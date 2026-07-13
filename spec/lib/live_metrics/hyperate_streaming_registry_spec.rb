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
    described_class.publish_health(
      sessions: 2,
      connected: 1,
      reconnecting: 1,
      stalled: 1,
      oldest_event_age_seconds: 27,
      reconnects: 4,
      stalls: 2,
      limit: 100,
    )

    health = JSON.parse(Discourse.redis.get(described_class::HEALTH_KEY))

    expect(health).to include(
      "v" => 2,
      "sessions" => 2,
      "connected" => 1,
      "reconnecting" => 1,
      "stalled" => 1,
      "oldest_event_age_seconds" => 27,
      "reconnects" => 4,
      "stalls" => 2,
      "limit" => 100,
    )
    expect(health.keys).not_to include("heart_rate", "device_id", "api_key")
  end

  it "allows only one collector leader per site" do
    expect(described_class.acquire_or_renew_leader("leader-a")).to eq(true)
    expect(described_class.acquire_or_renew_leader("leader-a")).to eq(true)
    expect(described_class.acquire_or_renew_leader("leader-b")).to eq(false)

    described_class.release_leader("leader-a")

    expect(described_class.acquire_or_renew_leader("leader-b")).to eq(true)
  end
end
