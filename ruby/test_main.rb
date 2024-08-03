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
    MyApp.settings.state_manager = StateManager.new
    MyApp.settings.state_manager.update_redis_status(:connected)
  end

  def self.log_message(level, message)
    MyApp.send(level, message)
  end

  def test_data_endpoint_when_cache_ready
    compressed_data = Zlib::Deflate.deflate('{"test":"data"}')
    MyApp.stubs(:cache_ready?).returns(true)
    MyApp.stubs(:in_memory_compressed_data).returns(compressed_data)
    MyApp.stubs(:in_memory_etag).returns('etag123')
    MyApp.stubs(:in_memory_last_modified).returns(Time.now.httpdate)
    MyApp.settings.state_manager.update_cache_status(:ready)

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
    MyApp.settings.state_manager.update_cache_status(:updating)

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
    mock_state_manager = Minitest::Mock.new
    mock_state_manager.expect :health_check, {
      cache_status: :ready,
      redis_status: :connected,
      last_cache_update: Time.now,
      error_count: 0
    }

    MyApp.settings.stubs(:state_manager).returns(mock_state_manager)

    get '/healthz'
    assert_equal 200, last_response.status
    health_status = JSON.parse(last_response.body)
    assert_equal 'ready', health_status['cache_status']
    assert_equal 'connected', health_status['redis_status']
    assert_includes health_status.keys, 'last_cache_update'
    assert_equal 0, health_status['error_count']

    mock_state_manager.verify
  end

  def test_healthz_endpoint_with_errors
    MyApp.settings.state_manager.update_cache_status(:error)
    MyApp.settings.state_manager.update_redis_status(:disconnected)
    MyApp.settings.state_manager.increment_error_count
    get '/healthz'
    assert_equal 503, last_response.status
    health_status = JSON.parse(last_response.body)
    assert_equal 'error', health_status['cache_status']
    assert_equal 'disconnected', health_status['redis_status']
    assert_equal 1, health_status['error_count']
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

  def test_log_level_consistency
    original_stdout = $stdout
    $stdout = StringIO.new

    MyApp.set_log_level(:debu)

    # Start a new thread that logs a message
    thread = Thread.new do
      MyAppTest.log_message(:debu, "Test message from thread")
    end
    thread.join

    # Log a message from the main thread
    MyAppTest.log_message(:debu, "Test message from main")

    output = $stdout.string
    $stdout = original_stdout

    assert_includes output, "[DEBUG] Test message from thread"
    assert_includes output, "[DEBUG] Test message from main"
    refute_includes output, "[DEBU]"
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