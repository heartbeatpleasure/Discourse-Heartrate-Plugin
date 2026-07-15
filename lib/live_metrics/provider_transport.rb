# frozen_string_literal: true

require "openssl"
require "uri"

module ::LiveMetrics
  class ProviderTransport
    class InvalidUrl < StandardError
      attr_reader :provider, :reason

      def initialize(provider, reason)
        @provider = provider.to_s
        @reason = reason.to_s
        super("Invalid #{provider} provider URL configuration (#{reason}).")
      end
    end

    HTTPS_SCHEME = "https"
    WSS_SCHEME = "wss"
    TLS_PORT = 443

    class << self
      def pulsoid_https_uri!(value)
        validate_uri!(
          value,
          provider: "Pulsoid",
          scheme: HTTPS_SCHEME,
          allowed_root_domain: "pulsoid.net",
        )
      end

      def hyperate_wss_uri!(value)
        validate_uri!(
          value,
          provider: "HypeRate",
          scheme: WSS_SCHEME,
          allowed_root_domain: "hyperate.io",
        )
      end

      def valid_pulsoid_https_url?(value)
        pulsoid_https_uri!(value)
        true
      rescue InvalidUrl, URI::InvalidURIError
        false
      end

      def valid_hyperate_wss_url?(value)
        hyperate_wss_uri!(value)
        true
      rescue InvalidUrl, URI::InvalidURIError
        false
      end

      private

      def validate_uri!(value, provider:, scheme:, allowed_root_domain:)
        uri = URI.parse(value.to_s.strip)
        hostname = normalized_hostname(uri.host)

        raise InvalidUrl.new(provider, "scheme") unless uri.scheme.to_s.downcase == scheme
        raise InvalidUrl.new(provider, "hostname") unless allowed_hostname?(hostname, allowed_root_domain)
        raise InvalidUrl.new(provider, "port") unless uri.port.to_i == TLS_PORT
        raise InvalidUrl.new(provider, "userinfo") if uri.userinfo.present?
        raise InvalidUrl.new(provider, "fragment") if uri.fragment.present?
        raise InvalidUrl.new(provider, "path") if uri.path.to_s.blank?

        uri
      rescue URI::InvalidURIError
        raise InvalidUrl.new(provider, "format")
      end

      def normalized_hostname(value)
        value.to_s.downcase.chomp(".")
      end

      def allowed_hostname?(hostname, root_domain)
        hostname == root_domain || hostname.end_with?(".#{root_domain}")
      end
    end
  end
end
