require 'minitest/autorun'
require 'rack/test'
require 'mocha/minitest'
require_relative 'main'

Logging.log_level = :error

class MyAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    MyApp.new
  end

  def setup
    MyApp.redis.flushdb
  end

  def teardown
    MyApp.redis.flushdb
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

  def test_cache_update_via_listener_thread
    Logging.log_level = :debug  # Temporarily enable debug logging
    MyApp.stubs(:fetch_data).returns({ "value" => "real_data" })

    MyApp.start_threads

    MyApp.redis.publish("please_update_now", "true")

    assert wait_for_cache_update, "Cache was not updated within the expected time"

    cached_data = MyApp.redis.get(MyApp.cache_key)
    puts "Cached data: #{cached_data.inspect}"

    refute_nil cached_data, "Cached data is nil"

    parsed_data = JSON.parse(cached_data)
    assert_equal "real_data", parsed_data["value"]
  ensure
    Logging.log_level = :error  # Reset log level
  end

  def test_lock_timeout
    # Acquire a lock with a short timeout
    assert MyApp.acquire_lock(1000), "Failed to acquire initial lock"

    # Wait for the lock to expire
    sleep 1.1

    # Verify that the lock can be acquired again
    assert MyApp.acquire_lock, "Failed to acquire lock after timeout"
  end

  def wait_for_cache_update(max_wait_time = 5)
    start_time = Time.now
    updated = false
    while Time.now - start_time < max_wait_time && !updated
      if MyApp.redis.exists(MyApp.cache_key)
        updated = true
        puts "Cache updated after #{Time.now - start_time} seconds"
      else
        sleep 0.1
      end
    end
    updated
  end
end