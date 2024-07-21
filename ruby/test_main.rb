require 'bundler/setup'
require 'rack/test'
require 'minitest/autorun'
require 'mocha/minitest'
require_relative 'logger'
require_relative 'main'

# Set the log level for tests
Loggable.set_log_level(:error)

class MyAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= MyApp.new(nil, mock_redis)
  end

  def setup
    MyApp.redis = mock_redis
    MyApp.lock_key = "update_lock"
    MyApp.cache_key = "cached_data"
    MyApp.lock_cv = ConditionVariable.new
    MyApp.lock_mutex = Mutex.new
  end

  def teardown
    mock_redis.flushdb
  end

  def test_data_endpoint_when_cache_ready
    # Use valid data instead of test data
    valid_data = { "value" => "real_data" }.to_json
    MyApp.redis.set(MyApp.cache_key, valid_data)
    get '/data'
    assert last_response.ok?
    assert_equal 'application/json', last_response.content_type
    assert_equal valid_data, last_response.body
  end

  def test_data_endpoint_when_cache_not_ready
    MyApp.redis.del(MyApp.cache_key)
    get '/data'
    assert_equal 202, last_response.status
    assert_equal "Cache is updating, please try again later.", last_response.body
  end

  def test_lock_timeout
    # Acquire a lock with a short timeout (100 milliseconds)
    assert MyApp.acquire_lock(100), "Failed to acquire initial lock"

    # Simulate time passing
    mock_redis.simulate_time_passing(0.11)

    # Verify that the lock can be acquired again
    assert MyApp.acquire_lock, "Failed to acquire lock after timeout"
  end

  def test_update_cache
    MyApp.stubs(:fetch_data).returns({ "value" => "real_data" })
    MyApp.stubs(:redis).returns(mock_redis)

    MyApp.update_cache

    assert_equal({ "value" => "real_data" }.to_json, mock_redis.get(MyApp.cache_key))
  end

  def test_listener_thread_updates_cache
    MyApp.stubs(:fetch_data).returns({ "value" => "real_data" })
    MyApp.stubs(:redis).returns(mock_redis)
    MyApp.stubs(:acquire_lock).returns(true)

    # Simulate the listener thread behavior
    app_instance = MyApp.new!
    app_instance.on_message("please_update_now", "true")

    assert_equal({ "value" => "real_data" }.to_json, mock_redis.get(MyApp.cache_key))
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
      if options[:nx] && @data.key?(key)
        return false
      end
      @data[key] = value
      if options[:px]
        @expiry[key] = Time.now.to_f + (options[:px] / 1000.0)
      end
      true
    end

    def get(key)
      check_expiry(key)
      @data[key]
    end

    def exists(key)
      check_expiry(key)
      @data.key?(key)
    end

    def publish(channel, message)
      # Simulate publish
    end

    def del(key)
      @data.delete(key)
      @expiry.delete(key)
    end

    def flushdb
      @data.clear
      @expiry.clear
    end

    def simulate_time_passing(seconds)
      @expiry.each do |key, expiry_time|
        if Time.now.to_f + seconds > expiry_time
          @data.delete(key)
          @expiry.delete(key)
        end
      end
    end

    private

    def check_expiry(key)
      if @expiry[key] && Time.now.to_f > @expiry[key]
        @data.delete(key)
        @expiry.delete(key)
      end
    end
  end
end