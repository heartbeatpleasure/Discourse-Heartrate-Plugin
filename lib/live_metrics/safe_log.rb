# frozen_string_literal: true

module ::LiveMetrics
  class SafeLog
    MAX_VALUE_LENGTH = 80

    class << self
      def warn(event, error: nil, **fields)
        write(:warn, event, error: error, **fields)
      end

      def error(event, error: nil, **fields)
        write(:error, event, error: error, **fields)
      end

      def info(event, **fields)
        write(:info, event, **fields)
      end

      def exception_class(error)
        safe_identifier(error&.class&.name.presence || "unknown_error")
      end

      private

      def write(level, event, error: nil, **fields)
        payload = fields.compact.transform_values { |value| safe_value(value) }
        if error
          payload[:error_class] = exception_class(error)
          status = error.respond_to?(:status) ? error.status.to_i : 0
          payload[:status] = status if status.positive?
        end

        suffix = payload.map { |key, value| "#{safe_identifier(key)}=#{value}" }.join(" ")
        message = "[live_metrics] #{safe_identifier(event)}"
        message = "#{message} #{suffix}" if suffix.present?
        Rails.logger.public_send(level, message)
      rescue => logging_error
        Rails.logger.warn(
          "[live_metrics] safe_log_failed error_class=#{exception_class(logging_error)}",
        )
      end

      def safe_value(value)
        case value
        when Integer
          value
        when TrueClass, FalseClass
          value
        else
          safe_identifier(value)
        end
      end

      def safe_identifier(value)
        normalized = value.to_s.gsub(/[^a-zA-Z0-9_.:\-]/, "_")
        normalized = "unknown" if normalized.blank?
        normalized.byteslice(0, MAX_VALUE_LENGTH)
      end
    end
  end
end
