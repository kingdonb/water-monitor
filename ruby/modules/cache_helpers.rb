require_relative 'loggable'

require 'net/http'

COMPRESSION_LEVEL = 1  # You can adjust this value as needed

module CacheHelpers
  include Loggable

  CACHE_DURATION = 86_400 # expire caches after 1 day (testing: after 60s)
  CACHE_15_DURATION = 15 * 60 # 15 minutes cache duration
  CACHE_2_DURATION = 2 * 60 # 2 minutes cache duration
  LOCK_TIMEOUT = 15_000 # 15 seconds in milliseconds
  CACHE_CONTROL_HEADER = "public, max-age=#{CACHE_DURATION}, must-revalidate"
  CACHE_15_CONTROL_HEADER = "public, max-age=#{CACHE_15_DURATION}, must-revalidate"
  GZIP_ENCODING = 'gzip'

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def backend_url
      end_date = Time.now.strftime("%F")
      url = "https://waterservices.usgs.gov/nwis/dv/?format=json&sites=04096405,04096515,04097500,040975299,04097540,04099000,04100500,04101000,04101500,04101800,04102500,04099750&statCd=00003&siteStatus=all&startDT=2000-01-01&endDT=#{end_date}"
      debu("backend_url: #{url}")
      url
    end

    def fetch_data
      debu("Fetching data from backend")
      url = backend_url
      uri = URI(url)
      response = Net::HTTP.get_response(uri)

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        response_body = if response.body.respond_to? :first
                          response.body.first
                        else
                          response.body
                        end
        response_size = response_body.bytesize
        debu("Data fetched successfully. Response size: #{response_size} bytes")
        if response_size <= 400
          debu("Response body: #{response.body}")
        else
          debu("Response body too large to print (> 400 bytes)")
        end
        data
      else
        erro("Error fetching data: #{response.code} #{response.message}")
        nil
      end
    rescue StandardError => e
      erro("Exception while fetching data: #{e.message}")
      nil
    end

    def cache_ready?
      current_time = Time.now
      if @last_redis_check.nil? || current_time - @last_redis_check > 5 || ENV['RACK_ENV'] == 'test'
        with_redis do |redis|
          last_modified = redis.get("#{cache_key}_last_modified")
          @in_memory_last_modified = last_modified
          @in_memory_etag = redis.get("#{cache_key}_etag")
          @in_memory_compressed_data = redis.get("#{cache_key}_compressed")
        end
        @last_redis_check = current_time
      end

      return false if @in_memory_compressed_data.nil? || @in_memory_compressed_data.empty? ||
                    @in_memory_last_modified.nil? || @in_memory_last_modified.empty? ||
                    @in_memory_etag.nil? || @in_memory_etag.empty?

      last_modified_time = Time.parse(@in_memory_last_modified)
      if current_time - last_modified_time > CACHE_DURATION # 24 hours
        debu("Cache not ready: data is stale")
        return false
      end

      true
    rescue StandardError => e
      erro("Error checking cache readiness: #{e.message}")
      false
    end

    def cache15_ready?
      current_time = Time.now
      if @last_redis15_check.nil? || current_time - @last_redis15_check > 5 || ENV['RACK_ENV'] == 'test'
        with_redis do |redis|
          last_modified = redis.get("#{cache_key}15_last_modified")
          @in_memory_last15_modified = last_modified
          @in_memory_etag15 = redis.get("#{cache_key}15_etag")
          @in_memory_compressed_data15 = redis.get("#{cache_key}15_compressed")
        end
        @last_redis15_check = current_time
      end

      return false if @in_memory_compressed_data15.nil? || @in_memory_compressed_data15.empty? ||
                    @in_memory_last15_modified.nil? || @in_memory_last15_modified.empty? ||
                    @in_memory_etag15.nil? || @in_memory_etag15.empty?

      last_modified_time = Time.parse(@in_memory_last15_modified)
      if current_time - last_modified_time > CACHE_15_DURATION # 15 minutes
        debu("Cache15 not ready: data15 is stale")
        return false
      end

      true
    rescue StandardError => e
      erro("Error checking cache15 readiness: #{e.message}")
      false
    end

    def acquire_lock(timeout = LOCK_TIMEOUT)
      with_redis do |redis|
        acquired = redis.set(lock_key, true, nx: true, px: timeout)
        debu("Lock acquisition attempt result: #{acquired}")
        acquired
      end
    end

    def update_cache
      debu("Updating cache")
      data = fetch_data
      if data.nil? || data.empty?
        erro("Error: Fetched data is nil or empty")
        return
      end
      json_data = data.to_json
      compressed_data = StringIO.new.tap do |io|
        gz = Zlib::GzipWriter.new(io, COMPRESSION_LEVEL)
        gz.write(json_data)
        gz.close
      end.string
      etag = Digest::MD5.hexdigest(json_data)
      current_time = Time.now.httpdate

      with_redis do |redis|
        if redis.respond_to?(:multi)
          redis.multi do |multi|
            set_cache_data(multi, json_data, compressed_data, etag, current_time)
          end
        else
          set_cache_data(redis, json_data, compressed_data, etag, current_time)
        end
      end

      @in_memory_compressed_data = compressed_data
      @in_memory_etag = etag
      @in_memory_last_modified = current_time

      # Update cache status to ready after successful update
      settings.state_manager.update_cache_status(:ready)

      debu("Cache updated, new value size: #{json_data.bytesize} bytes, compressed size: #{compressed_data.bytesize} bytes")
      release_lock
      debu("Cache updated and lock released")
    end

    def update_cache15
      debu("Updating cache15")
      data = fetch_data
      if data.nil? || data.empty?
        erro("Error: Fetched data15 is nil or empty")
        return
      end
      json_data = data.to_json
      compressed_data = StringIO.new.tap do |io|
        gz = Zlib::GzipWriter.new(io, COMPRESSION_LEVEL)
        gz.write(json_data)
        gz.close
      end.string
      etag = Digest::MD5.hexdigest(json_data)
      current_time = Time.now.httpdate

      with_redis do |redis|
        if redis.respond_to?(:multi)
          redis.multi do |multi|
            set_cache_data15(multi, json_data, compressed_data, etag, current_time)
          end
        else
          set_cache_data15(redis, json_data, compressed_data, etag, current_time)
        end
      end

      @in_memory_compressed_data15 = compressed_data
      @in_memory_etag15 = etag
      @in_memory_last15_modified = current_time

      # Update cache status to ready after successful update
      settings.state_manager.update_cache_status(:ready)

      debu("Cache15 updated, new value size: #{json_data.bytesize} bytes, compressed size: #{compressed_data.bytesize} bytes")
      release_lock
      debu("Cache15 updated and lock released")
    end

    def set_cache_data(redis, json_data, compressed_data, etag, current_time)
      expiry_time = CACHE_DURATION - 30
      redis.set(cache_key, json_data)
      redis.set("#{cache_key}_compressed", compressed_data)
      redis.set("#{cache_key}_last_modified", current_time)
      redis.set("#{cache_key}_etag", etag)
      redis.expire(cache_key, expiry_time) # Set TTL to 24 hours - 30s
      redis.expire("#{cache_key}_compressed", expiry_time)
      redis.expire("#{cache_key}_last_modified", expiry_time)
      redis.expire("#{cache_key}_etag", expiry_time)
    end

    def set_cache_data15(redis, json_data, compressed_data, etag, current_time)
      expiry_time = CACHE_DURATION - 30
      redis.set(cache_key, json_data)
      redis.set("#{cache_key}_compressed", compressed_data)
      redis.set("#{cache_key}_last_modified", current_time)
      redis.set("#{cache_key}_etag", etag)
      redis.expire(cache_key, expiry_time) # Set TTL to 24 hours - 30s
      redis.expire("#{cache_key}_compressed", expiry_time)
      redis.expire("#{cache_key}_last_modified", expiry_time)
      redis.expire("#{cache_key}_etag", expiry_time)
    end

    def release_lock
      with_redis do |redis|
        redis.del(lock_key)
      end
      debu("Lock released")
    end
  end

  def redis
    Thread.current[:redis] ||= Redis.new
  end

  def lock_key
    self.class.lock_key
  end

  def cache_key
    self.class.cache_key
  end
end
