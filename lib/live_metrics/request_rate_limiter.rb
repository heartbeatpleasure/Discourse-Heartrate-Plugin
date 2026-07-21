# frozen_string_literal: true

require "digest"

module ::LiveMetrics
  class RequestRateLimiter
    LIMITS = {
      user_search: { max: 60, seconds: 1.minute },
      provider_connect: { max: 12, seconds: 5.minutes },
      provider_disconnect: { max: 12, seconds: 5.minutes },
      provider_reconnect: { max: 1, seconds: 30.seconds },
      audience_mutation: { max: 60, seconds: 1.minute },
      settings_mutation: { max: 60, seconds: 1.minute },
      directory: { max: 180, seconds: 1.minute },
      badge_status: { max: 120, seconds: 1.minute },
      user_cards: { max: 240, seconds: 1.minute },
    }.freeze

    class << self
      def perform!(action, user:, request:)
        action = action.to_sym
        limit = LIMITS.fetch(action)
        type = "live_metrics_#{action}"
        type = "#{type}_#{anonymous_identity(request)}" if user.blank?

        RateLimiter.new(
          user,
          type,
          limit.fetch(:max),
          limit.fetch(:seconds),
          error_code: "live_metrics_#{action}_limit",
          apply_limit_to_staff: true,
        ).performed!
      end

      private

      def anonymous_identity(request)
        value = request&.remote_ip.to_s.presence || "unknown"
        Digest::SHA256.hexdigest(value).first(16)
      end
    end
  end
end
