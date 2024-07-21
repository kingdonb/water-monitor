require 'sinatra'
require 'redis'
require 'net/http'
require 'json'
require 'concurrent'

module CacheHelpers
  LOCK_TIMEOUT = 15_000 # 15 seconds in milliseconds

  def backend_url
    end_date = Time.now.strftime("%F")
    url = "https://waterservices.usgs.gov/nwis/dv/?format=json&sites=04096405,04096515,04097500,040975299,04097540,04099000,04100500,04101000,04101500,04101800,04102500,04099750&statCd=00003&siteStatus=all&startDT=2000-01-01&endDT=#{end_date}"
    puts "backend_url: #{url}"
    url
  end

  def cache_ready?
    cached_data = redis.get(cache_key)
    ready = cached_data && !cached_data.empty? && !is_test_data?(cached_data)
    puts "Cache ready: #{ready}"
    ready
  end

  def is_test_data?(data)
    parsed = JSON.parse(data)
    parsed.is_a?(Hash) && parsed.keys == ["test"] && parsed["test"] == "data"
  rescue JSON::ParserError
    false
  end

  def acquire_lock
    acquired = redis.set(lock_key, true, nx: true, px: LOCK_TIMEOUT)
    puts "Lock acquisition attempt result: #{acquired}"
    acquired
  end

  def release_lock
    redis.del(lock_key)
    puts "Lock released"
  end

  def update_cache
    puts "Updating cache"
    data = fetch_data
    if data.nil? || data.empty?
      puts "Error: Fetched data is nil or empty"
      return
    end
    json_data = data.to_json
    redis.set(cache_key, json_data)
    puts "Cache updated. New value size: #{json_data.bytesize} bytes"
    release_lock
    puts "Cache updated and lock released"
    cache_updated
  end

  def fetch_data
    puts "Fetching data from backend"
    url = backend_url
    uri = URI(url)
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      puts "Data fetched successfully. Response size: #{response.body.bytesize} bytes"
      data
    else
      puts "Error fetching data: #{response.code} #{response.message}"
      nil
    end
  rescue => e
    puts "Exception while fetching data: #{e.message}"
    nil
  end

  def cache_updated
    # Implementation depends on how you want to notify about cache updates
    puts "Cache updated notification sent"
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
      puts "Connected to Redis"
    rescue => e
      puts "Failed to connect to Redis: #{e.message}"
      exit 1
    end

    MyApp.lock_key = "update_lock"
    MyApp.cache_key = "cached_data"
    @@threads_started = false
    @@cache_updated_cv = ConditionVariable.new
    @@cache_updated_mutex = Mutex.new
  end

  get '/data' do
    puts "Received request at /data"
    if cache_ready?
      content_type :json
      cached_data = MyApp.redis.get(MyApp.cache_key)
      puts "Serving cached data. Size: #{cached_data.bytesize} bytes"
      cached_data
    else
      puts "Cache not ready or contains test data, publishing please_update_now message"
      MyApp.redis.publish("please_update_now", "true")
      status 202
      body "Cache is updating, please try again later."
    end
  end

  def self.start_threads
    return if @@threads_started

    @cron_thread = Thread.new do
      puts "Starting cron_thread"
      loop do
        sleep 86400  # 24 hours
        puts "cron_thread woke up"
        if !cache_ready? || (Time.now.to_i - MyApp.redis.ttl(MyApp.cache_key)) > 86400  # Check if cache is stale
          puts "Cache is stale or not ready"
          if acquire_lock
            update_cache
          end
        end
      end
    end

    @listener_thread = Thread.new do
      puts "Starting listener_thread"
      begin
        MyApp.redis.subscribe("please_update_now") do |on|
          on.message do |channel, message|
            puts "Received message on please_update_now: #{message}"
            if message == "true"
              if acquire_lock
                puts "Lock acquired in listener thread, updating cache"
                update_cache
              else
                puts "Failed to acquire lock in listener thread"
              end
            else
              puts "Unexpected message: #{message}"
            end
          end
        end
      rescue => e
        puts "Failed to subscribe to Redis channel: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end

    @@threads_started = true
  end

  def self.shutdown
    @cron_thread.kill if @cron_thread
    @listener_thread.kill if @listener_thread
    puts "Gracefully shutting down..."
    exit
  end

  def self.debug_info
    puts "Threads started: #{@@threads_started}"
    puts "Listener thread alive: #{@listener_thread&.alive?}"
    puts "Cache exists: #{MyApp.redis.exists(MyApp.cache_key)}"
    puts "Lock exists: #{MyApp.redis.exists(MyApp.lock_key)}"
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