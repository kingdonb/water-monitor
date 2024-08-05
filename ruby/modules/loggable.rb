module Loggable
  DEFAULT_LOG_LEVEL = :info
  LOG_LEVELS = { debu: 0, info: 1, erro: 2 }
  LOG_LEVEL_NAMES = { debu: 'DEBUG', info: 'INFO', erro: 'ERROR' }

  def self.included(base)
    base.extend(ClassMethods)
    base.instance_variable_set(:@log_level, LOG_LEVELS[DEFAULT_LOG_LEVEL])
  end

  module ClassMethods
    def set_log_level(level)
      level = case level
              when Integer then LOG_LEVELS.key(level)
              when String, Symbol then level.to_s[0..3].downcase.to_sym
              else raise ArgumentError, "Invalid log level: #{level}"
              end
      unless LOG_LEVELS.key?(level)
        raise ArgumentError, "Invalid log level: #{level}"
      end
      Thread.current[:log_level] = LOG_LEVELS[level]
      @log_level = LOG_LEVELS[level]
    end

    def log_level
      Thread.current[:log_level] || @log_level
    end
  end

  extend ClassMethods

  [:debu, :info, :erro].each do |level|
    define_method(level) do |message|
      log(level, message)
    end
  end

  def log_request(request:, response:, data_sent:, compressed:, level: :info)
    path = request.path_info
    status = response.status
    response_body = if response.body.respond_to? :first
                      response.body.first
                    else
                      response.body
                    end
    data_size = data_sent ? response_body&.bytesize : 0
    compression_status = compressed ? "compressed" : "uncompressed"
    cache_status = data_sent ? "served" : "not served"

    message = "Request: #{path} | Status: #{status} | Data: #{cache_status} (#{data_size} bytes, #{compression_status})"

    log(level, message)
  end

  private

  def log(level, message)
    level_sym = level.to_s[0..3].downcase.to_sym
    if LOG_LEVELS[level_sym] >= current_log_level
      puts "[#{LOG_LEVEL_NAMES[level_sym]}] #{message}"
    end
  end

  def current_log_level
    Thread.current[:log_level] ||
      if self.class.singleton_class.included_modules.include?(Loggable)
        self.class.instance_variable_get(:@log_level) || LOG_LEVELS[DEFAULT_LOG_LEVEL]
      else
        self.class.ancestors.find { |a| a.instance_variable_defined?(:@log_level) }&.instance_variable_get(:@log_level) || LOG_LEVELS[DEFAULT_LOG_LEVEL]
      end
  end
end