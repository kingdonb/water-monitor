module Loggable
  LOG_LEVELS = { debu: 0, info: 1, warn: 2, erro: 3 }

  def self.included(base)
    base.extend(ClassMethods)
    base.instance_variable_set(:@log_level, LOG_LEVELS[:info])
  end

  module ClassMethods
    def set_log_level(level)
      level = level&.[](...4)&.to_sym || level || :info
      unless LOG_LEVELS.key?(level)
        raise ArgumentError, "Invalid log level: #{level}"
      end
      @log_level = LOG_LEVELS[level]
    end

    def log_level
      @log_level
    end
  end

  extend ClassMethods

  [:debu, :info, :warn, :erro].each do |level|
    define_method(level) do |message|
      log(level, message)
    end
  end

  def log_request(request:, response:, data_sent:, compressed:, level: :info)
    path = request.path_info
    status = response.status
    data_size = data_sent ? response.body&.first&.bytesize : 0
    compression_status = compressed ? "compressed" : "uncompressed"
    cache_status = data_sent ? "served" : "not served"

    message = "Request: #{path} | Status: #{status} | Data: #{cache_status} (#{data_size} bytes, #{compression_status})"

    log(level, message)
  end

  private

  def log(level, message)
  # in case :debug or :error is passed in, use :debu and :erro instead
    level_sym = level.to_s[...4].to_sym
    if LOG_LEVELS[level_sym] >= current_log_level
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