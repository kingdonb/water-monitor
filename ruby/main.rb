require_relative 'logger'
require 'sinatra'
require 'redis'
require 'net/http'
require 'json'
require 'concurrent'
require 'digest/md5'
require 'connection_pool'
require 'zlib'

COMPRESSION_LEVEL = 1  # You can adjust this value as needed

module CacheHelpers
  include Loggable

  LOCK_TIMEOUT = 15_000 # 15 seconds in milliseconds
  CACHE_CONTROL_HEADER = 'public, max-age=86400, must-revalidate'
  GZIP_ENCODING = 'gzip'

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def backend_url
      end_date = Time.now.strftime("%F")
      url = "https://waterservices.usgs.gov/nwis/dv/?format=json&sites=04096405,04096515,04097500,040975299,04097540,04099000,04100500,04101000,04101500,04101800,04102500,04099750&statCd=00003&siteStatus=all&startDT=2000-01-01&endDT=#{end_date}"
      debu("backend_url: #{url}")
      url
    end

    def fetch_data
      debu("Fetching data from backend")
      url = backend_url
      uri = URI(url)
      response = Net::HTTP.get_response(uri)

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        response_body = if response.body.respond_to? :first
                          response.body.first
                        else
                          response.body
                        end
        response_size = response_body.bytesize
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

    def cache_ready?
      current_time = Time.now
      if @last_redis_check.nil? || current_time - @last_redis_check > 5 || ENV['RACK_ENV'] == 'test'
        with_redis do |redis|
          last_modified = redis.get("#{cache_key}_last_modified")
          @in_memory_last_modified = last_modified
          @in_memory_etag = redis.get("#{cache_key}_etag")
          @in_memory_compressed_data = redis.get("#{cache_key}_compressed")
        end
        @last_redis_check = current_time
      end

      return false if @in_memory_compressed_data.nil? || @in_memory_compressed_data.empty? ||
                    @in_memory_last_modified.nil? || @in_memory_last_modified.empty? ||
                    @in_memory_etag.nil? || @in_memory_etag.empty?

      last_modified_time = Time.parse(@in_memory_last_modified)
      if current_time - last_modified_time > 86400 # 24 hours
        debu("Cache not ready: data is stale")
        return false
      end

      true
    rescue => e
      erro("Error checking cache readiness: #{e.message}")
      false
    end

    def acquire_lock(timeout = LOCK_TIMEOUT)
      with_redis do |redis|
        acquired = redis.set(lock_key, true, nx: true, px: timeout)
        debu("Lock acquisition attempt result: #{acquired}")
        acquired
      end
    end

    def update_cache
      debu("Updating cache")
      data = fetch_data
      # debu("Data fetched: #{data.inspect}")
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
        if redis.respond_to?(:multi)
          redis.multi do |multi|
            set_cache_data(multi, json_data, compressed_data, etag, current_time)
          end
        else
          set_cache_data(redis, json_data, compressed_data, etag, current_time)
        end
      end

      @in_memory_compressed_data = compressed_data
      @in_memory_etag = etag
      @in_memory_last_modified = current_time

      debu("Cache updated, new value size: #{json_data.bytesize} bytes, compressed size: #{compressed_data.bytesize} bytes")
      release_lock
      debu("Cache updated and lock released")
    end

    def set_cache_data(redis, json_data, compressed_data, etag, current_time)
      redis.set(cache_key, json_data)
      redis.set("#{cache_key}_compressed", compressed_data)
      redis.set("#{cache_key}_last_modified", current_time)
      redis.set("#{cache_key}_etag", etag)
      redis.expire(cache_key, 86460) # Set TTL to 24 hours + 1 minute
      redis.expire("#{cache_key}_compressed", 86460)
      redis.expire("#{cache_key}_last_modified", 86460)
      redis.expire("#{cache_key}_etag", 86460)
    end

    def release_lock
      with_redis do |redis|
        redis.del(lock_key)
      end
      debu("Lock released")
    end
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
  include CacheHelpers
  include Loggable
  extend CacheHelpers::ClassMethods

  configure do
    set :environment, ENV['RACK_ENV'] || 'development'
  end

  def handle_data_request
    if self.class.cache_ready?
      serve_cached_data
    else
      request_cache_update
      log_request(request: request, response: response, data_sent: false, compressed: false)
    end
  rescue => e
    handle_data_error(e)
  end

  get '/data' do
    handle_data_request
  end

  get '/test' do
    'Test route'
  end

  def handle_data_error(error)
    erro("Error in /data route: #{error.message}")
    erro(error.backtrace.join("\n"))
    status 500
    body "An error occurred while processing your request."
    log_request(request: request, response: response, data_sent: false, compressed: false)
  end

  def serve_cached_data
    set_response_headers

    if client_cache_valid?(self.class.in_memory_etag)
      status 304
      log_request(request: request, response: response, data_sent: false, compressed: false)
      return
    end

    serve_appropriate_response
  rescue => e
    handle_serve_error(e)
  end

  private

  def set_response_headers
    content_type :json
    headers['ETag'] = self.class.in_memory_etag
    headers['Last-Modified'] = self.class.in_memory_last_modified
    headers['Cache-Control'] = CACHE_CONTROL_HEADER
    headers['Vary'] = 'Accept-Encoding'
  end

  def serve_appropriate_response
    if client_accepts_gzip?
      serve_compressed_response
    else
      serve_uncompressed_response
    end
  end

  def client_accepts_gzip?
    (request.env['HTTP_ACCEPT_ENCODING'] || '').include?(GZIP_ENCODING)
  end

  def serve_compressed_response
    headers['Content-Encoding'] = GZIP_ENCODING
    body self.class.in_memory_compressed_data.to_s
    log_request(request: request, response: response, data_sent: true, compressed: true)
  end

  def serve_uncompressed_response
    body Zlib::Inflate.inflate(self.class.in_memory_compressed_data.to_s)
    log_request(request: request, response: response, data_sent: true, compressed: false)
  end

  def handle_serve_error(error)
    erro("Error serving cached data: #{error.message}")
    status 500
    body "An error occurred while processing your request."
    log_request(request: request, response: response, data_sent: false, compressed: false)
  end

  def client_cache_valid?(etag)
    client_etag = request.env['HTTP_IF_NONE_MATCH']
    if client_etag && client_etag == etag
      debu("Cache hit: Client cache is still valid, returning 304")
      true
    else
      debu("Cache miss: Client cache is stale or non-existent")
      false
    end
  end

  def request_cache_update
    debu("Cache not ready or contains test data, publishing please_update_now message")
    with_redis { |redis| redis.publish("please_update_now", "true") }
    status 202
    body "Cache is updating, please try again later."
  rescue => e
    erro("Error requesting cache update: #{e.message}")
    status 202  # Keep the 202 status even if there's an error
    body "Cache is updating, please try again later."
  end

  class << self
    include Loggable
    attr_accessor :redis_pool, :lock_key, :cache_key, :lock_cv, :lock_mutex
    attr_accessor :in_memory_etag, :in_memory_compressed_data, :in_memory_last_modified
    attr_accessor :last_redis_check
    attr_accessor :app_initialized
    attr_accessor :cron_interval

    def update_cache
      debu("Updating cache")
      data = fetch_data
      # debu("Data fetched: #{data.inspect}")
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
        if redis.respond_to?(:multi)
          redis.multi do |multi|
            set_cache_data(multi, json_data, compressed_data, etag, current_time)
          end
        else
          set_cache_data(redis, json_data, compressed_data, etag, current_time)
        end
      end

      @in_memory_compressed_data = compressed_data
      @in_memory_etag = etag
      @in_memory_last_modified = current_time

      debu("Cache updated, new value size: #{json_data.bytesize} bytes, compressed size: #{compressed_data.bytesize} bytes")
      release_lock
      debu("Cache updated and lock released")
    end
  end

  def self.initialize_app(redis_url = nil)
    return if @app_initialized
    begin
      self.redis_pool = ConnectionPool.new(size: 5, timeout: 5) { Redis.new(url: redis_url) }
      self.lock_key = "update_lock"
      self.cache_key = "cached_data"
      self.lock_cv = ConditionVariable.new
      self.lock_mutex = Mutex.new
      debu("Redis connection pool initialized")
      @app_initialized = true
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

  set :bind, '0.0.0.0'

  get '/healthz' do
    # test redis connection (later)
    status 200
    body "Health OK"
    log_request(request: request, response: response, data_sent: true, compressed: false, level: :debug)
  end

  def log_request_headers
    %w[If-None-Match If-Modified-Since Cache-Control].each do |header|
      debu("#{header}: #{request.env["HTTP_#{header.upcase.gsub('-', '_')}"]}")
    end
    debu("Accept-Encoding: #{request.env['HTTP_ACCEPT_ENCODING'] || request.env['Accept-Encoding']}")
    debu("Raw headers: #{request.env.select { |k, v| k.start_with?('HTTP_') }}")
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
            debu("Lock acquired in cron thread, updating cache")
            update_cache
          else
            debu("Failed to acquire lock in cron thread")
          end
        else
          debu("Cache is ready, no update needed")
        end
        sleep @cron_interval || 86400 # Use configurable interval or default to 24 hours
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

# Initialize the app
MyApp.initialize_app(ENV['REDIS_URL'])

if __FILE__ == $0
  # Start the application and threads only when the script is run directly
  server_thread = Thread.new do
    MyApp.run!
  end

  # Ensure the server has time to start
  sleep 1

  # Start background threads
  MyApp.start_threads

  # Keep the main thread alive to handle interrupts
  server_thread.join
end