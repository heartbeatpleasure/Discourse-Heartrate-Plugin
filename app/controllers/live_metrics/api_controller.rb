# frozen_string_literal: true

module ::LiveMetrics
  class ApiController < ::ApplicationController
    requires_plugin ::LiveMetrics::PLUGIN_NAME

    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[me update_me]
    before_action :ensure_logged_in, only: %i[config directory], if: -> { SiteSetting.live_metrics_require_login_to_view_page }

    def config
      live_metrics_render_json(
        enabled: SiteSetting.live_metrics_enabled,
        directory_enabled: SiteSetting.live_metrics_directory_enabled,
        statistics_enabled: SiteSetting.live_metrics_statistics_enabled,
        database_ready: provider_accounts_table_ready?,
        poll_interval_seconds: SiteSetting.live_metrics_poll_interval_seconds.to_i,
        providers: {
          pulsoid: {
            enabled: SiteSetting.live_metrics_pulsoid_enabled,
            configured: ::LiveMetrics::PulsoidClient.configured?,
            connect_url: "/live-metrics/auth/pulsoid/start"
          }
        },
        visibility_options: visibility_options
      )
    end

    def me
      live_metrics_render_json(current_user_payload(include_live: true, include_statistics: true))
    end

    def update_me
      return live_metrics_render_error("database_not_ready", status: 503, message: "The Heartrate database table is not ready yet. Run Discourse migrations and rebuild/restart.") unless provider_accounts_table_ready?

      account = current_pulsoid_account
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      visibility = params[:visibility].to_s
      if visibility.present?
        return live_metrics_render_error("invalid_visibility", status: 422) unless ::LiveMetrics::ProviderAccount::VISIBILITIES.include?(visibility)
        account.visibility = visibility
      end

      account.show_on_profile = boolean_param(:show_on_profile, default: account.show_on_profile)
      account.show_in_directory = boolean_param(:show_in_directory, default: account.show_in_directory)
      account.save!

      live_metrics_render_json(current_user_payload(include_live: true, include_statistics: true))
    end

    def directory
      raise Discourse::NotFound unless SiteSetting.live_metrics_directory_enabled

      unless provider_accounts_table_ready?
        return live_metrics_render_json(users: [], generated_at: Time.zone.now.iso8601, database_ready: false)
      end

      accounts = ::LiveMetrics::ProviderAccount
        .pulsoid
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

      account = ::LiveMetrics::ProviderAccount.pulsoid.profile_enabled.find_by(user_id: user.id)
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

    def current_pulsoid_account
      return nil if current_user.blank? || !provider_accounts_table_ready?

      ::LiveMetrics::ProviderAccount.find_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
      )
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[live_metrics] provider account lookup failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      nil
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists?
    rescue => e
      Rails.logger.warn("[live_metrics] provider account table check failed error=#{e.class}: #{e.message}")
      false
    end

    def current_user_payload(include_live:, include_statistics:)
      account = current_pulsoid_account
      {
        user: user_payload(current_user),
        account: account ? account_payload(account, include_user: false, include_live: include_live, include_statistics: include_statistics, surface: :self) : nil
      }
    end

    def account_payload(account, include_user:, include_live:, include_statistics:, surface:)
      live = include_live ? ::LiveMetrics::PulsoidClient.latest(account) : nil
      payload = {
        provider: account.provider,
        provider_label: "Pulsoid",
        display_name: account.display_name.presence || "Pulsoid account",
        connected: account.connected?,
        visibility: account.visibility,
        show_on_profile: account.show_on_profile,
        show_in_directory: account.show_in_directory,
        live: live,
        status_label: status_label(live),
        profile: public_profile_payload(account)
      }

      payload[:user] = user_payload(account.user) if include_user

      if include_statistics && SiteSetting.live_metrics_statistics_enabled && account.scopes_list.include?(::LiveMetrics::PulsoidClient::STATISTICS_SCOPE)
        payload[:statistics] = {
          "24h" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "24h"),
          "7d" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "7d"),
          "30d" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "30d")
        }
      end

      payload
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
      {
        channel: profile["channel"],
        heart_rate_available: profile["heart_rate"] == true
      }
    end

    def can_view_account?(account, surface:)
      return false unless account&.connected?
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
  end
end
