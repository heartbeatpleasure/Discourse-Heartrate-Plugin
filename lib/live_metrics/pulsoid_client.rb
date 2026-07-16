# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module ::LiveMetrics
  class PulsoidClient
    DEFAULT_SCOPES = %w[data:heart_rate:read]
    STATISTICS_SCOPE = "data:statistics:read"
    USER_AGENT = "Discourse Heartrate Pulsoid/0.1"
    MAX_RESPONSE_BYTES = 1_048_576

    class Error < StandardError
      attr_reader :status, :body, :classification, :provider_code

      def initialize(
        message,
        status: nil,
        body: nil,
        classification: :provider_unavailable,
        provider_code: nil
      )
        super(message)
        @status = status&.to_i
        @body = body
        @classification = classification.to_sym
        @provider_code = provider_code.to_s.presence
      end
    end

    class Unauthorized < Error; end
    class NoHeartRateData < Error; end
    class StaleCredentials < Error; end

    PROVIDER_ERROR_CLASSIFICATIONS = {
      "7005" => :authorization_failed,
      "7006" => :token_expired,
      "7007" => :subscription_required,
      "7009" => :configuration_error,
      "7010" => :configuration_error,
      "7011" => :scope_required,
      "6003" => :scope_required,
      "7001" => :provider_unavailable,
      "7002" => :provider_unavailable,
      "7003" => :provider_unavailable,
      "7004" => :provider_unavailable,
      "6001" => :provider_unavailable,
      "6002" => :provider_unavailable,
    }.freeze

    def self.configured?
      return false unless SiteSetting.live_metrics_pulsoid_enabled
      return false if SiteSetting.live_metrics_pulsoid_client_id.to_s.blank?
      return false if SiteSetting.live_metrics_pulsoid_client_secret.to_s.blank?

      provider_urls = [
        SiteSetting.live_metrics_pulsoid_authorize_url,
        SiteSetting.live_metrics_pulsoid_token_url,
        SiteSetting.live_metrics_pulsoid_revoke_url,
        SiteSetting.live_metrics_pulsoid_latest_url,
        SiteSetting.live_metrics_pulsoid_profile_url,
      ]
      provider_urls << SiteSetting.live_metrics_pulsoid_statistics_url if SiteSetting.live_metrics_statistics_enabled
      provider_urls.all? { |url| ::LiveMetrics::ProviderTransport.valid_pulsoid_https_url?(url) }
    rescue => e
      ::LiveMetrics::SafeLog.warn("pulsoid_configuration_check_failed", error: e)
      false
    end

    def self.scopes
      scopes = DEFAULT_SCOPES.dup
      scopes << STATISTICS_SCOPE if SiteSetting.live_metrics_statistics_enabled
      scopes.uniq
    end

    def self.redirect_uri
      override = SiteSetting.live_metrics_pulsoid_redirect_uri_override.to_s.strip
      return override if override.present?

      "#{Discourse.base_url}/live-metrics/auth/pulsoid/callback"
    end

    def self.authorization_url(state:)
      uri = ::LiveMetrics::ProviderTransport.pulsoid_https_uri!(SiteSetting.live_metrics_pulsoid_authorize_url)
      uri.query = URI.encode_www_form(
        response_type: "code",
        client_id: SiteSetting.live_metrics_pulsoid_client_id,
        redirect_uri: redirect_uri,
        scope: scopes.join(","),
        state: state
      )
      uri.to_s
    end

    def self.exchange_code!(code:)
      response = post_form(
        SiteSetting.live_metrics_pulsoid_token_url,
        client_id: SiteSetting.live_metrics_pulsoid_client_id,
        client_secret: SiteSetting.live_metrics_pulsoid_client_secret,
        code: code,
        grant_type: "authorization_code",
        redirect_uri: redirect_uri
      )

      parse_token_response!(response)
    end

    def self.refresh!(account)
      expected_refresh_token_cipher = account.refresh_token_cipher.to_s
      refresh_token = account.refresh_token
      raise Unauthorized.new(
        "Missing Pulsoid refresh token",
        classification: :authorization_failed,
      ) if refresh_token.blank?

      response = post_form(
        SiteSetting.live_metrics_pulsoid_token_url,
        client_id: SiteSetting.live_metrics_pulsoid_client_id,
        client_secret: SiteSetting.live_metrics_pulsoid_client_secret,
        refresh_token: refresh_token,
        grant_type: "refresh_token"
      )

      token_payload = parse_token_response!(response)
      apply_refreshed_token_payload!(
        account,
        token_payload,
        expected_refresh_token_cipher: expected_refresh_token_cipher,
      )
      token_payload
    end

    def self.revoke(account)
      token = account.access_token
      return false if token.blank?

      post_form(SiteSetting.live_metrics_pulsoid_revoke_url, token: token)
      true
    rescue => e
      ::LiveMetrics::SafeLog.warn("pulsoid_revoke_failed", error: e, user_id: account.user_id)
      false
    end

    # Performs one uncached provider request. Background refresh jobs use this
    # method so web requests never wait for Pulsoid when async current readings
    # are enabled. `latest` remains as the legacy, cached synchronous wrapper.
    def self.fetch_latest(account, persist_last_error: true)
      with_refreshed_token(account) do |token|
        response = get_json(SiteSetting.live_metrics_pulsoid_latest_url, token: token)
        clear_last_error(account) if persist_last_error
        normalize_latest_response(response)
      end
    rescue NoHeartRateData
      clear_last_error(account) if persist_last_error
      { status: "no_data", heart_rate: nil, measured_at: nil, measured_at_ms: nil }
    rescue Unauthorized => e
      persist_unauthorized(account) if persist_last_error
      { status: "unauthorized", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: e.message }
    rescue => e
      ::LiveMetrics::SafeLog.warn("pulsoid_latest_failed", error: e, account_id: account.id)
      { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "Pulsoid data is temporarily unavailable." }
    end

    def self.latest(account)
      cache_key = "live_metrics:pulsoid:latest:v1:#{account.id}:#{account.updated_at.to_i}"
      Discourse.cache.fetch(cache_key, expires_in: SiteSetting.live_metrics_api_cache_seconds.seconds) do
        fetch_latest(account)
      end
    end

    def self.statistics(account, time_range: "24h")
      return nil unless SiteSetting.live_metrics_statistics_enabled
      safe_range = %w[24h 7d 30d].include?(time_range.to_s) ? time_range.to_s : "24h"
      cache_key = "live_metrics:pulsoid:statistics:v1:#{account.id}:#{safe_range}:#{account.updated_at.to_i}"

      Discourse.cache.fetch(cache_key, expires_in: 10.minutes) do
        with_refreshed_token(account) do |token|
          get_json(SiteSetting.live_metrics_pulsoid_statistics_url, token: token, query: { time_range: safe_range })
        end
      end
    rescue => e
      ::LiveMetrics::SafeLog.warn("pulsoid_statistics_failed", error: e, account_id: account.id, range: safe_range)
      nil
    end

    def self.profile(account)
      with_refreshed_token(account) do |token|
        get_json(SiteSetting.live_metrics_pulsoid_profile_url, token: token)
      end
    rescue => e
      ::LiveMetrics::SafeLog.warn("pulsoid_profile_failed", error: e, account_id: account.id)
      nil
    end

    def self.apply_refreshed_token_payload!(account, payload, expected_refresh_token_cipher:)
      now = Time.zone.now
      attributes = {
        access_token_cipher: ::LiveMetrics::TokenCipher.encrypt(payload.fetch("access_token")),
        refresh_token_cipher: ::LiveMetrics::TokenCipher.encrypt(payload.fetch("refresh_token")),
        token_expires_at: now + payload.fetch("expires_in").to_i.seconds,
        scopes: scopes_from_token_payload(payload).join(" "),
        last_error: nil,
        updated_at: now,
      }

      updated =
        account.class
          .where(id: account.id, refresh_token_cipher: expected_refresh_token_cipher)
          .update_all(attributes)

      if updated != 1
        raise StaleCredentials.new(
          "Pulsoid credentials changed while a token refresh was in progress.",
        )
      end

      account.reload
    end

    def self.clear_last_error(account)
      return if account.last_error.blank?

      updated =
        account.class
          .where(
            id: account.id,
            updated_at: account.updated_at,
            access_token_cipher: account.access_token_cipher,
            refresh_token_cipher: account.refresh_token_cipher,
          )
          .update_all(last_error: nil)
      account.last_error = nil if updated == 1
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def self.persist_unauthorized(account)
      now = Time.zone.now
      updated =
        account.class
          .where(
            id: account.id,
            updated_at: account.updated_at,
            access_token_cipher: account.access_token_cipher,
            refresh_token_cipher: account.refresh_token_cipher,
          )
          .update_all(last_error: "unauthorized", updated_at: now)
      if updated == 1
        account.last_error = "unauthorized"
        account.updated_at = now
      end
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def self.apply_token_payload!(account, payload)
      account.access_token = payload.fetch("access_token")
      account.refresh_token = payload.fetch("refresh_token")
      account.token_expires_at = Time.zone.now + payload.fetch("expires_in").to_i.seconds
      account.scopes = scopes_from_token_payload(payload).join(" ")
      account.last_error = nil
      account
    end

    def self.scopes_from_token_payload(payload)
      raw_scopes = payload["scopes"].presence || payload["scope"].presence

      parsed =
        case raw_scopes
        when Array
          raw_scopes
        when String
          raw_scopes.split(/[\s,]+/)
        else
          scopes
        end

      parsed.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def self.with_refreshed_token(account)
      if defined?(::LiveMetrics::PulsoidTokenManager)
        snapshot = ::LiveMetrics::PulsoidTokenManager.snapshot(account)
        return yield snapshot.access_token
      end

      refresh!(account) if account.token_refresh_recommended?
      token = account.access_token
      raise Unauthorized.new(
        "Missing Pulsoid access token",
        classification: :authorization_failed,
      ) if token.blank?

      yield token
    rescue Unauthorized => original_error
      begin
        if defined?(::LiveMetrics::PulsoidTokenManager)
          snapshot = ::LiveMetrics::PulsoidTokenManager.snapshot(account, force_refresh: true)
          return yield snapshot.access_token
        end

        refresh!(account)
        token = account.access_token
        raise Unauthorized.new(
          "Missing Pulsoid access token after refresh",
          classification: :authorization_failed,
        ) if token.blank?
        yield token
      rescue => refresh_error
        token_manager_error =
          defined?(::LiveMetrics::PulsoidTokenManager::Error) &&
            refresh_error.is_a?(::LiveMetrics::PulsoidTokenManager::Error)
        raise original_error if token_manager_error || refresh_error.is_a?(Error)

        raise
      end
    end

    def self.normalize_latest_response(response)
      measured_at_ms = response["measured_at"].to_i
      heart_rate = response.dig("data", "heart_rate")
      measured_at = measured_at_ms.positive? ? Time.zone.at(measured_at_ms / 1000.0) : nil
      age_seconds = measured_at ? [Time.zone.now.to_i - measured_at.to_i, 0].max : nil

      status =
        if heart_rate.blank?
          "no_data"
        elsif age_seconds && age_seconds <= SiteSetting.live_metrics_live_threshold_seconds.to_i
          "live"
        elsif age_seconds && age_seconds <= SiteSetting.live_metrics_stale_threshold_seconds.to_i
          "delayed"
        else
          "stale"
        end

      {
        status: status,
        heart_rate: heart_rate,
        measured_at: measured_at&.iso8601,
        measured_at_ms: measured_at_ms.positive? ? measured_at_ms : nil,
        age_seconds: age_seconds
      }
    end

    def self.parse_token_response!(response)
      body = parse_json(response.body)
      unless response.is_a?(Net::HTTPSuccess) && body["access_token"].present? && body["refresh_token"].present?
        raise error_for_response(status: response.code.to_i, body: response.body)
      end
      body
    end

    def self.error_for_response(status:, body:)
      status = status.to_i
      parsed = parse_json(body)
      provider_code = extract_provider_error_code(parsed)
      classification = PROVIDER_ERROR_CLASSIFICATIONS[provider_code]
      classification ||= classification_for_status(status)

      error_class =
        if %i[authorization_failed token_expired].include?(classification)
          Unauthorized
        else
          Error
        end

      error_class.new(
        safe_error_message(classification),
        status: status,
        body: nil,
        classification: classification,
        provider_code: provider_code,
      )
    end

    def self.get_json(url, token:, query: nil)
      uri = ::LiveMetrics::ProviderTransport.pulsoid_https_uri!(url)
      uri.query = URI.encode_www_form(query) if query.present?
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}"
      request["User-Agent"] = USER_AGENT

      response = perform(uri, request)
      if response.code.to_i == 412
        raise NoHeartRateData.new(
          "Pulsoid has no heart-rate data yet",
          status: 412,
          classification: :no_data,
        )
      end
      raise error_for_response(status: response.code.to_i, body: response.body) unless response.is_a?(Net::HTTPSuccess)

      parse_json(response.body)
    end


    def self.extract_provider_error_code(parsed)
      return nil unless parsed.is_a?(Hash)

      value =
        parsed["error_code"] ||
          parsed.dig("error", "code") ||
          parsed["code"]
      value.to_s.presence
    end

    def self.classification_for_status(status)
      case status.to_i
      when 401, 403
        :authorization_failed
      when 402
        :subscription_required
      when 429
        :rate_limited
      when 500..599
        :provider_unavailable
      else
        :provider_unavailable
      end
    end

    def self.safe_error_message(classification)
      case classification.to_sym
      when :authorization_failed, :token_expired
        "Pulsoid authorization failed."
      when :subscription_required
        "Pulsoid subscription is required."
      when :scope_required
        "Pulsoid permission is missing."
      when :rate_limited
        "Pulsoid rate limit was reached."
      when :configuration_error
        "Pulsoid authorization configuration is invalid."
      else
        "Pulsoid is temporarily unavailable."
      end
    end

    def self.post_form(url, params)
      uri = ::LiveMetrics::ProviderTransport.pulsoid_https_uri!(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request["Accept"] = "application/json"
      request["User-Agent"] = USER_AGENT
      request.body = URI.encode_www_form(params)

      perform(uri, request)
    end

    def self.perform(uri, request)
      uri = ::LiveMetrics::ProviderTransport.pulsoid_https_uri!(uri.to_s)
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 8
      http.read_timeout = 10
      response = http.start { |client| client.request(request) }
      ensure_response_size!(response)
      response
    end

    def self.ensure_response_size!(response)
      size = response.body.to_s.bytesize
      raise Error.new("Pulsoid response exceeded the safe size limit") if size > MAX_RESPONSE_BYTES
    end

    def self.parse_json(body)
      JSON.parse(body.to_s.presence || "{}")
    rescue JSON::ParserError
      {}
    end

    def self.safe_body(body)
      body.to_s.gsub(/[A-Fa-f0-9-]{20,}/, "[filtered]").truncate(500)
    end
  end
end
