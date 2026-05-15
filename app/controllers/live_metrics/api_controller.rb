# frozen_string_literal: true

module ::LiveMetrics
  class ApiController < ::ApplicationController
    requires_plugin ::LiveMetrics::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false

    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[me update_me update_account connect_hyperate disconnect_hyperate]
    before_action :ensure_logged_in, only: %i[plugin_config directory], if: -> { SiteSetting.live_metrics_require_login_to_view_page }

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
        visibility_options: visibility_options
      )
    end

    def me
      live_metrics_render_json(current_user_payload(include_live: true, include_statistics: true))
    end

    # Backwards-compatible settings endpoint. When no provider is supplied, the
    # first connected account is updated. Newer frontend code uses update_account
    # so multiple providers can be managed independently.
    def update_me
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = current_provider_account(params[:provider].presence || preferred_account_provider)
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      apply_account_settings!(account)
      return if performed?

      live_metrics_render_json(current_user_payload(include_live: true, include_statistics: true))
    end

    def update_account
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      provider = normalize_provider(params[:provider])
      return live_metrics_render_error("invalid_provider", status: 422) if provider.blank?

      account = current_provider_account(provider)
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      apply_account_settings!(account)
      return if performed?

      live_metrics_render_json(current_user_payload(include_live: true, include_statistics: true))
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

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false), status: 200)
    end

    def disconnect_hyperate
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = ::LiveMetrics::ProviderAccount.find_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
      )
      account&.destroy!

      live_metrics_render_json(disconnected: true)
    end

    def directory
      raise Discourse::NotFound unless SiteSetting.live_metrics_directory_enabled

      unless provider_accounts_table_ready?
        return live_metrics_render_json(users: [], generated_at: Time.zone.now.iso8601, database_ready: false)
      end

      accounts = ::LiveMetrics::ProviderAccount
        .enabled_providers
        .directory_enabled
        .includes(:user)
        .order(updated_at: :desc)
        .limit(SiteSetting.live_metrics_directory_limit.to_i)

      rows = accounts.filter_map do |account|
        next unless can_view_account?(account, surface: :directory)

        account_payload(account, include_user: true, include_live: true, include_statistics: false, surface: :directory)
      end

      rows.sort_by! { |row| live_sort_key(row[:live]) }
      live_metrics_render_json(users: rows, generated_at: Time.zone.now.iso8601)
    end

    def user
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound if user.blank?

      account = ::LiveMetrics::ProviderAccount.enabled_providers.profile_enabled.find_by(user_id: user.id)
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
        .order(:provider)
        .to_a
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[live_metrics] provider account lookup failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      []
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists?
    rescue => e
      Rails.logger.warn("[live_metrics] provider account table check failed error=#{e.class}: #{e.message}")
      false
    end

    def current_user_payload(include_live:, include_statistics:)
      accounts = current_accounts.map do |account|
        account_payload(account, include_user: false, include_live: include_live, include_statistics: include_statistics, surface: :self)
      end

      {
        user: user_payload(current_user),
        account: preferred_account_payload(accounts),
        accounts: accounts
      }
    end

    def preferred_account_payload(accounts)
      accounts.find { |account| account.dig(:live, :status).to_s == "live" } || accounts.first
    end

    def preferred_account_provider
      current_accounts.first&.provider
    end

    def account_payload(account, include_user:, include_live:, include_statistics:, surface:)
      live = include_live ? live_payload(account) : nil
      payload = {
        provider: account.provider,
        provider_label: provider_label(account.provider),
        display_name: account.display_name.presence || default_display_name(account.provider),
        connected: account.connected?,
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
        profile_url: "/u/#{user.username}"
      }
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
        return live_metrics_render_error("invalid_visibility", status: 422) unless ::LiveMetrics::ProviderAccount::VISIBILITIES.include?(visibility)
        account.visibility = visibility
      end

      account.show_on_profile = boolean_param(:show_on_profile, default: account.show_on_profile)
      account.show_in_directory = boolean_param(:show_in_directory, default: account.show_in_directory)
      account.save!
    end

    def can_view_account?(account, surface:)
      return false unless account&.connected?
      return false unless ::LiveMetrics.enabled_provider_names.include?(account.provider)
      return true if current_user&.staff?
      return true if current_user.present? && account.user_id == current_user.id

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
      [
        { id: "private", label: "Only me" },
        { id: "logged_in", label: "Logged-in users" },
        { id: "public", label: "Public" },
        { id: "staff", label: "Staff only" }
      ]
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
