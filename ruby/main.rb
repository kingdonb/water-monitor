require_relative 'logger'
require 'sinatra'
require 'redis'
require 'net/http'
require 'json'
require 'concurrent'
require 'digest/md5'
require 'connection_pool'
require 'zlib'

# Set the log level for the Loggable module
Loggable.set_log_level(ENV['LOG_LEVEL'])

module CacheHelpers
  include Loggable

  LOCK_TIMEOUT = 15_000 # 15 seconds in milliseconds

  def backend_url
    end_date = Time.now.strftime("%F")
    url = "https://waterservices.usgs.gov/nwis/dv/?format=json&sites=04096405,04096515,04097500,040975299,04097540,04099000,04100500,04101000,04101500,04101800,04102500,04099750&statCd=00003&siteStatus=all&startDT=2000-01-01&endDT=#{end_date}"
    debu("backend_url: #{url}")
    url
  end

  def cache_ready?
    with_redis do |redis|
      cached_data = redis.get(cache_key)
      compressed_data = redis.get("#{cache_key}_compressed")
      last_modified = redis.get("#{cache_key}_last_modified")
      etag = redis.get("#{cache_key}_etag")

      if cached_data.nil? || cached_data.empty? ||
         compressed_data.nil? || compressed_data.empty? ||
         last_modified.nil? || last_modified.empty? ||
         etag.nil? || etag.empty?
        debu("Cache not ready: one or more required fields are missing or empty")
        return false
      end

      last_modified_time = Time.parse(last_modified)
      if Time.now - last_modified_time > 86400  # 24 hours
        debu("Cache not ready: data is stale")
        return false
      end

      ready = !is_test_data?(cached_data)
      debu("Cache ready: #{ready}")
      ready
    end
  rescue => e
    erro("Error checking cache readiness: #{e.message}")
    false
  end

  def is_test_data?(data)
    parsed = JSON.parse(data)
    parsed.is_a?(Hash) && parsed.keys == ["test"] && parsed["test"] == "data"
  rescue JSON::ParserError
    false
  end

  def acquire_lock(timeout = LOCK_TIMEOUT)
    with_redis do |redis|
      acquired = redis.set(lock_key, true, nx: true, px: timeout)
      debu("Lock acquisition attempt result: #{acquired}")
      acquired
    end
  end

  def release_lock
    with_redis do |redis|
      redis.del(lock_key)
    end
    debu("Lock released")
  end

  def update_cache
    debu("Updating cache")
    data = fetch_data
    debu("Data fetched: #{data.inspect}")
    if data.nil? || data.empty?
      erro("Error: Fetched data is nil or empty")
      return
    end
    json_data = data.to_json
    compressed_data = StringIO.new.tap do |io|
      gz = Zlib::GzipWriter.new(io, COMPRESSION_LEVEL)
      gz.write(json_data)
      gz.close
    end.string
    etag = Digest::MD5.hexdigest(json_data)
    current_time = Time.now.httpdate
    with_redis do |redis|
      redis.set(cache_key, json_data)
      redis.set("#{cache_key}_compressed", compressed_data)
      redis.set("#{cache_key}_last_modified", current_time)
      redis.set("#{cache_key}_etag", etag)
      redis.expire(cache_key, 86460) # Set TTL to 24 hours + 1 minute
      redis.expire("#{cache_key}_compressed", 86460)
      redis.expire("#{cache_key}_last_modified", 86460)
      redis.expire("#{cache_key}_etag", 86460)
    end
    debu("Cache updated, new value size: #{json_data.bytesize} bytes, compressed size: #{compressed_data.bytesize} bytes")
    release_lock
    debu("Cache updated and lock released")
    cache_updated
  end

  def fetch_data
    debu("Fetching data from backend")
    url = backend_url
    uri = URI(url)
    response = Net::HTTP.get_response(uri)

    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      response_size = response.body.bytesize
      debu("Data fetched successfully. Response size: #{response_size} bytes")
      if response_size <= 400
        debu("Response body: #{response.body}")
      else
        debu("Response body too large to print (> 400 bytes)")
      end
      data
    else
      erro("Error fetching data: #{response.code} #{response.message}")
      nil
    end
  rescue => e
    erro("Exception while fetching data: #{e.message}")
    nil
  end

  def cache_updated
    # Implementation depends on how you want to notify about cache updates
    debu("Cache updated notification sent")
  end

  def redis
    Thread.current[:redis] ||= Redis.new
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
    include Loggable
    attr_accessor :redis_pool, :lock_key, :cache_key, :lock_cv, :lock_mutex
  end

  def self.initialize_app(redis_url = nil)
    begin
      self.redis_pool = ConnectionPool.new(size: 5, timeout: 5) { Redis.new(url: redis_url) }
      self.lock_key = "update_lock"
      self.cache_key = "cached_data"
      self.lock_cv = ConditionVariable.new
      self.lock_mutex = Mutex.new
      debu("Redis connection pool initialized")
    rescue Redis::CannotConnectError => e
      erro("Failed to connect to Redis: #{e.message}")
      exit(1)
    end
  end

  # Define with_redis as both a class and instance method
  def self.with_redis
    redis_pool.with { |redis| yield redis }
  end

  def with_redis(&block)
    self.class.with_redis(&block)
  end

  def self.cache_ready?
    with_redis do |redis|
      cached_data = redis.get(cache_key)
      compressed_data = redis.get("#{cache_key}_compressed")
      last_modified = redis.get("#{cache_key}_last_modified")
      etag = redis.get("#{cache_key}_etag")

      if cached_data.nil? || cached_data.empty? ||
         compressed_data.nil? || compressed_data.empty? ||
         last_modified.nil? || last_modified.empty? ||
         etag.nil? || etag.empty?
        debu("Cache not ready: one or more required fields are missing or empty")
        return false
      end

      last_modified_time = Time.parse(last_modified)
      if Time.now - last_modified_time > 86400  # 24 hours
        debu("Cache not ready: data is stale")
        return false
      end

      ready = !is_test_data?(cached_data)
      debu("Cache ready: #{ready}")
      ready
    end
  rescue => e
    erro("Error checking cache readiness: #{e.message}")
    false
  end

  def self.is_test_data?(data)
    parsed = JSON.parse(data)
    parsed.is_a?(Hash) && parsed.keys == ["test"] && parsed["test"] == "data"
  rescue JSON::ParserError
    false
  end

  def self.acquire_lock(timeout = LOCK_TIMEOUT)
    lock_mutex.synchronize do
      acquired = with_redis do |redis|
        redis.set(lock_key, true, nx: true, px: timeout)
      end
      debu("Lock acquisition attempt result: #{acquired}")
      lock_cv.signal if acquired
      acquired
    end
  end

  def self.release_lock
    lock_mutex.synchronize do
      with_redis do |redis|
        redis.del(lock_key)
      end
      debu("Lock released")
      lock_cv.signal
    end
  end

  COMPRESSION_LEVEL = Zlib::BEST_COMPRESSION

  set :bind, '0.0.0.0'

  get '/data' do
    debu("Received request at /data")
    debu("If-None-Match: #{request.env['HTTP_IF_NONE_MATCH']}")
    debu("If-Modified-Since: #{request.env['HTTP_IF_MODIFIED_SINCE']}")
    debu("Cache-Control: #{request.env['HTTP_CACHE_CONTROL']}")

    accept_encoding = request.env['HTTP_ACCEPT_ENCODING'] || request.env['Accept-Encoding']
    debu("Accept-Encoding: #{accept_encoding}")
    debu("Raw headers: #{request.env.select { |k, v| k.start_with?('HTTP_') }}")

    begin
      if cache_ready?
        content_type :json
        cached_data = with_redis { |redis| redis.get(self.class.cache_key) }
        compressed_data = with_redis { |redis| redis.get("#{self.class.cache_key}_compressed") }
        last_modified = with_redis { |redis| redis.get("#{self.class.cache_key}_last_modified") }
        etag = with_redis { |redis| redis.get("#{self.class.cache_key}_etag") }

        if etag.nil?
          etag = Digest::MD5.hexdigest(cached_data)
          with_redis do |redis|
            redis.set("#{self.class.cache_key}_etag", etag)
          end
        end

        # Set caching headers
        headers['Last-Modified'] = last_modified if last_modified
        headers['ETag'] = etag
        headers['Cache-Control'] = 'public, max-age=86400, must-revalidate'
        headers['Vary'] = 'Accept-Encoding'

        # Check if the client's cached version is still valid
        client_etag = request.env['HTTP_IF_NONE_MATCH']
        if client_etag && client_etag == etag
          debu("Cache hit: Client cache is still valid, returning 304")
          status 304
          return
        else
          debu("Cache miss: Client cache is stale or non-existent")
        end

        if compressed_data.nil?
          debu("Compressed data not found in cache, compressing now")
          compressed_data = StringIO.new.tap do |io|
            gz = Zlib::GzipWriter.new(io, COMPRESSION_LEVEL)
            gz.write(cached_data)
            gz.close
          end.string
          with_redis do |redis|
            redis.set("#{self.class.cache_key}_compressed", compressed_data)
          end
        end

        if accept_encoding&.include?('gzip')
          headers['Content-Encoding'] = 'gzip'
          response_body = compressed_data
          debu("Serving compressed data (gzip). Size: #{response_body.bytesize} bytes")
        else
          response_body = cached_data
          debu("Serving uncompressed data. Size: #{response_body.bytesize} bytes")
        end

        status 200
        body response_body
      else
        debu("Cache not ready or contains test data, publishing please_update_now message")
        with_redis { |redis| redis.publish("please_update_now", "true") }
        status 202
        body "Cache is updating, please try again later."
      end
    rescue => e
      erro("Error in /data route: #{e.message}")
      erro(e.backtrace.join("\n"))
      status 500
      body "An error occurred while processing your request."
    end
  end

  def self.start_threads
    return if @threads_started
    debu("Starting background threads")

    unless redis_pool
      erro("Redis connection pool not initialized. Cannot start threads.")
      return
    end

    @listener_thread = Thread.new do
      debu("Starting listener_thread")
      begin
        redis = Redis.new # New connection for this thread
        redis.subscribe("please_update_now") do |on|
          on.message do |channel, message|
            debu("Received message on please_update_now: #{message}")
            if message == "true"
              if acquire_lock
                debu("Lock acquired in listener thread, updating cache")
                update_cache
              else
                debu("Failed to acquire lock in listener thread")
              end
            else
              debu("Unexpected message: #{message}")
            end
          end
        end
      rescue Redis::BaseConnectionError => e
        erro("Redis connection error in listener thread: #{e.message}")
      rescue => e
        erro("Failed to subscribe to Redis channel: #{e.message}")
        erro(e.backtrace.join("\n"))
      ensure
        redis.close if redis
      end
    end

    @cron_thread = Thread.new do
      debu("Starting cron_thread")
      redis = Redis.new # New connection for this thread
      loop do
        if !cache_ready?
          debu("Cache is not ready or stale")
          if acquire_lock
            update_cache
          end
        end
        sleep 86400 # 24 hours
        debu("cron_thread woke up")
      end
    ensure
      redis.close if redis
    end

    @threads_started = true
    debu("Background threads started")
  end

  def self.shutdown
    debu("Shutting down background threads")
    @cron_thread.kill if @cron_thread
    @listener_thread.kill if @listener_thread
    info("Gracefully shutting down...")
    exit
  end

  def self.update_cache
    debu("Updating cache")
    data = fetch_data
    debu("Data fetched: #{data.inspect}")
    if data.nil? || data.empty?
      erro("Error: Fetched data is nil or empty")
      return
    end
    json_data = data.to_json
    compressed_data = StringIO.new.tap do |io|
      gz = Zlib::GzipWriter.new(io, COMPRESSION_LEVEL)
      gz.write(json_data)
      gz.close
    end.string
    etag = Digest::MD5.hexdigest(json_data)
    current_time = Time.now.httpdate
    with_redis do |redis|
      redis.set(cache_key, json_data)
      redis.set("#{cache_key}_compressed", compressed_data)
      redis.set("#{cache_key}_last_modified", current_time)
      redis.set("#{cache_key}_etag", etag)
      redis.expire(cache_key, 86460) # Set TTL to 24 hours + 1 minute
      redis.expire("#{cache_key}_compressed", 86460)
      redis.expire("#{cache_key}_last_modified", 86460)
      redis.expire("#{cache_key}_etag", 86460)
    end
    debu("Cache updated, new value size: #{json_data.bytesize} bytes, compressed size: #{compressed_data.bytesize} bytes")
    release_lock
    debu("Cache updated and lock released")
    cache_updated
  end

  def on_message(channel, message)
    debu("Received message on #{channel}: #{message}")
    if channel == "please_update_now" && message == "true"
      if self.class.acquire_lock
        debu("Lock acquired in listener thread, updating cache")
        self.class.update_cache
      else
        debu("Failed to acquire lock in listener thread")
      end
    else
      debu("Unexpected message: #{message}")
    end
  end

  helpers do
    def stale?(options)
      etag = options[:etag]
      last_modified = options[:last_modified]

      if_none_match = request.env['HTTP_IF_NONE_MATCH']
      if_modified_since = request.env['HTTP_IF_MODIFIED_SINCE']

      return true if if_none_match.nil? && if_modified_since.nil?

      if if_none_match && etag
        return false if if_none_match == etag
      elsif if_modified_since && last_modified
        return false if Time.parse(if_modified_since) >= Time.parse(last_modified)
      end

      true
    end
  end

  at_exit { MyApp.shutdown }
end

# Set the log level for MyApp
MyApp.set_log_level(ENV['LOG_LEVEL'])

# Start the application and threads after setting the log level
MyApp.initialize_app(ENV['REDIS_URL'])

server_thread = Thread.new do
  MyApp.run! if MyApp.app_file == $0
end

# Ensure the server has time to start
sleep 1

# Start background threads
MyApp.start_threads

# Keep the main thread alive to handle interrupts
server_thread.join