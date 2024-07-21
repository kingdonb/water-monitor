require_relative 'logger'
require 'sinatra'
require 'redis'
require 'net/http'
require 'json'
require 'concurrent'

# The log level is now set in logger.rb

module CacheHelpers
  include Loggable

  LOCK_TIMEOUT = 15_000 # 15 seconds in milliseconds

  def backend_url
    end_date = Time.now.strftime("%F")
    url = "https://waterservices.usgs.gov/nwis/dv/?format=json&sites=04096405,04096515,04097500,040975299,04097540,04099000,04100500,04101000,04101500,04101800,04102500,04099750&statCd=00003&siteStatus=all&startDT=2000-01-01&endDT=#{end_date}"
    debug("backend_url: #{url}")
    url
  end

  def cache_ready?
    cached_data = redis.get(cache_key)
    ready = cached_data && !cached_data.empty? && !is_test_data?(cached_data)
    debug("Cache ready: #{ready}")
    ready
  end

  def is_test_data?(data)
    parsed = JSON.parse(data)
    parsed.is_a?(Hash) && parsed.keys == ["test"] && parsed["test"] == "data"
  rescue JSON::ParserError
    false
  end

  def acquire_lock(timeout = LOCK_TIMEOUT)
    acquired = redis.set(lock_key, true, nx: true, px: timeout)
    debug("Lock acquisition attempt result: #{acquired}")
    acquired
  end

  def release_lock
    redis.del(lock_key)
    debug("Lock released")
  end

  def update_cache
    debug("Updating cache")
    data = fetch_data
    debug("Data fetched: #{data.inspect}")
    if data.nil? || data.empty?
      error("Error: Fetched data is nil or empty")
      return
    end
    json_data = data.to_json
    redis.set(cache_key, json_data)
    debug("Cache updated. New value size: #{json_data.bytesize} bytes")
    if json_data.bytesize <= 400
      debug("New cache value: #{json_data}")
    else
      debug("New cache value too large to print (> 400 bytes)")
    end
    release_lock
    debug("Cache updated and lock released")
    cache_updated
  end

  def fetch_data
    debug("Fetching data from backend")
    url = backend_url
    uri = URI(url)
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      response_size = response.body.bytesize
      debug("Data fetched successfully. Response size: #{response_size} bytes")
      if response_size <= 400
        debug("Response body: #{response.body}")
      else
        debug("Response body too large to print (> 400 bytes)")
      end
      data
    else
      error("Error fetching data: #{response.code} #{response.message}")
      nil
    end
  rescue => e
    error("Exception while fetching data: #{e.message}")
    nil
  end

  def cache_updated
    # Implementation depends on how you want to notify about cache updates
    debug("Cache updated notification sent")
  end

  def redis
    self.class.redis
  end

  def lock_key
    self.class.lock_key
  end

  def cache_key
    self.class.cache_key
  end
end

class MyApp < Sinatra::Base
  extend CacheHelpers
  include CacheHelpers
  include Loggable

  class << self
    attr_accessor :redis, :lock_key, :cache_key, :lock_cv, :lock_mutex
  end

  def initialize(app = nil, redis_instance = nil)
    super(app)
    self.class.redis = redis_instance || Redis.new
    self.class.lock_key = "update_lock"
    self.class.cache_key = "cached_data"
    self.class.lock_cv = ConditionVariable.new
    self.class.lock_mutex = Mutex.new
    @threads_started = false
  end

  configure do
    set :redis, Redis.new unless settings.respond_to?(:redis)
  end

  def self.acquire_lock(timeout = LOCK_TIMEOUT)
    lock_mutex.synchronize do
      acquired = redis.set(lock_key, true, nx: true, px: timeout)
      debug("Lock acquisition attempt result: #{acquired}")
      lock_cv.signal if acquired
      acquired
    end
  end

  def self.release_lock
    lock_mutex.synchronize do
      redis.del(lock_key)
      debug("Lock released")
      lock_cv.signal
    end
  end

  get '/data' do
    debug("Received request at /data")
    if cache_ready?
      content_type :json
      cached_data = MyApp.redis.get(MyApp.cache_key)
      debug("Serving cached data. Size: #{cached_data.bytesize} bytes")
      cached_data
    else
      debug("Cache not ready or contains test data, publishing please_update_now message")
      MyApp.redis.publish("please_update_now", "true")
      status 202
      body "Cache is updating, please try again later."
    end
  end

  def self.start_threads
    return if @threads_started

    @cron_thread = Thread.new do
      debug("Starting cron_thread")
      loop do
        sleep 86400  # 24 hours
        debug("cron_thread woke up")
        if !cache_ready? || (Time.now.to_i - redis.ttl(cache_key)) > 86400  # Check if cache is stale
          debug("Cache is stale or not ready")
          if acquire_lock
            update_cache
          end
        end
      end
    end

    @listener_thread = Thread.new do
      debug("Starting listener_thread")
      begin
        redis.subscribe("please_update_now") do |on|
          on.message do |channel, message|
            debug("Received message on please_update_now: #{message}")
            if message == "true"
              if acquire_lock
                debug("Lock acquired in listener thread, updating cache")
                update_cache
              else
                debug("Failed to acquire lock in listener thread")
              end
            else
              debug("Unexpected message: #{message}")
            end
          end
        end
      rescue => e
        error("Failed to subscribe to Redis channel: #{e.message}")
        error(e.backtrace.join("\n"))
      end
    end

    @threads_started = true
  end

  def self.shutdown
    @cron_thread.kill if @cron_thread
    @listener_thread.kill if @listener_thread
    info("Gracefully shutting down...")
    exit
  end

  def self.debug_info
    debug("Threads started: #{@threads_started}")
    debug("Listener thread alive: #{@listener_thread&.alive?}")
    debug("Cache exists: #{redis.exists(cache_key)}")
    debug("Lock exists: #{redis.exists(lock_key)}")
  end

  def self.update_cache
    debug("Updating cache")
    data = fetch_data
    debug("Data fetched: #{data.inspect}")
    if data.nil? || data.empty?
      error("Error: Fetched data is nil or empty")
      return
    end
    redis.set(cache_key, data.to_json)
    debug("Cache updated, new value: #{redis.get(cache_key)}")
    release_lock
    debug("Cache updated and lock released")
    cache_updated
  end

  def on_message(channel, message)
    debug("Received message on #{channel}: #{message}")
    if channel == "please_update_now" && message == "true"
      if self.class.acquire_lock
        debug("Lock acquired in listener thread, updating cache")
        self.class.update_cache
      else
        debug("Failed to acquire lock in listener thread")
      end
    else
      debug("Unexpected message: #{message}")
    end
  end

  at_exit { MyApp.shutdown }
end

# Start the application and threads after the class definition
server_thread = Thread.new do
  MyApp.run! if MyApp.app_file == $0
end

# Ensure the server has time to start
sleep 1

# Start background threads
MyApp.start_threads

# Keep the main thread alive to handle interrupts
server_thread.join