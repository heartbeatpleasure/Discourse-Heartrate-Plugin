# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module ::LiveMetrics
  class PulsoidClient
    DEFAULT_SCOPES = %w[data:heart_rate:read]
    STATISTICS_SCOPE = "data:statistics:read"
    USER_AGENT = "Discourse Heartrate Pulsoid PoC/0.1"

    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class Unauthorized < Error; end
    class NoHeartRateData < Error; end
    class StaleCredentials < Error; end

    def self.configured?
      SiteSetting.live_metrics_pulsoid_enabled &&
        SiteSetting.live_metrics_pulsoid_client_id.to_s.present? &&
        SiteSetting.live_metrics_pulsoid_client_secret.to_s.present?
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
      uri = URI.parse(SiteSetting.live_metrics_pulsoid_authorize_url)
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
      raise Unauthorized.new("Missing Pulsoid refresh token") if refresh_token.blank?

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
      Rails.logger.warn("[live_metrics] Pulsoid revoke failed user_id=#{account.user_id} error=#{e.class}: #{e.message}")
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
      Rails.logger.warn("[live_metrics] Pulsoid latest failed account_id=#{account.id} error=#{e.class}: #{e.message}")
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
      Rails.logger.warn("[live_metrics] Pulsoid statistics failed account_id=#{account.id} range=#{safe_range} error=#{e.class}: #{e.message}")
      nil
    end

    def self.profile(account)
      with_refreshed_token(account) do |token|
        get_json(SiteSetting.live_metrics_pulsoid_profile_url, token: token)
      end
    rescue => e
      Rails.logger.warn("[live_metrics] Pulsoid profile failed account_id=#{account.id} error=#{e.class}: #{e.message}")
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
      refresh!(account) if account.token_refresh_recommended?

      token = account.access_token
      raise Unauthorized.new("Missing Pulsoid access token") if token.blank?

      yield token
    rescue Unauthorized
      refresh!(account)
      token = account.access_token
      raise Unauthorized.new("Missing Pulsoid access token after refresh") if token.blank?

      yield token
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
        raise Error.new("Pulsoid token request failed", status: response.code.to_i, body: safe_body(response.body))
      end
      body
    end

    def self.get_json(url, token:, query: nil)
      uri = URI.parse(url)
      uri.query = URI.encode_www_form(query) if query.present?
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}"
      request["User-Agent"] = USER_AGENT

      response = perform(uri, request)
      raise NoHeartRateData.new("Pulsoid has no heart-rate data yet", status: 412) if response.code.to_i == 412
      raise Unauthorized.new("Pulsoid authorization failed", status: response.code.to_i) if response.code.to_i == 401
      raise Error.new("Pulsoid API request failed", status: response.code.to_i, body: safe_body(response.body)) unless response.is_a?(Net::HTTPSuccess)

      parse_json(response.body)
    end

    def self.post_form(url, params)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request["Accept"] = "application/json"
      request["User-Agent"] = USER_AGENT
      request.body = URI.encode_www_form(params)

      perform(uri, request)
    end

    def self.perform(uri, request)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 8, read_timeout: 10) do |http|
        http.request(request)
      end
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
