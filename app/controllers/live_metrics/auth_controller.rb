# frozen_string_literal: true

module ::LiveMetrics
  class AuthController < ::ApplicationController
    requires_plugin ::LiveMetrics::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false

    before_action :ensure_enabled
    before_action :ensure_logged_in

    def pulsoid_start
      unless ::LiveMetrics::PulsoidClient.configured?
        return redirect_to live_metrics_page_url(error: "pulsoid_not_configured")
      end

      state = SecureRandom.hex(32)
      session[:live_metrics_pulsoid_oauth_state] = state

      # OAuth must leave the Discourse host. On newer Rails/Discourse builds,
      # external redirects require allow_other_host to avoid a hard error page.
      redirect_to ::LiveMetrics::PulsoidClient.authorization_url(state: state), allow_other_host: true
    rescue => e
      Rails.logger.warn("[live_metrics] Pulsoid OAuth start failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      redirect_to live_metrics_page_url(error: "pulsoid_connect_failed")
    end

    def pulsoid_callback
      expected_state = session.delete(:live_metrics_pulsoid_oauth_state).to_s
      received_state = params[:state].to_s
      code = params[:code].to_s

      # Pulsoid may return OAuth errors such as invalid_scope before it echoes
      # state back. Surface the provider error first so we do not mask the real
      # problem as a generic state mismatch. Successful callbacks still require
      # an exact state match before exchanging the authorization code.
      if params[:error].present?
        Rails.logger.warn("[live_metrics] Pulsoid OAuth returned error user_id=#{current_user&.id} error=#{params[:error]} description=#{params[:error_description]}")
        return redirect_to live_metrics_page_url(error: safe_oauth_error(params[:error].to_s))
      end

      if expected_state.blank? || received_state.blank? || expected_state.bytesize != received_state.bytesize || !ActiveSupport::SecurityUtils.secure_compare(expected_state, received_state)
        return redirect_to live_metrics_page_url(error: "oauth_state_mismatch")
      end

      if code.blank?
        return redirect_to live_metrics_page_url(error: "missing_authorization_code")
      end

      unless provider_accounts_table_ready?
        return redirect_to live_metrics_page_url(error: "database_not_ready")
      end

      token_payload = ::LiveMetrics::PulsoidClient.exchange_code!(code: code)

      account = ::LiveMetrics::ProviderAccount.find_or_initialize_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
      )
      ::LiveMetrics::PulsoidClient.apply_token_payload!(account, token_payload)
      account.visibility ||= "private"
      account.show_on_profile = false if account.show_on_profile.nil?
      account.show_in_directory = false if account.show_in_directory.nil?
      account.save!
      account.activate!

      profile = ::LiveMetrics::PulsoidClient.profile(account)
      if profile.present?
        account.profile_hash = profile
        account.provider_uid = profile["username"].presence || profile["login"].presence || profile["channel"].presence
        account.display_name = profile["username"].presence || profile["channel"].presence || "Pulsoid account"
        account.last_profile_synced_at = Time.zone.now
        account.save!
      end

      redirect_to live_metrics_page_url(connected: "pulsoid")
    rescue => e
      Rails.logger.warn("[live_metrics] Pulsoid OAuth callback failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      redirect_to live_metrics_page_url(error: "pulsoid_connect_failed")
    end

    def pulsoid_disconnect
      unless provider_accounts_table_ready?
        return render json: { disconnected: false, error: "database_not_ready" }, status: 503
      end

      account = ::LiveMetrics::ProviderAccount.find_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
      )

      if account.present?
        was_active = account.active?
        ::LiveMetrics::PulsoidClient.revoke(account)
        account.destroy!
        activate_fallback_account_for_user! if was_active
      end

      render json: { disconnected: true }, status: 200
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.live_metrics_enabled && SiteSetting.live_metrics_pulsoid_enabled
    end

    def safe_oauth_error(value)
      sanitized = value.to_s.downcase.gsub(/[^a-z0-9_\-]/, "_")
      sanitized.present? ? sanitized.truncate(80, omission: "") : "oauth_error"
    end

    def live_metrics_page_url(query = {})
      query = query.compact_blank if query.respond_to?(:compact_blank)
      return "/live-metrics" if query.blank?

      "/live-metrics?#{query.to_query}"
    end

    def activate_fallback_account_for_user!
      fallback = ::LiveMetrics::ProviderAccount
        .where(user_id: current_user.id, provider: ::LiveMetrics.enabled_provider_names)
        .order(updated_at: :desc)
        .detect(&:connected?)
      fallback&.activate!
    rescue => e
      Rails.logger.warn("[live_metrics] fallback provider activation failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists? && ::LiveMetrics::ProviderAccount.column_names.include?("active")
    rescue => e
      Rails.logger.warn("[live_metrics] provider account table check failed error=#{e.class}: #{e.message}")
      false
    end
  end
end
