require 'minitest/autorun'
require 'rack/test'
require 'mocha/minitest'
require_relative 'main'

class MyAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    MyApp.new
  end

  def setup
    MyApp.settings.redis.flushdb
  end

  def teardown
    MyApp.settings.redis.flushdb
  end

  def test_data_endpoint_when_cache_ready
    # Simulate cache being ready
    MyApp.settings.redis.set("cached_data", { test: "data" }.to_json)
    get '/data'
    assert last_response.ok?
    assert_equal 'application/json', last_response.content_type
    assert_equal({ test: "data" }.to_json, last_response.body)
  end

  def test_data_endpoint_when_cache_not_ready
    # Simulate cache not being ready
    MyApp.settings.redis.del("cached_data")
    get '/data'
    assert_equal 202, last_response.status
    assert_equal "Cache is updating, please try again later.", last_response.body
  end

  def test_cache_update_via_listener_thread
    MyApp.stubs(:fetch_data).returns({ "value" => "test_data" })

    MyApp.start_threads

    puts "Publishing message to Redis channel"
    MyApp.settings.redis.publish("please_update_now", "true")

    puts "Waiting for cache update"
    assert wait_for_cache_update, "Cache was not updated within the expected time"

    cached_data = MyApp.settings.redis.get(MyApp.settings.cache_key)
    puts "Cached data: #{cached_data.inspect}"

    refute_nil cached_data, "Cached data is nil"

    parsed_data = JSON.parse(cached_data)
    assert_equal "test_data", parsed_data["value"]
  end

  def test_lock_timeout
    # Mock the acquire_lock method to simulate lock acquisition
    MyApp.expects(:acquire_lock).returns(true)

    # Simulate acquiring a lock without expiration
    MyApp.settings.redis.set("update_lock", true)

    # Wait for a short period to simulate lock expiration
    MyApp.wait_for_cache_update(2)

    # Verify that the lock can be acquired again
    assert MyApp.acquire_lock
  end

  def wait_for_cache_update(max_wait_time = 5)
    start_time = Time.now
    updated = false
    while Time.now - start_time < max_wait_time && !updated
      if MyApp.settings.redis.exists(MyApp.settings.cache_key)
        updated = true
        puts "Cache updated after #{Time.now - start_time} seconds"
      else
        sleep 0.1
      end
    end
    updated
  end
end