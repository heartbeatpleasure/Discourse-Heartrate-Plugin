# frozen_string_literal: true

RSpec.describe LiveMetrics::PulsoidClient do
  fab!(:user)
  fab!(:account) do
    account = LiveMetrics::ProviderAccount.new(
      user: user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
    account.access_token = "old-access"
    account.refresh_token = "old-refresh"
    account.token_expires_at = 1.hour.from_now
    account.save!
    account
  end

  let(:refreshed_payload) do
    {
      "access_token" => "new-access",
      "refresh_token" => "new-refresh",
      "expires_in" => 3600,
      "scope" => "data:heart_rate:read",
    }
  end

  it "atomically applies refreshed credentials when the source token is unchanged" do
    expected_cipher = account.refresh_token_cipher

    described_class.apply_refreshed_token_payload!(
      account,
      refreshed_payload,
      expected_refresh_token_cipher: expected_cipher,
    )

    expect(account.access_token).to eq("new-access")
    expect(account.refresh_token).to eq("new-refresh")
    expect(account.scopes_list).to include("data:heart_rate:read")
  end

  it "never overwrites credentials from a concurrent reconnect" do
    stale_cipher = account.refresh_token_cipher
    account.access_token = "reconnected-access"
    account.refresh_token = "reconnected-refresh"
    account.save!

    expect do
      described_class.apply_refreshed_token_payload!(
        account,
        refreshed_payload,
        expected_refresh_token_cipher: stale_cipher,
      )
    end.to raise_error(LiveMetrics::PulsoidClient::StaleCredentials)

    account.reload
    expect(account.access_token).to eq("reconnected-access")
    expect(account.refresh_token).to eq("reconnected-refresh")
  end
  it "does not apply a stale provider error after the account changed" do
    stale_account = LiveMetrics::ProviderAccount.find(account.id)
    account.update!(display_name: "Reconnected Pulsoid")

    described_class.persist_unauthorized(stale_account)

    expect(account.reload.last_error).to be_nil
  end

  it "refuses insecure or off-domain provider endpoint configuration" do
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_client_id = "client-id"
    SiteSetting.live_metrics_pulsoid_client_secret = "client-secret"
    SiteSetting.live_metrics_pulsoid_authorize_url = "http://pulsoid.net/oauth2/authorize"

    expect(described_class.configured?).to eq(false)

    SiteSetting.live_metrics_pulsoid_authorize_url =
      "https://pulsoid.net.evil.test/oauth2/authorize"
    expect(described_class.configured?).to eq(false)
  end

  it "rejects provider responses that exceed the safe size limit" do
    response = stub(body: "x" * (described_class::MAX_RESPONSE_BYTES + 1))

    expect do
      described_class.ensure_response_size!(response)
    end.to raise_error(LiveMetrics::PulsoidClient::Error, /safe size limit/)
  end

  it "classifies documented provider failures without exposing raw provider text" do
    cases = {
      [403, 7005] => :authorization_failed,
      [403, 7006] => :token_expired,
      [402, 7007] => :subscription_required,
      [400, 7011] => :scope_required,
      [400, 6003] => :scope_required,
      [400, 7009] => :configuration_error,
      [400, 7001] => :provider_unavailable,
      [429, nil] => :rate_limited,
      [503, nil] => :provider_unavailable,
    }

    cases.each do |(status, provider_code), expected|
      body =
        if provider_code
          { error_code: provider_code, error_message: "secret provider detail" }.to_json
        else
          { error_message: "secret provider detail" }.to_json
        end
      error = described_class.error_for_response(status: status, body: body)

      expect(error.classification).to eq(expected)
      expect(error.message).not_to include("secret provider detail")
      expect(error.body).to be_nil
    end
  end

  it "uses the shared token manager for HTTP requests" do
    snapshot = LiveMetrics::PulsoidTokenManager::Snapshot.new(
      account_id: account.id,
      access_token: "managed-access-token",
      expires_at: 1.hour.from_now,
      credential_fingerprint: "fingerprint",
    )
    LiveMetrics::PulsoidTokenManager.expects(:snapshot).with(account).returns(snapshot)

    yielded = described_class.with_refreshed_token(account) { |token| token }

    expect(yielded).to eq("managed-access-token")
  end

end
