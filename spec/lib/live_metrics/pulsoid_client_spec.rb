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

end
