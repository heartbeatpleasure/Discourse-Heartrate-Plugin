# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateStreamingRegistry do
  fab!(:user)
  fab!(:account) do
    LiveMetrics::ProviderAccount.create!(
      user: user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "test-device",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
  end

  let(:token) { "stream-token" }

  after do
    described_class.invalidate_session(account)
    described_class.release_leader("leader-a")
    described_class.release_leader("leader-b")
    described_class.clear_health
    LiveMetrics::CurrentStateStore.delete(account)
  end

  it "guards current-state writes with the active stream token" do
    expect(described_class.activate_session(account, token)).to eq(true)

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
    rejected = described_class.write_state_if_current(
      account,
      {
        status: "live",
        heart_rate: 99,
        measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
      },
      token,
    )

    expect(rejected).to be_nil
    expect(LiveMetrics::CurrentStateStore.read(account)[:heart_rate]).to eq(84)
  end

  it "publishes privacy-safe streaming watchdog health" do
    now_ms = (Time.now.to_f * 1000).to_i
    described_class.publish_health(
      collector_started_at_ms: now_ms - 60_000,
      sessions: 2,
      connected: 1,
      reconnecting: 1,
      unauthorized: 0,
      stalled: 1,
      oldest_event_age_seconds: 27,
      oldest_frame_age_seconds: 3,
      frames: 25,
      readings: 20,
      reconnects: 4,
      stalls: 2,
      limit: 100,
      limit_reached: true,
      last_reconnect_reason: "transport_stalled",
      last_reconnect_at_ms: now_ms - 5_000,
      last_successful_join_at_ms: now_ms - 10_000,
    )

    health = described_class.read_health

    expect(health).to include(
      "v" => 4,
      "sessions" => 2,
      "connected" => 1,
      "reconnecting" => 1,
      "unauthorized" => 0,
      "stalled" => 1,
      "oldest_event_age_seconds" => 27,
      "oldest_frame_age_seconds" => 3,
      "frames" => 25,
      "readings" => 20,
      "reconnects" => 4,
      "stalls" => 2,
      "limit" => 100,
      "limit_reached" => true,
      "last_reconnect_reason" => "transport_stalled",
      "last_join_result" => "successful",
    )
    expect(health.keys).not_to include(
      "heart_rate",
      "device_id",
      "provider_uid",
      "account_id",
      "api_key",
      "token",
    )
  end

  it "allows only one collector leader per site" do
    expect(described_class.acquire_or_renew_leader("leader-a")).to eq(true)
    expect(described_class.acquire_or_renew_leader("leader-a")).to eq(true)
    expect(described_class.acquire_or_renew_leader("leader-b")).to eq(false)

    described_class.release_leader("leader-a")

    expect(described_class.acquire_or_renew_leader("leader-b")).to eq(true)
  end
end
