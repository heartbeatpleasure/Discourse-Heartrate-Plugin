# frozen_string_literal: true

module ::LiveMetrics
  class AuthController < ::ApplicationController
    requires_plugin ::LiveMetrics::PLUGIN_NAME

    before_action :ensure_enabled
    before_action :ensure_logged_in

    def pulsoid_start
      unless ::LiveMetrics::PulsoidClient.configured?
        return redirect_to "/live-metrics?error=pulsoid_not_configured"
      end

      state = SecureRandom.hex(32)
      session[:live_metrics_pulsoid_oauth_state] = state
      redirect_to ::LiveMetrics::PulsoidClient.authorization_url(state: state)
    end

    def pulsoid_callback
      expected_state = session.delete(:live_metrics_pulsoid_oauth_state).to_s
      received_state = params[:state].to_s
      code = params[:code].to_s

      if expected_state.blank? || expected_state.bytesize != received_state.bytesize || !ActiveSupport::SecurityUtils.secure_compare(expected_state, received_state)
        return redirect_to "/live-metrics?error=oauth_state_mismatch"
      end

      if params[:error].present?
        return redirect_to "/live-metrics?error=#{ERB::Util.url_encode(params[:error].to_s)}"
      end

      if code.blank?
        return redirect_to "/live-metrics?error=missing_authorization_code"
      end

      unless provider_accounts_table_ready?
        return redirect_to "/live-metrics?error=database_not_ready"
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

      profile = ::LiveMetrics::PulsoidClient.profile(account)
      if profile.present?
        account.profile_hash = profile
        account.provider_uid = profile["username"].presence || profile["login"].presence || profile["channel"].presence
        account.display_name = profile["username"].presence || profile["channel"].presence || "Pulsoid account"
        account.last_profile_synced_at = Time.zone.now
        account.save!
      end

      redirect_to "/live-metrics?connected=pulsoid"
    rescue => e
      Rails.logger.warn("[live_metrics] Pulsoid OAuth callback failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      redirect_to "/live-metrics?error=pulsoid_connect_failed"
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
        ::LiveMetrics::PulsoidClient.revoke(account)
        account.destroy!
      end

      render json: { disconnected: true }, status: 200
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.live_metrics_enabled && SiteSetting.live_metrics_pulsoid_enabled
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists?
    rescue => e
      Rails.logger.warn("[live_metrics] provider account table check failed error=#{e.class}: #{e.message}")
      false
    end
  end
end
