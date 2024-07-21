require 'bundler/setup'
require 'rack/test'
require 'minitest/autorun'
require 'mocha/minitest'
require_relative 'logger'
require_relative 'main'

class MyAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= MyApp.new
  end

  def setup
    MyApp.initialize_app
    MyApp.redis_pool = ConnectionPool.new(size: 5, timeout: 5) { mock_redis }
    MyApp.lock_key = "update_lock"
    MyApp.cache_key = "cached_data"
    MyApp.lock_cv = ConditionVariable.new
    MyApp.lock_mutex = Mutex.new
    @app = nil
  end

  def teardown
    MyApp.with_redis(&:flushdb)
  end

  def test_data_endpoint_when_cache_ready
    valid_data = { "value" => "real_data" }.to_json
    last_modified = Time.now.httpdate
    etag = Digest::MD5.hexdigest(valid_data)
    compressed_data = StringIO.new.tap do |io|
      gz = Zlib::GzipWriter.new(io, MyApp::COMPRESSION_LEVEL)
      gz.write(valid_data)
      gz.close
    end.string

    MyApp.with_redis do |redis|
      redis.set(MyApp.cache_key, valid_data)
      redis.set("#{MyApp.cache_key}_compressed", compressed_data)
      redis.set("#{MyApp.cache_key}_last_modified", last_modified)
      redis.set("#{MyApp.cache_key}_etag", etag)
    end

    # Ensure cache is ready
    assert MyApp.cache_ready?, "Cache should be ready"

    # First request to get the ETag
    get '/data'
    assert last_response.ok?, "Response should be OK, but was #{last_response.status}"
    assert_equal 'application/json', last_response.content_type
    assert_equal valid_data, last_response.body
    assert_equal last_modified, last_response.headers['Last-Modified']
    assert_equal etag, last_response.headers['ETag']

    # Second request with If-None-Match header
    header 'If-None-Match', etag
    get '/data'
    assert_equal 304, last_response.status, "Response should be 304 Not Modified, but was #{last_response.status}"
    assert_empty last_response.body
  end

  def test_data_endpoint_when_cache_not_ready
    MyApp.with_redis { |redis| redis.flushdb }  # Clear all data in Redis
    get '/data'
    assert_equal 202, last_response.status, "Expected 202, but got #{last_response.status}"
    assert_equal "Cache is updating, please try again later.", last_response.body
  end

  def test_lock_timeout
    # Acquire a lock with a short timeout (100 milliseconds)
    assert MyApp.acquire_lock(100), "Failed to acquire initial lock"

    # Simulate time passing
    MyApp.with_redis { |redis| redis.simulate_time_passing(0.11) }

    # Verify that the lock can be acquired again
    assert MyApp.acquire_lock, "Failed to acquire lock after timeout"
  end

  def test_update_cache
    MyApp.stubs(:fetch_data).returns({ "value" => "real_data" })

    MyApp.update_cache

    MyApp.with_redis do |redis|
      assert_equal({ "value" => "real_data" }.to_json, redis.get(MyApp.cache_key))
      assert redis.exists("#{MyApp.cache_key}_last_modified")
      assert_equal 86460, redis.ttl(MyApp.cache_key)
    end
  end

  def test_listener_thread_updates_cache
    MyApp.stubs(:fetch_data).returns({ "value" => "real_data" })
    MyApp.stubs(:acquire_lock).returns(true)

    # Simulate the listener thread behavior
    MyApp.with_redis do |redis|
      redis.publish("please_update_now", "true")
    end

    # Manually call the update_cache method to simulate the listener thread's action
    MyApp.update_cache

    MyApp.with_redis do |redis|
      assert_equal({ "value" => "real_data" }.to_json, redis.get(MyApp.cache_key))
      assert redis.exists("#{MyApp.cache_key}_last_modified")
      assert_equal 86460, redis.ttl(MyApp.cache_key)
    end
  end

  private

  def mock_redis
    @mock_redis ||= MockRedis.new
  end

  class MockRedis
    def initialize
      @data = {}
      @expiry = {}
    end

    def set(key, value, options = {})
      if options[:ex]
        @expiry[key] = Time.now.to_i + options[:ex]
      end
      @data[key] = value
      "OK"
    end

    def get(key)
      check_expiry(key)
      @data[key]
    end

    def exists(key)
      check_expiry(key)
      @data.key?(key)
    end

    def expire(key, seconds)
      @expiry[key] = Time.now.to_i + seconds
      true
    end

    def ttl(key)
      check_expiry(key)
      return -2 unless @data.key?(key)
      return -1 unless @expiry.key?(key)
      [@expiry[key] - Time.now.to_i, 0].max
    end

    def del(key)
      @data.delete(key)
      @expiry.delete(key)
      1
    end

    def flushdb
      @data.clear
      @expiry.clear
      "OK"
    end

    def simulate_time_passing(seconds)
      @expiry.each do |key, expiry_time|
        if Time.now.to_f + seconds > expiry_time
          @data.delete(key)
          @expiry.delete(key)
        end
      end
    end

    def publish(channel, message)
      1
    end

    private

    def check_expiry(key)
      if @expiry[key] && Time.now.to_i > @expiry[key]
        @data.delete(key)
        @expiry.delete(key)
      end
    end
  end
end