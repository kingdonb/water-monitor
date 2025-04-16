require 'concurrent'
require_relative 'loggable'

class StateManager
  include Loggable

  def initialize
    @cache_status = Concurrent::Atom.new(:unknown)
    @cache15_status = Concurrent::Atom.new(:unknown)
    @redis_status = Concurrent::Atom.new(:unknown)
    @last_cache_update = Concurrent::Atom.new(nil)
    @last_cache15_update = Concurrent::Atom.new(nil)
    @error_count = Concurrent::Atom.new(0)
  end

  def update_cache_status(status)
    @cache_status.swap { status }
    @last_cache_update.swap { Time.now } if status == :ready
  end

  def update_cache15_status(status)
    @cache15_status.swap { status }
    @last_cache15_update.swap { Time.now } if status == :ready
  end

  def update_redis_status(status)
    @redis_status.swap { status }
  end

  def increment_error_count
    @error_count.swap { |count| count + 1 }
  end

  def reset_error_count
    @error_count.swap { 0 }
  end

  def health_check
    {
      cache_status: @cache_status.value,
      cache15_status: @cache15_status.value,
      redis_status: @redis_status.value,
      last_cache_update: @last_cache_update.value,
      last_cache15_update: @last_cache15_update.value,
      error_count: @error_count.value
    }
  end
end
