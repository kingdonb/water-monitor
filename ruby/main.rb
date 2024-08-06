require_relative 'modules/my_app'

#require 'redis'
#require 'json'
#require 'concurrent'
#require 'digest/md5'
#require 'connection_pool'
#require 'zlib'

# Set the log level for MyApp
MyApp.set_log_level(ENV['LOG_LEVEL'] ? ENV['LOG_LEVEL'].to_sym : Loggable::DEFAULT_LOG_LEVEL)

# Initialize the app
MyApp.initialize_app(ENV['REDIS_URL'])

if __FILE__ == $0
  # Start the application and threads only when the script is run directly
  server_thread = Thread.new do
    MyApp.run!
  end

  # Ensure the server has time to start
  sleep 0

  # Tell the cron_thread how often it should fire
  MyApp.cron_interval = CacheHelpers::CACHE_DURATION

  # Start background threads
  MyApp.start_threads

  # Keep the main thread alive to handle interrupts
  server_thread.join
end
