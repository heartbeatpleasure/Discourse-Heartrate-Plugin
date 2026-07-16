# frozen_string_literal: true

RSpec.describe LiveMetrics::PulsoidTokenManager do
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
    account.access_token = "old-access-token"
    account.refresh_token = "old-refresh-token"
    account.token_expires_at = 1.hour.from_now
    account.save!
    account
  end

  after do
    Discourse.redis.del(described_class.lock_key(account.id))
  end

  it "returns a redacted token snapshot when no refresh is needed" do
    LiveMetrics::PulsoidClient.expects(:refresh!).never

    snapshot = described_class.snapshot(account)

    expect(snapshot.access_token).to eq("old-access-token")
    expect(snapshot.credential_fingerprint).to be_present
    expect(snapshot.inspect).not_to include("old-access-token", "old-refresh-token")
  end

  it "serializes per-account refresh ownership with compare-and-delete" do
    first = described_class.acquire_lock(account)
    second = described_class.acquire_lock(account)

    expect(first).to be_present
    expect(second).to be_nil
    expect(described_class.release_lock(account, "wrong-token")).to eq(false)
    expect(described_class.release_lock(account, first)).to eq(true)
    expect(described_class.acquire_lock(account)).to be_present
  end

  it "refreshes expiring credentials and uses the rotated token pair" do
    account.update!(token_expires_at: 1.minute.from_now)
    LiveMetrics::PulsoidClient.expects(:refresh!).once.with do |refresh_account|
      refresh_account.access_token = "rotated-access-token"
      refresh_account.refresh_token = "rotated-refresh-token"
      refresh_account.token_expires_at = 1.hour.from_now
      refresh_account.save!
      true
    end

    snapshot = described_class.snapshot(account)

    expect(snapshot.access_token).to eq("rotated-access-token")
    expect(account.reload.refresh_token).to eq("rotated-refresh-token")
    expect(snapshot.socket_refresh_deadline).to be < snapshot.expires_at
  end

  it "waits for a concurrent owner and reuses its newer credentials" do
    initial_fingerprint = described_class.credential_fingerprint(account)
    described_class.stubs(:acquire_lock).returns(nil)
    described_class.stubs(:monotonic_now).returns(0.0, 0.1)
    described_class.expects(:sleep).once do
      account.access_token = "concurrent-access-token"
      account.refresh_token = "concurrent-refresh-token"
      account.token_expires_at = 1.hour.from_now
      account.save!
      true
    end
    LiveMetrics::PulsoidClient.expects(:refresh!).never

    snapshot = described_class.snapshot(account, force_refresh: true)

    expect(snapshot.access_token).to eq("concurrent-access-token")
    expect(snapshot.credential_fingerprint).not_to eq(initial_fingerprint)
  end
end
