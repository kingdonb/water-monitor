module Loggable
  LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }

  class << self
    def included(base)
      base.extend(ClassMethods)
    end
  end

  module ClassMethods
    def set_log_level(level)
      @log_level = LOG_LEVELS[level] || 1
    end

    def log_level
      @log_level ||= 1
    end
  end

  [:debug, :info, :warn, :error].each do |level|
    define_method(level) do |message|
      log(level, message)
    end
  end

  private

  def log(level, message)
    if LOG_LEVELS[level] >= self.class.log_level
      puts "[#{level.to_s.upcase}] #{message}"
    end
  end
end