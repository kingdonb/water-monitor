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

  def fetch_data
    puts "Fetching data from backend"
    uri = URI(backend_url)
    response = Net::HTTP.get(uri)
    data = JSON.parse(response)
    data
  end

  def cache_ready?
    ready = settings.redis.exists(settings.cache_key)
    puts "Cache ready: #{ready}"
    ready == 1
  end

  def acquire_lock
    acquired = settings.redis.set(settings.lock_key, true, nx: true, px: LOCK_TIMEOUT)
    puts "Lock acquired: #{acquired}"
    acquired
  end

  def release_lock
    settings.redis.del(settings.lock_key)
    puts "Lock released"
  end

  def update_cache
    puts "Updating cache"
    data = fetch_data
    settings.redis.set(settings.cache_key, data.to_json)
    release_lock
    puts "Cache updated"
  end
end

class MyApp < Sinatra::Base
  configure do
    begin
      redis = Redis.new
      redis.ping
      set :redis, redis
      puts "Connected to Redis"
    rescue => e
      puts "Failed to connect to Redis: #{e.message}"
      exit 1
    end

    set :lock_key, "update_lock"
    set :cache_key, "cached_data"
    @@threads_started = false
  end

  helpers CacheHelpers

  get '/data' do
    puts "Received request at /data"
    if cache_ready?
      content_type :json
      cached_data = settings.redis.get(settings.cache_key)
      cached_data
    else
      puts "Cache not ready, publishing please_update_now message"
      settings.redis.publish("please_update_now", "true")
      status 202
      body "Cache is updating, please try again later."
    end
  end

  def self.start_threads
    return if @@threads_started

    extend CacheHelpers

    @cron_thread = Thread.new do
      puts "Starting cron_thread"
      loop do
        sleep 86400  # 24 hours
        puts "cron_thread woke up"
        if !cache_ready? || (Time.now.to_i - settings.redis.ttl(settings.cache_key)) > 86400  # Check if cache is stale
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
        settings.redis.subscribe("please_update_now") do |on|
          on.message do |channel, message|
            puts "Received message on please_update_now: #{message}"
            if message == "true" && acquire_lock
              update_cache
            end
          end
        end
      rescue => e
        puts "Failed to subscribe to Redis channel: #{e.message}"
      end
    end

    @@threads_started = true
  end

  def self.shutdown
    @cron_thread.kill if @cron_thread
    @listener_thread.kill if @listener_thread
    settings.redis.quit
    puts "Gracefully shutting down..."
    exit
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