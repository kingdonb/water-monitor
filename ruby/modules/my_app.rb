require 'redis'
require 'sinatra'
require_relative 'cache_helpers'
require_relative 'state_manager'

class MyApp < Sinatra::Base
  include CacheHelpers
  include Loggable
  extend CacheHelpers::ClassMethods

  configure do
    set :environment, ENV['RACK_ENV'] || 'development'
    set :state_manager, StateManager.new
    set_log_level(ENV['LOG_LEVEL'] ? ENV['LOG_LEVEL'].to_sym : Loggable::DEFAULT_LOG_LEVEL)
  end

  def handle_data_request
    health_status = settings.state_manager.health_check
    if health_status[:redis_status] != :connected
      status 503
      body "Service temporarily unavailable due to database connection issues."
      log_request(request: request, response: response, data_sent: false, compressed: false)
    elsif self.class.cache_ready?
      settings.state_manager.update_cache_status(:ready)
      serve_cached_data
    else
      settings.state_manager.update_cache_status(:updating)
      request_cache_update
      status 202
      body "Cache is updating, please try again later."
    end
    # log_request(request: request, response: response, data_sent: false, compressed: false)
  rescue StandardError => e
    settings.state_manager.increment_error_count
    handle_data_error(e)
  end

  get '/data' do
    handle_data_request
  end

  def handle_data15_request
    health_status = settings.state_manager.health_check
    if health_status[:redis_status] != :connected
      status 503
      body "Service temporarily unavailable due to database connection issues."
      log_request(request: request, response: response, data_sent: false, compressed: false)
    elsif self.class.cache_ready?
      settings.state_manager.update_cache_status(:ready)
      serve_cached_data
    else
      settings.state_manager.update_cache_status(:updating)
      request_cache_update
      status 202
      body "Cache is updating, please try again later."
    end
    # log_request(request: request, response: response, data_sent: false, compressed: false)
  rescue StandardError => e
    settings.state_manager.increment_error_count
    handle_data_error(e)
  end

  get '/data15' do
    handle_data15_request
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
  rescue StandardError => e
    handle_serve_error(e)
  end

  private

  def set_response_headers
    content_type :json
    headers['ETag'] = self.class.in_memory_etag
    headers['Last-Modified'] = self.class.in_memory_last_modified
    headers['Cache-Control'] = CACHE_CONTROL_HEADER
    headers['Access-Control-Allow-Origin'] = '*'
    headers['Vary'] = 'Accept-Encoding'
  end

  def set_response15_headers
    content_type :json
    headers['ETag'] = self.class.in_memory_etag
    headers['Last-Modified'] = self.class.in_memory_last_modified
    headers['Cache-Control'] = CACHE_15_CONTROL_HEADER
    headers['Access-Control-Allow-Origin'] = '*'
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

    # Update cache status to updating while the cache is being warmed
    settings.state_manager.update_cache_status(:updating)

    status 202
    body "Cache is updating, please try again later."
  rescue StandardError => e
    erro("Error requesting cache update: #{e.message}")
    status 202  # Keep the 202 status even if there's an error
    body "Cache is updating, please try again later."
  end

  class << self
    include Loggable
    attr_accessor :redis_pool, :lock_key, :cache_key, :lock_cv, :lock_mutex
    attr_accessor :in_memory_etag, :in_memory_compressed_data, :in_memory_last_modified
    attr_accessor :in_memory_etag15, :in_memory_compressed_data15, :in_memory_last15_modified
    attr_accessor :last_redis_check
    attr_accessor :last_redis15_check
    attr_accessor :app_initialized
    attr_accessor :cron_interval
  end

  def self.initialize_app(redis_url = nil)
    set_log_level(ENV['LOG_LEVEL']) if ENV['LOG_LEVEL']
    return if @app_initialized
    begin
      self.redis_pool = ConnectionPool.new(size: 5, timeout: 5) do
        redis = Redis.new(url: redis_url)
        settings.state_manager.update_redis_status(:connected)
        info("Successfully connected to Redis")
        redis
      end
      self.lock_key = "update_lock"
      self.cache_key = "cached_data"
      self.lock_cv = ConditionVariable.new
      self.lock_mutex = Mutex.new
      debu("Redis connection pool initialized")
      @app_initialized = true
      start_redis_health_check
    rescue Redis::CannotConnectError, SocketError => e
      settings.state_manager.update_redis_status(:disconnected)
      erro("Failed to connect to Redis: #{e.message}")
      erro("Application will start, but data serving will be unavailable")
      @app_initialized = true  # Still mark as initialized to prevent repeated attempts
      start_redis_health_check  # Start health check to attempt reconnection
    end
  end

  def self.start_redis_health_check
    Thread.new do
      loop do
        begin
          if redis_pool.nil?
            initialize_app(ENV['REDIS_URL'])
          else
            with_redis { |redis| redis.ping }
            settings.state_manager.update_redis_status(:connected)
          end
        rescue Redis::BaseConnectionError, SocketError => e
          settings.state_manager.update_redis_status(:disconnected)
          erro("Redis health check failed: #{e.message}")
        rescue StandardError => e
          settings.state_manager.update_redis_status(:error)
          erro("Unexpected error in Redis health check: #{e.message}")
        end
        sleep 10 # Check every 10 seconds
      end
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
    health_status = settings.state_manager.health_check
    status health_status[:cache_status] == :ready && health_status[:redis_status] == :connected ? 200 : 503
    content_type :json
    body health_status.to_json
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

    current_log_level = log_level

    @cron_thread = Thread.new do
      set_log_level(current_log_level)
      debu("Starting cron_thread")
      redis = Redis.new
      loop do
        if cache_ready?
          debu("Cache is ready, no update needed in cron_thread")
          settings.state_manager.update_cache_status(:ready)
        elsif acquire_lock
          debu("Lock acquired in cron_thread, updating cache")
          update_cache
        else
          debu("Failed to acquire lock in cron_thread")
        end
        sleep cron_interval
        debu("cron_thread woke up")
      end
    ensure
      redis.close if redis
    end

    @listener_thread = Thread.new do
      set_log_level(current_log_level)
      debu("Starting listener_thread")
      begin
        redis = Redis.new # New connection for this thread
        redis.subscribe("please_update_now") do |on|
          on.message do |channel, message|
            on_message(channel, message)
          end
        end
      rescue Redis::BaseConnectionError, EOFError => e
        erro("Redis connection error in listener thread: #{e.message}")
        settings.state_manager.update_redis_status(:disconnected)
      rescue StandardError => e
        erro("Failed to subscribe to Redis channel: #{e.message}")
        erro(e.backtrace.join("\n"))
        settings.state_manager.update_redis_status(:error)
      ensure
        redis.close if redis
      end
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

  def self.on_message(channel, message)
    debu("Received message on #{channel}: #{message}")
    if channel == "please_update_now" && message == "true"
      if self.acquire_lock
        debu("Lock acquired in listener thread, updating cache")
        self.update_cache
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
