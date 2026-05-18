# frozen_string_literal: true

module ::LiveMetrics
  class ApiController < ::ApplicationController
    requires_plugin ::LiveMetrics::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false

    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[me live_preview update_me update_account activate_account connect_hyperate disconnect_hyperate]
    before_action :ensure_logged_in, only: %i[plugin_config directory], if: -> { SiteSetting.live_metrics_require_login_to_view_page }
    before_action :ensure_can_view, only: %i[plugin_config me live_preview directory user]
    before_action :ensure_can_share, only: %i[update_me update_account activate_account connect_hyperate]

    # NOTE: do not name this action `config`; ActionController already has
    # a `config` method and Discourse plugin controllers can fail hard when
    # routes point at an action with that name. Keep the public URL as
    # /live-metrics/api/config, but route it to plugin_config internally.
    def plugin_config
      live_metrics_render_json(
        enabled: SiteSetting.live_metrics_enabled,
        directory_enabled: SiteSetting.live_metrics_directory_enabled,
        statistics_enabled: SiteSetting.live_metrics_statistics_enabled,
        database_ready: provider_accounts_table_ready?,
        poll_interval_seconds: SiteSetting.live_metrics_poll_interval_seconds.to_i,
        providers: provider_config_payload,
        visibility_options: visibility_options,
        permissions: {
          can_view: ::LiveMetrics::Permissions.can_view?(guardian),
          can_share: ::LiveMetrics::Permissions.can_share?(guardian)
        }
      )
    end

    def me
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      ensure_active_account_for_user!(current_user)
      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    end

    def live_preview
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = active_current_account
      payload = {
        account: account ? account_payload(account, include_user: false, include_live: true, include_statistics: false, surface: :self) : nil,
        generated_at: Time.zone.now.iso8601
      }

      live_metrics_render_json(payload)
    end

    # Backwards-compatible settings endpoint. When no provider is supplied, the
    # active connected account is updated. Newer frontend code uses update_account
    # so multiple providers can be managed independently.
    def update_me
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = current_provider_account(params[:provider].presence || active_current_account&.provider || preferred_account_provider)
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      apply_account_settings!(account)
      return if performed?

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    end

    def update_account
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      provider = normalize_provider(params[:provider])
      return live_metrics_render_error("invalid_provider", status: 422) if provider.blank?

      account = current_provider_account(provider)
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      apply_account_settings!(account)
      return if performed?

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    end

    def activate_account
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      provider = normalize_provider(params[:provider])
      return live_metrics_render_error("invalid_provider", status: 422, message: "Choose a valid heartrate provider.") if provider.blank?

      account = current_provider_account(provider)
      return live_metrics_render_error("not_connected", status: 404, message: "Connect this provider before making it active.") if account.blank? || !account.connected?
      return live_metrics_render_error("provider_disabled", status: 404, message: "This provider is currently disabled.") unless ::LiveMetrics.enabled_provider_names.include?(provider)

      account.activate!
      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    rescue ActiveRecord::RecordInvalid => e
      live_metrics_render_error("activate_failed", status: 422, message: e.record.errors.full_messages.join(", ").presence || "The active provider could not be changed.")
    rescue => e
      Rails.logger.warn("[live_metrics] activate provider failed user_id=#{current_user&.id} provider=#{params[:provider]} error=#{e.class}: #{e.message}")
      live_metrics_render_error("activate_failed", status: 422, message: "The active provider could not be changed.")
    end

    def connect_hyperate
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?
      return live_metrics_render_error("hyperate_disabled", status: 404) unless SiteSetting.live_metrics_hyperate_enabled
      return live_metrics_render_error("hyperate_not_configured", status: 422, message: "HypeRate is enabled, but the API key is not configured yet.") unless ::LiveMetrics::HypeRateClient.configured?

      device_id = ::LiveMetrics::HypeRateClient.normalize_device_id(params[:device_id])
      return live_metrics_render_error("invalid_hyperate_device_id", status: 422, message: "Enter a valid HypeRate device ID.") unless ::LiveMetrics::HypeRateClient.valid_device_id?(device_id)

      account = ::LiveMetrics::ProviderAccount.find_or_initialize_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
      )

      account.provider_uid = device_id
      account.display_name = "HypeRate #{masked_device_id(device_id)}"
      account.profile_hash = { "device_id_last4" => device_id.last(4) }
      account.visibility ||= "private"
      account.show_on_profile = false if account.show_on_profile.nil?
      account.show_in_directory = false if account.show_in_directory.nil?
      account.access_token_cipher = nil
      account.refresh_token_cipher = nil
      account.token_expires_at = nil
      account.scopes = nil
      account.last_error = nil
      account.save!
      account.activate!

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false), status: 200)
    end

    def disconnect_hyperate
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = ::LiveMetrics::ProviderAccount.find_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
      )
      was_active = account&.active?
      account&.destroy!
      activate_fallback_account_for_user!(current_user) if was_active

      live_metrics_render_json(disconnected: true)
    end

    def directory
      raise Discourse::NotFound unless SiteSetting.live_metrics_directory_enabled

      unless provider_accounts_table_ready?
        return live_metrics_render_json(users: [], generated_at: Time.zone.now.iso8601, database_ready: false)
      end

      accounts = ::LiveMetrics::ProviderAccount
        .enabled_providers
        .active
        .directory_enabled
        .includes(:user)
        .order(updated_at: :desc)
        .limit(SiteSetting.live_metrics_directory_limit.to_i)

      rows = accounts.filter_map do |account|
        next unless can_view_account?(account, surface: :directory)

        payload = account_payload(account, include_user: true, include_live: true, include_statistics: false, surface: :directory)
        next unless directory_live_payload?(payload[:live])

        payload
      end

      rows.sort_by! { |row| live_sort_key(row[:live]) }
      live_metrics_render_json(users: rows, generated_at: Time.zone.now.iso8601)
    end

    def user
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound if user.blank?

      account = ::LiveMetrics::ProviderAccount.enabled_providers.active.profile_enabled.find_by(user_id: user.id)
      raise Discourse::NotFound if account.blank? || !can_view_account?(account, surface: :profile)

      live_metrics_render_json(account_payload(account, include_user: true, include_live: true, include_statistics: true, surface: :profile))
    end

    private

    def live_metrics_render_json(payload = nil, status: 200, **keyword_payload)
      payload = keyword_payload if payload.nil?
      payload = {} if payload.nil?
      render json: payload, status: status
    end

    def live_metrics_render_error(error_key, status: 422, message: nil)
      live_metrics_render_json({ error: error_key, message: message || error_key }, status: status)
    end

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.live_metrics_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless ::LiveMetrics::Permissions.can_view?(guardian)
    end

    def ensure_can_share
      return if ::LiveMetrics::Permissions.can_share?(guardian)

      live_metrics_render_error(
        "sharing_not_allowed",
        status: 403,
        message: "Your account is not allowed to connect or share heartrate data."
      )
    end

    def provider_config_payload
      {
        pulsoid: {
          enabled: SiteSetting.live_metrics_pulsoid_enabled,
          configured: ::LiveMetrics::PulsoidClient.configured?,
          connect_url: "/live-metrics/api/connect/pulsoid",
          connect_type: "oauth",
          label: "Pulsoid"
        },
        hyperate: {
          enabled: SiteSetting.live_metrics_hyperate_enabled,
          configured: ::LiveMetrics::HypeRateClient.configured?,
          connect_url: "/live-metrics/api/connect/hyperate",
          connect_type: "device_id",
          label: "HypeRate"
        }
      }
    end

    def current_provider_account(provider)
      provider = normalize_provider(provider)
      return nil if current_user.blank? || provider.blank? || !provider_accounts_table_ready?

      ::LiveMetrics::ProviderAccount.find_by(user_id: current_user.id, provider: provider)
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[live_metrics] provider account lookup failed user_id=#{current_user&.id} provider=#{provider} error=#{e.class}: #{e.message}")
      nil
    end

    def current_accounts
      return [] if current_user.blank? || !provider_accounts_table_ready?

      ::LiveMetrics::ProviderAccount
        .where(user_id: current_user.id, provider: ::LiveMetrics.enabled_provider_names)
        .order(active: :desc, updated_at: :desc, provider: :asc)
        .to_a
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[live_metrics] provider account lookup failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      []
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists? && ::LiveMetrics::ProviderAccount.column_names.include?("active")
    rescue => e
      Rails.logger.warn("[live_metrics] provider account table check failed error=#{e.class}: #{e.message}")
      false
    end

    def current_user_payload(include_live:, include_statistics:)
      accounts = current_accounts.map do |account|
        account_payload(account, include_user: false, include_live: include_live && account.active?, include_statistics: include_statistics && account.active?, surface: :self)
      end

      active_account = accounts.find { |account| account[:active] } || accounts.first

      {
        user: user_payload(current_user),
        account: active_account,
        active_provider: active_account&.dig(:provider),
        accounts: accounts
      }
    end

    def preferred_account_provider
      current_accounts.first&.provider
    end

    def active_current_account
      ensure_active_account_for_user!(current_user)
      current_accounts.find(&:active?)
    end

    def ensure_active_account_for_user!(user)
      return if user.blank? || !provider_accounts_table_ready?

      accounts = ::LiveMetrics::ProviderAccount
        .where(user_id: user.id, provider: ::LiveMetrics.enabled_provider_names)
        .select(&:connected?)

      return if accounts.blank?
      return if accounts.any?(&:active?)

      accounts.max_by(&:updated_at)&.activate!
    rescue => e
      Rails.logger.warn("[live_metrics] active provider check failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
    end

    def activate_fallback_account_for_user!(user)
      return if user.blank? || !provider_accounts_table_ready?

      fallback = ::LiveMetrics::ProviderAccount
        .where(user_id: user.id, provider: ::LiveMetrics.enabled_provider_names)
        .order(updated_at: :desc)
        .detect(&:connected?)
      fallback&.activate!
    rescue => e
      Rails.logger.warn("[live_metrics] fallback provider activation failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
    end

    def account_payload(account, include_user:, include_live:, include_statistics:, surface:)
      live = include_live ? live_payload(account) : nil
      payload = {
        provider: account.provider,
        provider_label: provider_label(account.provider),
        display_name: account.display_name.presence || default_display_name(account.provider),
        connected: account.connected?,
        active: account.active?,
        visibility: account.visibility,
        show_on_profile: account.show_on_profile,
        show_in_directory: account.show_in_directory,
        live: live,
        status_label: status_label(live),
        profile: public_profile_payload(account)
      }

      payload[:user] = user_payload(account.user) if include_user

      if include_statistics && account.pulsoid? && SiteSetting.live_metrics_statistics_enabled && account.scopes_list.include?(::LiveMetrics::PulsoidClient::STATISTICS_SCOPE)
        payload[:statistics] = {
          "24h" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "24h"),
          "7d" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "7d"),
          "30d" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "30d")
        }
      end

      payload
    end

    def live_payload(account)
      case account.provider
      when ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
        ::LiveMetrics::PulsoidClient.latest(account)
      when ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
        ::LiveMetrics::HypeRateClient.latest(account)
      else
        { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil }
      end
    end

    def user_payload(user)
      {
        id: user.id,
        username: user.username,
        name: user.name,
        avatar_template: user.avatar_template,
        profile_url: "/u/#{user.username}",
        profile_details: public_user_profile_details(user)
      }
    end

    PROFILE_DETAIL_ALIASES = {
      "age" => %w[age leeftijd],
      "gender" => %w[gender geslacht],
      "country" => %w[country land]
    }.freeze

    PROFILE_DETAIL_LABELS = {
      "age" => "Age",
      "gender" => "Gender",
      "country" => "Country"
    }.freeze

    def public_user_profile_details(user)
      return [] if user.blank? || !defined?(::UserField)

      fields_by_key = profile_detail_user_fields
      return [] if fields_by_key.blank?

      custom_fields = user.custom_fields || {}
      fields_by_key.filter_map do |key, field|
        value = custom_fields["user_field_#{field.id}"]
        next if value.blank?

        { key: key, label: PROFILE_DETAIL_LABELS[key] || field.name.to_s, value: value.to_s }
      end
    rescue => e
      Rails.logger.warn("[live_metrics] public profile detail lookup failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
      []
    end

    def profile_detail_user_fields
      @profile_detail_user_fields ||= begin
        fields = ::UserField.all.to_a
        fields.each_with_object({}) do |field, memo|
          next unless public_profile_detail_field?(field)

          key = normalized_profile_detail_key(field.name)
          next if key.blank? || memo.key?(key)

          memo[key] = field
        end.sort_by { |key, _| PROFILE_DETAIL_LABELS.keys.index(key) || 99 }.to_h
      end
    rescue => e
      Rails.logger.warn("[live_metrics] profile detail user field lookup failed error=#{e.class}: #{e.message}")
      {}
    end

    def public_profile_detail_field?(field)
      visible_on_card =
        (field.respond_to?(:show_on_user_card) && field.show_on_user_card) ||
        (field.respond_to?(:show_on_user_card?) && field.show_on_user_card?)
      visible_on_profile =
        (field.respond_to?(:show_on_profile) && field.show_on_profile) ||
        (field.respond_to?(:show_on_profile?) && field.show_on_profile?)

      visible_on_card || visible_on_profile
    end

    def normalized_profile_detail_key(name)
      normalized = name.to_s.downcase.strip
      PROFILE_DETAIL_ALIASES.find { |_, aliases| aliases.include?(normalized) }&.first
    end

    def public_profile_payload(account)
      profile = account.profile_hash
      payload = {
        channel: profile["channel"],
        heart_rate_available: profile["heart_rate"] == true
      }
      payload[:device_id_last4] = profile["device_id_last4"] if account.hyperate?
      payload
    end

    def apply_account_settings!(account)
      visibility = params[:visibility].to_s
      if visibility.present?
        allowed_visibility_ids = ::LiveMetrics::Permissions.visibility_option_ids
        unless ::LiveMetrics::ProviderAccount::VISIBILITIES.include?(visibility) && allowed_visibility_ids.include?(visibility)
          return live_metrics_render_error("invalid_visibility", status: 422, message: "Choose an available visibility option.")
        end

        account.visibility = visibility
      end

      account.show_on_profile = boolean_param(:show_on_profile, default: account.show_on_profile)
      account.show_in_directory = boolean_param(:show_in_directory, default: account.show_in_directory)
      account.save!
    rescue ActiveRecord::RecordInvalid => e
      live_metrics_render_error("settings_save_failed", status: 422, message: e.record.errors.full_messages.join(", ").presence || "Your heartrate settings could not be saved.")
    rescue => e
      Rails.logger.warn("[live_metrics] account settings save failed account_id=#{account&.id} error=#{e.class}: #{e.message}")
      live_metrics_render_error("settings_save_failed", status: 422, message: "Your heartrate settings could not be saved.")
    end

    def can_view_account?(account, surface:)
      return false unless account&.connected?
      return false unless account.active?
      return false unless ::LiveMetrics.enabled_provider_names.include?(account.provider)
      return true if current_user&.staff?
      return true if current_user.present? && account.user_id == current_user.id
      return false unless ::LiveMetrics::Permissions.can_share_user?(account.user)

      case surface
      when :directory
        return false unless account.show_in_directory
      when :profile
        return false unless account.show_on_profile
      end

      case account.visibility
      when "public"
        SiteSetting.live_metrics_allow_anonymous_public_view || current_user.present?
      when "logged_in"
        current_user.present?
      when "staff"
        current_user&.staff?
      else
        false
      end
    end

    def visibility_options
      ::LiveMetrics::Permissions.visibility_option_ids.map do |id|
        { id: id, label: visibility_label(id) }
      end
    end

    def visibility_label(id)
      case id.to_s
      when "private"
        "Only me"
      when "logged_in"
        "Logged-in users"
      when "public"
        "Public"
      when "staff"
        "Staff only"
      else
        id.to_s.titleize
      end
    end

    def boolean_param(key, default:)
      return default unless params.key?(key)

      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def status_label(live)
      case live&.dig(:status).to_s
      when "live"
        "Live"
      when "delayed"
        "Delayed"
      when "stale"
        "No recent signal"
      when "no_data"
        "No heart-rate data yet"
      when "unauthorized"
        "Reconnect required"
      else
        "Unavailable"
      end
    end

    def directory_live_payload?(live)
      live&.dig(:status).to_s == "live" && live&.dig(:heart_rate).present?
    end

    def live_sort_key(live)
      status = live&.dig(:status).to_s
      status_rank = { "live" => 0, "delayed" => 1, "stale" => 2, "no_data" => 3, "unauthorized" => 4, "unavailable" => 5 }[status] || 9
      age = live&.dig(:age_seconds).to_i
      [status_rank, age]
    end

    def provider_label(provider)
      case provider.to_s
      when ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
        "Pulsoid"
      when ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
        "HypeRate"
      else
        provider.to_s.titleize
      end
    end

    def default_display_name(provider)
      "#{provider_label(provider)} account"
    end

    def normalize_provider(provider)
      provider = provider.to_s.downcase.strip
      ::LiveMetrics::ProviderAccount::PROVIDERS.include?(provider) ? provider : nil
    end

    def masked_device_id(device_id)
      value = device_id.to_s
      return "device" if value.blank?
      return "device #{value}" if value.length <= 8

      "device #{value.first(4)}…#{value.last(4)}"
    end

    def database_not_ready_message
      "The Heartrate database table is not ready yet. Run Discourse migrations and rebuild/restart."
    end
  end
end
