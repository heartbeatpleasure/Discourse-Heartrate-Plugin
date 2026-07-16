# frozen_string_literal: true

RSpec.describe LiveMetrics::ProviderTransport do
  describe ".pulsoid_https_uri!" do
    it "accepts TLS URLs on the Pulsoid root domain and subdomains" do
      expect(described_class.pulsoid_https_uri!("https://pulsoid.net/oauth2/token").host).to eq(
        "pulsoid.net",
      )
      expect(described_class.pulsoid_https_uri!("https://dev.pulsoid.net/api/v1/profile").host).to eq(
        "dev.pulsoid.net",
      )
    end

    it "rejects insecure, off-domain and credential-bearing URLs" do
      invalid_urls = [
        "http://pulsoid.net/oauth2/token",
        "https://pulsoid.net.evil.test/oauth2/token",
        "https://user:password@pulsoid.net/oauth2/token",
        "https://pulsoid.net:8443/oauth2/token",
      ]

      invalid_urls.each do |url|
        expect { described_class.pulsoid_https_uri!(url) }.to raise_error(
          LiveMetrics::ProviderTransport::InvalidUrl,
        )
      end
    end
  end

  describe ".pulsoid_wss_uri!" do
    it "accepts secure WebSocket URLs on Pulsoid" do
      uri = described_class.pulsoid_wss_uri!(
        "wss://dev.pulsoid.net/api/v1/data/real_time",
      )

      expect(uri.scheme).to eq("wss")
      expect(uri.host).to eq("dev.pulsoid.net")
      expect(uri.port).to eq(443)
    end

    it "rejects unsafe Pulsoid WebSocket URLs" do
      invalid_urls = [
        "ws://dev.pulsoid.net/api/v1/data/real_time",
        "wss://pulsoid.net.evil.test/api/v1/data/real_time",
        "wss://user:password@dev.pulsoid.net/api/v1/data/real_time",
        "wss://dev.pulsoid.net:8443/api/v1/data/real_time",
        "wss://dev.pulsoid.net/#fragment",
      ]

      invalid_urls.each do |url|
        expect { described_class.pulsoid_wss_uri!(url) }.to raise_error(
          LiveMetrics::ProviderTransport::InvalidUrl,
        )
        expect(described_class.valid_pulsoid_wss_url?(url)).to eq(false)
      end
    end
  end

  describe ".hyperate_wss_uri!" do
    it "accepts secure WebSocket URLs on HypeRate" do
      uri = described_class.hyperate_wss_uri!("wss://app.hyperate.io/ws/:deviceId")

      expect(uri.scheme).to eq("wss")
      expect(uri.host).to eq("app.hyperate.io")
    end

    it "rejects insecure or off-domain WebSocket URLs" do
      invalid_urls = [
        "ws://app.hyperate.io/ws/:deviceId",
        "wss://hyperate.io.evil.test/ws/:deviceId",
        "wss://user:password@app.hyperate.io/ws/:deviceId",
        "wss://app.hyperate.io:8443/ws/:deviceId",
      ]

      invalid_urls.each do |url|
        expect { described_class.hyperate_wss_uri!(url) }.to raise_error(
          LiveMetrics::ProviderTransport::InvalidUrl,
        )
      end
    end
  end
end
