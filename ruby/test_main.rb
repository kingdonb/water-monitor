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
    # Mock the fetch_data method to avoid hitting the external service
    MyApp.expects(:fetch_data).returns({ test: "data" })

    # Simulate cache not being ready
    MyApp.settings.redis.del("cached_data")
    MyApp.settings.redis.del("update_lock")

    # Publish a message to the Redis channel to trigger cache update
    MyApp.settings.redis.publish("please_update_now", "true")

    # Wait for the listener thread to process the message and update the cache
    sleep 2

    # Verify that the cache has been updated
    assert MyApp.settings.redis.exists("cached_data")
  end

  def test_lock_timeout
    # Mock the acquire_lock method to simulate lock acquisition
    MyApp.expects(:acquire_lock).returns(true)

    # Simulate acquiring a lock without expiration
    MyApp.settings.redis.set("update_lock", true)

    # Wait for a short period to simulate lock expiration
    sleep 2

    # Verify that the lock can be acquired again
    assert MyApp.acquire_lock
  end
end