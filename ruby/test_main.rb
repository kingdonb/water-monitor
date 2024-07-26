require 'minitest/autorun'
require 'rack/test'
require 'mocha/minitest'
require 'zlib'
require_relative '../ruby/main'

class MyAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    MyApp
  end

  def setup
    MyApp.initialize_app
    MyApp.redis_pool = ConnectionPool.new(size: 5, timeout: 5) { MockRedis.new }
  end

  def test_data_endpoint_when_cache_ready
    compressed_data = Zlib::Deflate.deflate('{"test":"data"}')
    MyApp.stubs(:cache_ready?).returns(true)
    MyApp.stubs(:in_memory_compressed_data).returns(compressed_data)
    MyApp.stubs(:in_memory_etag).returns('etag123')
    MyApp.stubs(:in_memory_last_modified).returns(Time.now.httpdate)

    # Test with a client that accepts gzip
    header 'Accept-Encoding', 'gzip'
    get '/data'
    assert_equal 200, last_response.status
    assert_equal 'gzip', last_response.headers['Content-Encoding']
    assert_equal compressed_data, last_response.body

    # Test with a client that doesn't accept gzip
    header 'Accept-Encoding', ''
    get '/data'
    assert_equal 200, last_response.status
    assert_nil last_response.headers['Content-Encoding']
    assert_equal '{"test":"data"}', last_response.body
  end

  def test_data_endpoint_when_cache_not_ready
    MyApp.stubs(:cache_ready?).returns(false)

    get '/data'
    assert_equal 202, last_response.status
    assert_equal 'Cache is updating, please try again later.', last_response.body
  end

  def test_cache_update_process
    mock_data = { 'key' => 'value' }
    MyApp.stubs(:fetch_data).returns(mock_data)
    MyApp.stubs(:acquire_lock).returns(true)
    MyApp.stubs(:release_lock).returns(true)

    MyApp.update_cache

    MyApp.with_redis do |redis|
      assert redis.exists(MyApp.cache_key)
      assert redis.exists("#{MyApp.cache_key}_compressed")
      assert redis.exists("#{MyApp.cache_key}_last_modified")
      assert redis.exists("#{MyApp.cache_key}_etag")
    end
  end

  def test_healthz_endpoint
    get '/healthz'
    assert_equal 200, last_response.status
    assert_equal 'Health OK', last_response.body
  end

  def test_cron_thread_updates_cache
    MyApp.cron_interval = 1 # Set to 1 second for testing
    MyApp.stubs(:cache_ready?).returns(false)
    MyApp.expects(:update_cache).at_least(2)

    # Start the cron thread
    MyApp.start_threads

    # Wait for the cron thread to run
    # (it runs once on startup, then again after cron_interval)
    sleep 2

    # No need to call MyApp.shutdown here

    # Verify that update_cache was called
    # The expectation is automatically verified when the test method ends
  end

  def teardown
    # Stop the threads
    MyApp.instance_variable_get(:@cron_thread)&.kill
    MyApp.instance_variable_get(:@listener_thread)&.kill

    # Reset any stubbed methods
    MyApp.unstub(:cache_ready?)
    MyApp.unstub(:update_cache)

    # Reset the cron interval
    MyApp.cron_interval = nil
  end
end

class MockRedis
  def initialize
    @data = {}
  end

  def set(key, value, options = {})
    @data[key] = value
  end

  def get(key)
    @data[key]
  end

  def exists(key)
    @data.key?(key)
  end

  def multi
    yield self
  end

  def expire(key, ttl)
    # Simulate expire (not actually implemented for this mock)
  end

  def del(key)
    @data.delete(key)
  end

  def publish(channel, message)
    # Simulate publish (not actually implemented for this mock)
  end
end