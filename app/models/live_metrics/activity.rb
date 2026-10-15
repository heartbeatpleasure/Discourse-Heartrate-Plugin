# frozen_string_literal: true

module ::LiveMetrics
  class Activity < ActiveRecord::Base
    self.table_name = "live_metrics_activities"

    belongs_to :user

    DURATION_OPTIONS = [30, 60, 120, 180, 240, 360, 480, 600, 720, 1440].freeze
    MAX_LABEL_LENGTH = 60
    MAX_INPUT_BYTES = 512

    class << self
      def enabled?
        SiteSetting.live_metrics_activity_enabled && (
          SiteSetting.live_metrics_activity_custom_enabled ||
          (SiteSetting.live_metrics_activity_predefined_enabled && options.present?)
        )
      end

      def options
        return [] unless SiteSetting.live_metrics_activity_predefined_enabled

        Array(SiteSetting.live_metrics_activity_options).flat_map { |value| value.to_s.split("|") }
          .map { |value| value.strip.gsub(/[[:cntrl:]\u2028\u2029]/, "") }
          .select { |value| value.present? && value.length <= MAX_LABEL_LENGTH && value != "__custom__" }
          .uniq { |value| value.downcase }
          .first(60)
      end

      def default_minutes(label)
        entry = Array(SiteSetting.live_metrics_activity_duration_overrides)
          .flat_map { |value| value.to_s.split("|") }
          .find do |value|
            candidate, = value.split(":", 2)
            candidate.to_s.strip.casecmp?(label.to_s.strip)
          end
        configured = entry.to_s.split(":", 2).last.to_i if entry
        return configured if DURATION_OPTIONS.include?(configured)

        fallback = SiteSetting.live_metrics_activity_default_duration_minutes.to_i
        DURATION_OPTIONS.include?(fallback) ? fallback : 240
      end

      def config
        {
          enabled: enabled?,
          predefined_enabled: SiteSetting.live_metrics_activity_predefined_enabled,
          custom_enabled: SiteSetting.live_metrics_activity_custom_enabled,
          details_enabled: SiteSetting.live_metrics_activity_details_enabled,
          options: options,
          max_text_length: SiteSetting.live_metrics_activity_max_text_length.to_i,
          expiry_mode: SiteSetting.live_metrics_activity_expiry_mode,
          allow_no_expiry: SiteSetting.live_metrics_activity_allow_no_expiry,
          fixed_duration_minutes: SiteSetting.live_metrics_activity_fixed_duration_minutes.to_i,
          default_duration_minutes: default_minutes(""),
          duration_options: DURATION_OPTIONS,
          default_durations: options.to_h { |label| [label, default_minutes(label)] },
        }
      end

      # Only call this after the account's existing visibility, opt-in and live
      # heartbeat checks. A single query serves an entire directory/card batch.
      def active_for_users(user_ids)
        return {} unless enabled? && table_exists?

        ids = Array(user_ids).compact.uniq
        return {} if ids.empty?

        where(user_id: ids).where("expires_at IS NULL OR expires_at > ?", Time.zone.now)
          .each_with_object({}) do |record, result|
            payload = record.public_payload
            result[record.user_id] = payload if payload
          end
      end

      def current_for(user)
        return nil unless enabled? && user && table_exists?

        where(user_id: user.id).where("expires_at IS NULL OR expires_at > ?", Time.zone.now).first
      end

      def normalize_text(value, required: false)
        text = value.to_s.strip
        raise ArgumentError, "Activity text is too long." if text.bytesize > MAX_INPUT_BYTES
        raise ArgumentError, "Activity text contains invalid characters." if text.match?(/[[:cntrl:]\u2028\u2029]/)
        raise ArgumentError, "Activity text is too long." if text.length > SiteSetting.live_metrics_activity_max_text_length.to_i
        raise ArgumentError, "Please describe your activity." if required && text.blank?
        text
      end

      def expiry_for(label, duration_value)
        mode = SiteSetting.live_metrics_activity_expiry_mode
        return nil if mode == "disabled"

        minutes =
          if mode == "fixed"
            SiteSetting.live_metrics_activity_fixed_duration_minutes.to_i
          elsif mode == "user_selectable"
            duration_value.present? ? Integer(duration_value.to_s, 10) : default_minutes(label)
          else
            raise ArgumentError, "Invalid expiration configuration."
          end

        return nil if minutes == 0 && SiteSetting.live_metrics_activity_allow_no_expiry && mode == "user_selectable"
        valid_duration =
          if mode == "fixed"
            minutes.between?(30, 1440)
          else
            DURATION_OPTIONS.include?(minutes)
          end
        raise ArgumentError, "Choose a valid activity duration." unless valid_duration

        Time.zone.now + minutes.minutes
      rescue ArgumentError, TypeError
        raise ArgumentError, "Choose a valid activity duration."
      end
    end

    def public_payload
      return nil unless self.class.enabled?

      # Never keep an indefinite activity publicly visible if the site
      # subsequently disables indefinite durations.
      if expires_at.nil? && SiteSetting.live_metrics_activity_expiry_mode != "disabled" &&
           !SiteSetting.live_metrics_activity_allow_no_expiry
        return nil
      end

      label = activity_name.to_s
      if is_custom
        return nil unless SiteSetting.live_metrics_activity_custom_enabled
        return nil if label.blank?
        display = label
        details_value = nil
      else
        return nil unless SiteSetting.live_metrics_activity_predefined_enabled
        # Removed choices are no longer public, even if their TTL remains active.
        return nil unless self.class.options.include?(label)
        details_value = SiteSetting.live_metrics_activity_details_enabled ? details.presence : nil
        display = [label, details_value].compact.join(" · ")
      end

      { label: label, details: details_value, custom: is_custom, text: display, expires_at: expires_at&.iso8601, duration_minutes: duration_minutes }
    end
  end
end
