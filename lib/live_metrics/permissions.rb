# frozen_string_literal: true

module ::LiveMetrics
  module Permissions
    module_function

    def enabled?
      SiteSetting.live_metrics_enabled
    end

    # Discourse list site settings can be stored as an Array, a pipe-separated
    # string, or pasted comma/newline-separated text. Keep this tolerant so admin
    # settings behave like other group-list settings in our plugins.
    def list_setting(value)
      return value.map { |v| v.to_s.strip }.reject(&:blank?) if value.is_a?(Array)

      value
        .to_s
        .split(/[|,\n]/)
        .map { |v| v.to_s.strip }
        .reject(&:blank?)
    end

    def viewer_groups
      list_setting(SiteSetting.live_metrics_viewer_groups).map(&:downcase)
    end

    def sharer_groups
      list_setting(SiteSetting.live_metrics_allowed_sharer_groups).map(&:downcase)
    end

    def visibility_option_ids
      configured = list_setting(SiteSetting.live_metrics_allowed_visibility_options)
        .map { |value| value.to_s.downcase.strip }
        .select { |value| ::LiveMetrics::ProviderAccount::VISIBILITIES.include?(value) }
        .uniq

      # Only me is the fail-closed baseline and cannot be removed by an invalid or
      # overly restrictive site-setting value.
      (["private"] + configured).uniq
    rescue => e
      ::LiveMetrics::SafeLog.warn("visibility_option_setting_failed", error: e)
      ["private"]
    end

    def visibility_enabled?(visibility)
      visibility_option_ids.include?(visibility.to_s)
    end

    def effective_visibility_id(account_or_visibility)
      visibility =
        if account_or_visibility.respond_to?(:visibility)
          account_or_visibility.visibility.to_s
        else
          account_or_visibility.to_s
        end

      visibility_enabled?(visibility) ? visibility : "private"
    end

    def enforce_visibility_options!
      return 0 unless defined?(::LiveMetrics::ProviderAccount)
      return 0 unless ::LiveMetrics::ProviderAccount.table_exists?

      allowed = visibility_option_ids
      now = Time.zone.now
      ::LiveMetrics::ProviderAccount
        .where.not(visibility: allowed)
        .update_all(visibility: "private", updated_at: now)
    rescue => e
      ::LiveMetrics::SafeLog.warn("visibility_enforcement_failed", error: e)
      0
    end

    # New provider connections should be immediately useful while still respecting
    # the visibility choices enabled by staff. Existing connections are never
    # overwritten by these defaults.
    def default_visibility_id
      options = visibility_option_ids
      return "logged_in" if options.include?("logged_in")
      return "private" if options.include?("private")

      options.first || "private"
    end

    def new_connection_sharing_defaults
      {
        visibility: default_visibility_id,
        show_on_profile: false,
        show_on_user_card: true,
        show_in_directory: true,
      }
    end

    def user_in_any_group?(user, groups)
      return false if user.nil? || groups.blank?

      normalized_groups = groups.map { |group| group.to_s.downcase }
      association = user.association(:groups)

      if association.loaded?
        return association.target.any? do |group|
          normalized_groups.include?(group.name.to_s.downcase)
        end
      end

      user.groups.where("lower(name) IN (?)", normalized_groups).exists?
    end

    def can_view?(guardian_or_user)
      return false unless enabled?

      user = extract_user(guardian_or_user)
      return anonymous_can_view? if user.nil?

      can_view_user?(user)
    end

    def can_view_user?(user)
      return false unless enabled?
      return false if user.nil?
      return true if user.admin? || user.staff?

      groups = viewer_groups
      return true if groups.blank?

      user_in_any_group?(user, groups)
    end

    def can_share?(guardian_or_user)
      user = extract_user(guardian_or_user)
      can_share_user?(user)
    end

    def can_share_user?(user)
      return false unless can_view_user?(user)
      return true if user.admin? || user.staff?

      groups = sharer_groups
      return true if groups.blank?

      user_in_any_group?(user, groups)
    end

    # Central visibility policy for every public Heartrate surface. Keeping the
    # audience decision in one place prevents the overview, profile and user-card
    # endpoints from drifting apart.
    def can_view_account?(account, viewer)
      return false unless enabled?
      return false if account.blank?

      # The account owner and staff always retain access. This check deliberately
      # happens before specific-user and blocked-user lists.
      return true if viewer&.staff?
      return true if viewer.present? && account.user_id == viewer.id

      # Owners who are no longer allowed to share must not remain publicly visible.
      return false unless can_share_user?(account.user)

      case effective_visibility_id(account)
      when "public"
        viewer.present? || anonymous_can_view?
      when "specific_users"
        viewer.present? && audience_ids(account.specific_user_ids).include?(viewer.id)
      when "logged_in"
        viewer.present? && !audience_ids(account.blocked_user_ids).include?(viewer.id)
      when "staff"
        false
      else
        false
      end
    rescue => e
      ::LiveMetrics::SafeLog.warn(
        "account_visibility_check_failed",
        error: e,
        account_id: account&.id,
        viewer_id: viewer&.id,
      )
      false
    end

    def audience_ids(value)
      Array(value)
        .filter_map { |id| Integer(id, exception: false) }
        .select(&:positive?)
        .uniq
    end

    def anonymous_can_view?
      !SiteSetting.live_metrics_require_login_to_view_page && SiteSetting.live_metrics_allow_anonymous_public_view
    end

    def extract_user(guardian_or_user)
      return nil if guardian_or_user.blank?
      return guardian_or_user.user if guardian_or_user.respond_to?(:user)

      guardian_or_user
    end
  end
end
