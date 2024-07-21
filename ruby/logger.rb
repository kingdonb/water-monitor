module Loggable
  LOG_LEVELS = { debug: 0, info: 1, warn: 2, erro: 3 }

  def self.included(base)
    base.extend(ClassMethods)
    base.instance_variable_set(:@log_level, LOG_LEVELS[:info])
  end

  module ClassMethods
    def set_log_level(level)
      @log_level = LOG_LEVELS[level] || LOG_LEVELS[:info]
    end

    def log_level
      @log_level
    end
  end

  extend ClassMethods

  [:debug, :info, :warn, :erro].each do |level|
    define_method(level) do |message|
      log(level, message)
    end
  end

  private

  def log(level, message)
    if LOG_LEVELS[level] >= current_log_level
      puts "[#{level.to_s.upcase}] #{message}"
    end
  end

  def current_log_level
    if self.class.singleton_class.included_modules.include?(Loggable)
      self.class.instance_variable_get(:@log_level) || LOG_LEVELS[:info]
    else
      self.class.ancestors.find { |a| a.instance_variable_defined?(:@log_level) }&.instance_variable_get(:@log_level) || LOG_LEVELS[:info]
    end
  end
end