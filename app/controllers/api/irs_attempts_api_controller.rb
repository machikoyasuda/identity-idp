##
# This controller implements the Poll-based delivery method for Security Event
# Tokens as described RFC 8936
#
# ref: https://datatracker.ietf.org/doc/html/rfc8936
#
module Api
  class IrsAttemptsApiController < ApplicationController
    include RenderConditionConcern
    include ActionController::Live

    check_or_render_not_found -> { IdentityConfig.store.irs_attempt_api_enabled }

    skip_before_action :verify_authenticity_token
    before_action :authenticate_client
    prepend_before_action :skip_session_load
    prepend_before_action :skip_session_expiration

    respond_to :json

    def create
      start_time = Time.zone.now.to_f
      if timestamp
        if s3_helper.attempts_serve_events_from_s3
          if IrsAttemptApiLogFile.find_by(requested_time: timestamp_key(key: timestamp))
            log_file_record = IrsAttemptApiLogFile.find_by(
              requested_time: timestamp_key(key: timestamp),
            )
            headers['X-Payload-Key'] = log_file_record.encrypted_key
            headers['X-Payload-IV'] = log_file_record.iv

            serve_s3_response(log_file_record: log_file_record)

          else
            render json: { status: :not_found, description: 'File not found for Timestamp' },
                   status: :not_found
          end
        else
          result = encrypted_security_event_log_result

          headers['X-Payload-Key'] = Base64.strict_encode64(result.encrypted_key)
          headers['X-Payload-IV'] = Base64.strict_encode64(result.iv)

          send_data result.encrypted_data,
                    disposition: "filename=#{result.filename}"
        end
      else
        render json: { status: :unprocessable_entity, description: 'Invalid timestamp parameter' },
               status: :unprocessable_entity
      end
      analytics.irs_attempts_api_events(
        **analytics_properties(
          authenticated: true,
          elapsed_time: elapsed_time(start_time),
        ),
      )
    end

    private

    def buffer_range(current_buffer_index:, buffer_size:, file_size:)
      buffer_end = [current_buffer_index + buffer_size, file_size].min
      "bytes=#{current_buffer_index}-#{buffer_end}"
    end

    def serve_s3_response(log_file_record:)
      if IdentityConfig.store.irs_attempt_api_aws_s3_stream_enabled
        response = s3_helper.s3_client.head_object(
          bucket: s3_helper.attempts_bucket_name,
          key: log_file_record.filename,
        )

        requested_data_size = response.content_length

        buffer_index = 0
        buffer_size = IdentityConfig.store.irs_attempt_api_aws_s3_stream_buffer_size

        send_stream(
          type: response.content_type,
          filename: log_file_record.filename,
        ) do |stream|
          while buffer_index < requested_data_size
            requested_data = s3_helper.s3_client.get_object(
              bucket: s3_helper.attempts_bucket_name,
              key: log_file_record.filename,
              range: buffer_range(
                current_buffer_index: buffer_index,
                buffer_size: buffer_size,
                file_size: requested_data_size,
              ),
            )
            buffer_index += buffer_size + 1
            stream.write(requested_data.body.read)
          end
        end
      else
        requested_data = s3_helper.s3_client.get_object(
          bucket: s3_helper.attempts_bucket_name,
          key: log_file_record.filename,
        )

        send_data requested_data.body.read,
                  disposition: "filename=#{log_file_record.filename}"
      end
    end

    def authenticate_client
      bearer, csp_id, token = request.authorization&.split(' ', 3)
      if bearer != 'Bearer' || !valid_auth_token?(token) ||
         csp_id != IdentityConfig.store.irs_attempt_api_csp_id
        analytics.irs_attempts_api_events(
          **analytics_properties(
            authenticated: false,
            elapsed_time: 0,
          ),
        )
        render json: { status: 401, description: 'Unauthorized' }, status: :unauthorized
      end
    end

    def valid_auth_token?(token)
      valid_auth_data = hashed_valid_auth_data
      cost = valid_auth_data[:cost]
      salt = valid_auth_data[:salt]
      hashed_token = scrypt_digest(token: token, salt: salt, cost: cost)

      valid_auth_data[:digested_tokens].any? do |valid_hashed_token|
        ActiveSupport::SecurityUtils.secure_compare(
          valid_hashed_token,
          hashed_token,
        )
      end
    end

    def scrypt_digest(token:, salt:, cost:)
      scrypt_salt = cost + OpenSSL::Digest::SHA256.hexdigest(salt)
      scrypted = SCrypt::Engine.hash_secret token, scrypt_salt, 32
      SCrypt::Password.new(scrypted).digest
    end

    # @return [Array<String>] JWE strings
    def security_event_tokens
      return [] unless timestamp

      events = redis_client.read_events(timestamp: timestamp)
      events.values
    end

    def encrypted_security_event_log_result
      IrsAttemptsApi::EnvelopeEncryptor.encrypt(
        data: security_event_tokens.join("\r\n"),
        timestamp: timestamp,
        public_key_str: IdentityConfig.store.irs_attempt_api_public_key,
      )
    end

    def timestamp_key(key:)
      IrsAttemptsApi::EnvelopeEncryptor.formatted_timestamp(key)
    end

    def redis_client
      @redis_client ||= IrsAttemptsApi::RedisClient.new
    end

    def s3_helper
      @s3_helper ||= JobHelpers::S3Helper.new
    end

    def hashed_valid_auth_data
      key = IdentityConfig.store.irs_attempt_api_auth_tokens.map do |token|
        OpenSSL::Digest::SHA256.hexdigest(token)
      end.join(',')

      Rails.cache.fetch("irs_hashed_tokens:#{key}", expires_in: 48.hours) do
        salt = SecureRandom.hex(32)
        cost = IdentityConfig.store.scrypt_cost
        digested_tokens = IdentityConfig.store.irs_attempt_api_auth_tokens.map do |token|
          scrypt_digest(token: token, salt: salt, cost: cost)
        end

        {
          salt: salt,
          cost: cost,
          digested_tokens: digested_tokens,
        }
      end
    end

    def analytics_properties(authenticated:, elapsed_time:)
      {
        rendered_event_count: security_event_tokens.count,
        timestamp: timestamp&.iso8601,
        elapsed_time: elapsed_time,
        authenticated: authenticated,
        success: authenticated && timestamp.present?,
      }
    end

    def timestamp
      timestamp_param = params.permit(:timestamp)[:timestamp]
      return nil if timestamp_param.nil?

      date_fmt = timestamp_param.include?('.') ? '%Y-%m-%dT%H:%M:%S.%N%z' : '%Y-%m-%dT%H:%M:%S%z'

      Time.strptime(timestamp_param, date_fmt)
    rescue ArgumentError
      nil
    end

    def elapsed_time(start_time)
      Time.zone.now.to_f - start_time
    end
  end
end
