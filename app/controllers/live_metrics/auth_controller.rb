# frozen_string_literal: true

module ::LiveMetrics
  class AuthController < ::ApplicationController
    PULSOID_OAUTH_STATES_KEY = :live_metrics_pulsoid_oauth_states
    PULSOID_OAUTH_STATE_TTL = 10.minutes
    PULSOID_OAUTH_STATE_LIMIT = 5

    RATE_LIMIT_ACTIONS = {
      "pulsoid_start" => :provider_connect,
      "pulsoid_disconnect" => :provider_disconnect,
    }.freeze

    OAUTH_ERROR_CODES = %w[
      access_denied
      invalid_request
      unauthorized_client
      unsupported_response_type
      invalid_scope
      server_error
      temporarily_unavailable
    ].freeze

    requires_plugin ::LiveMetrics::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false

    before_action :ensure_enabled
    before_action :ensure_logged_in
    before_action :enforce_request_rate_limit, only: RATE_LIMIT_ACTIONS.keys.map(&:to_sym)
    before_action :ensure_can_share, only: %i[pulsoid_start pulsoid_callback]

    def pulsoid_start
      unless ::LiveMetrics::PulsoidClient.configured?
        record_admin_event(
          event: "oauth_start",
          result: "not_configured",
          severity: "warning",
        )
        return redirect_to live_metrics_page_url(error: "pulsoid_not_configured")
      end

      state = SecureRandom.hex(32)
      store_oauth_state!(state)

      # OAuth must leave the Discourse host. On newer Rails/Discourse builds,
      # external redirects require allow_other_host to avoid a hard error page.
      authorization_url = ::LiveMetrics::PulsoidClient.authorization_url(state: state)
      redirect_to authorization_url, allow_other_host: true
      record_admin_event(event: "oauth_start", result: "redirected")
    rescue => e
      record_admin_event(
        event: "oauth_start",
        result: "connect_failed",
        severity: "error",
      )
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_oauth_start_failed",
        error: e,
        user_id: current_user&.id,
      )
      redirect_to live_metrics_page_url(error: "pulsoid_connect_failed")
    end

    def pulsoid_callback
      received_state = params[:state].to_s
      code = params[:code].to_s

      # Pulsoid may return OAuth errors such as invalid_scope before it echoes
      # state back. Surface the provider error first so we do not mask the real
      # problem as a generic state mismatch. Successful callbacks still require
      # an exact state match before exchanging the authorization code.
      if params[:error].present?
        consume_oauth_state(received_state) if received_state.present?
        record_admin_event(
          event: "oauth_callback",
          result: "provider_error",
          severity: "warning",
        )
        error_code = safe_oauth_error(params[:error])
        ::LiveMetrics::SafeLog.warn(
          "pulsoid_oauth_provider_error",
          user_id: current_user&.id,
          oauth_error: error_code,
        )
        return redirect_to live_metrics_page_url(error: error_code)
      end

      unless consume_oauth_state(received_state)
        record_admin_event(
          event: "oauth_callback",
          result: "state_mismatch",
          severity: "warning",
        )
        return redirect_to live_metrics_page_url(error: "oauth_state_mismatch")
      end

      if code.blank?
        record_admin_event(
          event: "oauth_callback",
          result: "missing_authorization_code",
          severity: "warning",
        )
        return redirect_to live_metrics_page_url(error: "missing_authorization_code")
      end

      unless provider_accounts_table_ready?
        record_admin_event(
          event: "oauth_callback",
          result: "database_not_ready",
          severity: "error",
        )
        return redirect_to live_metrics_page_url(error: "database_not_ready")
      end

      token_payload = ::LiveMetrics::PulsoidClient.exchange_code!(code: code)
      validated_token = ::LiveMetrics::PulsoidClient.validate_token_payload!(token_payload)

      account = ::LiveMetrics::ProviderAccount.find_or_initialize_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
      )
      new_connection = account.new_record?
      if account.persisted? && ::LiveMetrics::RefreshCoordinator.async_enabled?
        ::LiveMetrics::RefreshCoordinator.stop(account, clear_fetch_lock: false)
      end

      ::LiveMetrics::PulsoidClient.apply_token_payload!(
        account,
        token_payload,
        expires_in: validated_token.fetch("expires_in"),
        validated_scopes: validated_token.fetch("scopes"),
      )
      if new_connection
        account.assign_attributes(::LiveMetrics::Permissions.new_connection_sharing_defaults)
      end
      account.provider_uid = nil
      account.display_name = "Pulsoid account"
      account.profile_data = nil
      account.last_profile_synced_at = nil
      account.save!
      account.activate!

      if ::LiveMetrics::RefreshCoordinator.async_enabled?
        ::LiveMetrics::RefreshCoordinator.start(account, replace: true)
      end
      ::LiveMetrics::RefreshCoordinator.sync_user(current_user.id)

      record_admin_event(event: "oauth_callback", result: "success")
      redirect_to live_metrics_page_url(connected: "pulsoid")
    rescue ::LiveMetrics::PulsoidClient::ValidationError => e
      result, error_code = validation_error_codes(e)
      record_admin_event(
        event: "oauth_callback",
        result: result,
        severity: "warning",
      )
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_oauth_validation_failed",
        error: e,
        user_id: current_user&.id,
        classification: e.classification,
      )
      redirect_to live_metrics_page_url(error: error_code)
    rescue => e
      record_admin_event(
        event: "oauth_callback",
        result: "connect_failed",
        severity: "error",
      )
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_oauth_callback_failed",
        error: e,
        user_id: current_user&.id,
      )
      redirect_to live_metrics_page_url(error: "pulsoid_connect_failed")
    end

    def pulsoid_disconnect
      unless provider_accounts_table_ready?
        record_admin_event(
          event: "provider_disconnect",
          result: "database_not_ready",
          severity: "error",
        )
        return render json: { disconnected: false, error: "database_not_ready" }, status: 503
      end

      account = ::LiveMetrics::ProviderAccount.find_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
      )

      if account.present?
        was_active = account.active?
        ::LiveMetrics::RefreshCoordinator.stop(account)
        revoked = ::LiveMetrics::PulsoidClient.revoke(account)
        unless revoked
          record_admin_event(
            event: "provider_disconnect",
            result: "revoke_failed",
            severity: "warning",
          )
        end
        account.destroy!
        activate_fallback_account_for_user! if was_active
        ::LiveMetrics::RefreshCoordinator.sync_user(current_user.id)
      end

      record_admin_event(event: "provider_disconnect", result: "disconnected")
      render json: { disconnected: true }, status: 200
    rescue
      record_admin_event(
        event: "provider_disconnect",
        result: "disconnect_failed",
        severity: "error",
      )
      raise
    end

    private

    def enforce_request_rate_limit
      limiter_action = RATE_LIMIT_ACTIONS.fetch(action_name)
      ::LiveMetrics::RequestRateLimiter.perform!(
        limiter_action,
        user: current_user,
        request: request,
      )
    end

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.live_metrics_enabled && SiteSetting.live_metrics_pulsoid_enabled
    end

    def ensure_can_share
      return if ::LiveMetrics::Permissions.can_share?(guardian)

      record_admin_event(
        event: action_name == "pulsoid_callback" ? "oauth_callback" : "oauth_start",
        result: "sharing_denied",
        severity: "warning",
      )
      redirect_to live_metrics_page_url(error: "sharing_not_allowed")
    end

    def record_admin_event(event:, result:, severity: "info")
      ::LiveMetrics::AdminEventLog.record(
        provider: "pulsoid",
        event: event,
        result: result,
        severity: severity,
        client_context: ::LiveMetrics::AdminEventLog.client_context_for(request),
      )
    end

    def safe_oauth_error(value)
      normalized = value.to_s.downcase.strip
      OAUTH_ERROR_CODES.include?(normalized) ? normalized : "oauth_error"
    end

    def store_oauth_state!(state)
      states = pruned_oauth_states
      states << { "value" => state.to_s, "created_at" => Time.now.to_i }
      session[PULSOID_OAUTH_STATES_KEY] = states.last(PULSOID_OAUTH_STATE_LIMIT)
    end

    def consume_oauth_state(received_state)
      received_state = received_state.to_s
      states = pruned_oauth_states
      match_index = states.index do |entry|
        secure_state_match?(entry["value"], received_state)
      end

      matched = match_index.present?
      states.delete_at(match_index) if matched
      session[PULSOID_OAUTH_STATES_KEY] = states
      matched
    end

    def pruned_oauth_states
      cutoff = Time.now.to_i - PULSOID_OAUTH_STATE_TTL.to_i
      Array(session[PULSOID_OAUTH_STATES_KEY]).filter_map do |entry|
        next unless entry.respond_to?(:[])

        value = (entry["value"] || entry[:value]).to_s
        created_at = (entry["created_at"] || entry[:created_at]).to_i
        next if value.blank? || created_at < cutoff

        { "value" => value, "created_at" => created_at }
      end.last(PULSOID_OAUTH_STATE_LIMIT)
    end

    def secure_state_match?(expected, received)
      expected = expected.to_s
      received = received.to_s
      return false if expected.blank? || received.blank?
      return false unless expected.bytesize == received.bytesize

      ActiveSupport::SecurityUtils.secure_compare(expected, received)
    end

    def validation_error_codes(error)
      case error.classification.to_sym
      when :scope_required
        ["scope_required", "pulsoid_scope_required"]
      when :configuration_error
        ["client_mismatch", "pulsoid_client_mismatch"]
      else
        ["token_validation_failed", "pulsoid_token_validation_failed"]
      end
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
      ::LiveMetrics::SafeLog.warn(
        "fallback_provider_activation_failed",
        error: e,
        user_id: current_user&.id,
      )
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists? &&
        %w[active show_on_user_card].all? { |column| ::LiveMetrics::ProviderAccount.column_names.include?(column) }
    rescue => e
      ::LiveMetrics::SafeLog.warn("provider_account_table_check_failed", error: e)
      false
    end
  end
end
