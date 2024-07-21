require 'sinatra'
require 'redis'
require 'net/http'
require 'json'
require 'concurrent'

module Logging
  LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }
  
  def self.log_level=(level)
    @log_level = LOG_LEVELS[level] || 1
  end

  def self.log(level, message)
    if LOG_LEVELS[level] >= @log_level
      puts "[#{level.to_s.upcase}] #{message}"
    end
  end
end

Logging.log_level = ENV['LOG_LEVEL']&.to_sym || :info

module CacheHelpers
  LOCK_TIMEOUT = 15_000 # 15 seconds in milliseconds

  def backend_url
    end_date = Time.now.strftime("%F")
    url = "https://waterservices.usgs.gov/nwis/dv/?format=json&sites=04096405,04096515,04097500,040975299,04097540,04099000,04100500,04101000,04101500,04101800,04102500,04099750&statCd=00003&siteStatus=all&startDT=2000-01-01&endDT=#{end_date}"
    Logging.log(:debug, "backend_url: #{url}")
    url
  end

  def cache_ready?
    cached_data = redis.get(cache_key)
    ready = cached_data && !cached_data.empty? && !is_test_data?(cached_data)
    Logging.log(:debug, "Cache ready: #{ready}")
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
    Logging.log(:debug, "Lock acquisition attempt result: #{acquired}")
    acquired
  end

  def release_lock
    redis.del(lock_key)
    Logging.log(:debug, "Lock released")
  end

  def update_cache
    Logging.log(:debug, "Updating cache")
    data = fetch_data
    Logging.log(:debug, "Data fetched: #{data.inspect}")
    if data.nil? || data.empty?
      Logging.log(:error, "Error: Fetched data is nil or empty")
      return
    end
    json_data = data.to_json
    redis.set(cache_key, json_data)
    Logging.log(:debug, "Cache updated. New value size: #{json_data.bytesize} bytes")
    if json_data.bytesize <= 400
      Logging.log(:debug, "New cache value: #{json_data}")
    else
      Logging.log(:debug, "New cache value too large to print (> 400 bytes)")
    end
    release_lock
    Logging.log(:debug, "Cache updated and lock released")
    cache_updated
  end

  def fetch_data
    Logging.log(:debug, "Fetching data from backend")
    url = backend_url
    uri = URI(url)
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      response_size = response.body.bytesize
      Logging.log(:debug, "Data fetched successfully. Response size: #{response_size} bytes")
      if response_size <= 400
        Logging.log(:debug, "Response body: #{response.body}")
      else
        Logging.log(:debug, "Response body too large to print (> 400 bytes)")
      end
      data
    else
      Logging.log(:error, "Error fetching data: #{response.code} #{response.message}")
      nil
    end
  rescue => e
    Logging.log(:error, "Exception while fetching data: #{e.message}")
    nil
  end

  def cache_updated
    # Implementation depends on how you want to notify about cache updates
    Logging.log(:debug, "Cache updated notification sent")
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

  class << self
    attr_accessor :redis, :lock_key, :cache_key
  end

  configure do
    begin
      MyApp.redis = Redis.new
      MyApp.redis.ping
      Logging.log(:info, "Connected to Redis")
    rescue => e
      Logging.log(:error, "Failed to connect to Redis: #{e.message}")
      exit 1
    end

    MyApp.lock_key = "update_lock"
    MyApp.cache_key = "cached_data"
    @@threads_started = false
    @@cache_updated_cv = ConditionVariable.new
    @@cache_updated_mutex = Mutex.new
  end

  get '/data' do
    Logging.log(:debug, "Received request at /data")
    if cache_ready?
      content_type :json
      cached_data = MyApp.redis.get(MyApp.cache_key)
      Logging.log(:debug, "Serving cached data. Size: #{cached_data.bytesize} bytes")
      cached_data
    else
      Logging.log(:debug, "Cache not ready or contains test data, publishing please_update_now message")
      MyApp.redis.publish("please_update_now", "true")
      status 202
      body "Cache is updating, please try again later."
    end
  end

  def self.start_threads
    return if @@threads_started

    @cron_thread = Thread.new do
      Logging.log(:debug, "Starting cron_thread")
      loop do
        sleep 86400  # 24 hours
        Logging.log(:debug, "cron_thread woke up")
        if !cache_ready? || (Time.now.to_i - MyApp.redis.ttl(MyApp.cache_key)) > 86400  # Check if cache is stale
          Logging.log(:debug, "Cache is stale or not ready")
          if acquire_lock
            update_cache
          end
        end
      end
    end

    @listener_thread = Thread.new do
      Logging.log(:debug, "Starting listener_thread")
      begin
        MyApp.redis.subscribe("please_update_now") do |on|
          on.message do |channel, message|
            Logging.log(:debug, "Received message on please_update_now: #{message}")
            if message == "true"
              if acquire_lock
                Logging.log(:debug, "Lock acquired in listener thread, updating cache")
                update_cache
              else
                Logging.log(:debug, "Failed to acquire lock in listener thread")
              end
            else
              Logging.log(:debug, "Unexpected message: #{message}")
            end
          end
        end
      rescue => e
        Logging.log(:error, "Failed to subscribe to Redis channel: #{e.message}")
        Logging.log(:error, e.backtrace.join("\n"))
      end
    end

    @@threads_started = true
  end

  def self.shutdown
    @cron_thread.kill if @cron_thread
    @listener_thread.kill if @listener_thread
    Logging.log(:info, "Gracefully shutting down...")
    exit
  end

  def self.debug_info
    Logging.log(:debug, "Threads started: #{@@threads_started}")
    Logging.log(:debug, "Listener thread alive: #{@listener_thread&.alive?}")
    Logging.log(:debug, "Cache exists: #{MyApp.redis.exists(MyApp.cache_key)}")
    Logging.log(:debug, "Lock exists: #{MyApp.redis.exists(MyApp.lock_key)}")
  end

  def self.update_cache
    Logging.log(:debug, "Updating cache")
    data = fetch_data
    Logging.log(:debug, "Data fetched: #{data.inspect}")
    if data.nil? || data.empty?
      Logging.log(:error, "Error: Fetched data is nil or empty")
      return
    end
    redis.set(cache_key, data.to_json)
    Logging.log(:debug, "Cache updated, new value: #{redis.get(cache_key)}")
    release_lock
    Logging.log(:debug, "Cache updated and lock released")
    cache_updated
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