# frozen_string_literal: true

RSpec.describe LiveMetrics::PulsoidStreamingRegistry do
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
    account.access_token = "registry-access"
    account.refresh_token = "registry-refresh"
    account.save!
    account
  end

  let(:token) { "pulsoid-stream-token" }

  after do
    described_class.invalidate_session(account)
    described_class.release_leader("leader-a")
    described_class.release_leader("leader-b")
    described_class.clear_health
    LiveMetrics::CurrentStateStore.delete(account)
  end

  it "prevents duplicate sessions and guards current-state writes by ownership" do
    expect(described_class.activate_session(account, token)).to eq(true)
    expect(described_class.activate_session(account, "second-token")).to eq(false)

    state = described_class.write_state_if_current(
      account,
      {
        status: "live",
        heart_rate: 84,
        measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
      },
      token,
    )
    expect(state[:heart_rate]).to eq(84)

    described_class.invalidate_session(account)
    expect(
      described_class.write_state_if_current(
        account,
        {
          status: "live",
          heart_rate: 99,
          measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
        },
        token,
      ),
    ).to be_nil
    expect(LiveMetrics::CurrentStateStore.read(account)[:heart_rate]).to eq(84)
  end

  it "allows only one collector leader per site" do
    expect(described_class.acquire_or_renew_leader("leader-a")).to eq(true)
    expect(described_class.acquire_or_renew_leader("leader-a")).to eq(true)
    expect(described_class.acquire_or_renew_leader("leader-b")).to eq(false)

    described_class.release_leader("leader-a")
    expect(described_class.acquire_or_renew_leader("leader-b")).to eq(true)
  end

  it "publishes only privacy-safe aggregate health" do
    now_ms = (Time.now.to_f * 1000).to_i
    described_class.publish_health(
      collector_started_at_ms: now_ms - 60_000,
      desired_sessions: 3,
      sessions: 2,
      connected: 1,
      reconnecting: 1,
      unauthorized: 0,
      subscription_required: 1,
      scope_required: 0,
      stalled: 1,
      oldest_event_age_seconds: 27,
      oldest_frame_age_seconds: 3,
      frames: 25,
      readings: 20,
      reconnects: 4,
      authorization_failures: 2,
      limit: 100,
      limit_reached: true,
      last_reconnect_reason: "subscription_required",
      last_reconnect_at_ms: now_ms - 5_000,
      last_successful_join_at_ms: now_ms - 10_000,
      username: "must-not-leak",
      heart_rate: 99,
      token: "must-not-leak",
    )

    health = described_class.read_health
    expect(health).to include(
      "v" => 1,
      "desired_sessions" => 3,
      "sessions" => 2,
      "connected" => 1,
      "subscription_required" => 1,
      "frames" => 25,
      "readings" => 20,
      "authorization_failures" => 2,
      "limit_reached" => true,
      "last_reconnect_reason" => "subscription_required",
    )
    expect(health.keys).not_to include(
      "username",
      "account_id",
      "provider_uid",
      "email",
      "heart_rate",
      "access_token",
      "refresh_token",
      "token",
    )
  end
end
