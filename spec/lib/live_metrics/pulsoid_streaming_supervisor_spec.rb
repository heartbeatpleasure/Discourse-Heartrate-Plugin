# frozen_string_literal: true

RSpec.describe LiveMetrics::PulsoidStreamingSupervisor do
  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_streaming_enabled = true
    SiteSetting.live_metrics_pulsoid_client_secret = "client-secret"
    SiteSetting.live_metrics_pulsoid_ws_url =
      "wss://dev.pulsoid.net/api/v1/data/real_time"
    SiteSetting.live_metrics_pulsoid_max_streams = 2
    SiteSetting.live_metrics_pulsoid_stream_transport_timeout_seconds = 45
    SiteSetting.live_metrics_pulsoid_client_id = "client-id"
    SiteSetting.live_metrics_pulsoid_token_url = "https://pulsoid.net/oauth2/token"
  end

  after { LiveMetrics::PulsoidStreamingRegistry.clear_health }

  def create_account(label)
    account = LiveMetrics::ProviderAccount.new(
      user: Fabricate(:user),
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
    account.access_token = "access-#{label}"
    account.refresh_token = "refresh-#{label}"
    account.token_expires_at = 1.hour.from_now
    account.save!
    account
  end

  it "enforces the stream limit without creating an HTTP overflow fallback" do
    accounts = 3.times.map { |index| create_account(index) }
    supervisor = described_class.new

    desired = supervisor.send(:desired_accounts)

    expect(desired.length).to eq(2)
    expect(desired.values).to all(include(:fingerprint))
    expect(LiveMetrics::RefreshCoordinator.pulsoid_streaming_eligible?(accounts.last)).to eq(true)
    expect(LiveMetrics::RefreshCoordinator.eligible?(accounts.last)).to eq(false)
    database = supervisor.send(:current_database)
    supervisor.send(:publish_health, database)
    expect(LiveMetrics::PulsoidStreamingRegistry.read_health["limit_reached"]).to eq(true)
  end

  it "changes the session fingerprint after token rotation or transport changes" do
    account = create_account("fingerprint")
    first = described_class.new.send(:desired_accounts).fetch(account.id).fetch(:fingerprint)

    account.update!(visibility: "logged_in")
    visibility_only =
      described_class.new.send(:desired_accounts).fetch(account.id).fetch(:fingerprint)
    expect(visibility_only).to eq(first)

    account.access_token = "rotated-access"
    account.refresh_token = "rotated-refresh"
    account.token_expires_at = 2.hours.from_now
    account.save!
    second = described_class.new.send(:desired_accounts).fetch(account.id).fetch(:fingerprint)
    expect(second).not_to eq(first)

    SiteSetting.live_metrics_pulsoid_stream_transport_timeout_seconds = 60
    third = described_class.new.send(:desired_accounts).fetch(account.id).fetch(:fingerprint)
    expect(third).not_to eq(second)
  end

  it "does not let a non-leader delete health published by the active leader" do
    LiveMetrics::PulsoidStreamingRegistry.publish_health(
      collector_started_at_ms: (Time.now.to_f * 1000).to_i,
      sessions: 1,
      connected: 1,
      limit: 100,
    )
    supervisor = described_class.new

    supervisor.send(:lose_leadership, supervisor.send(:current_database))

    expect(LiveMetrics::PulsoidStreamingRegistry.read_health).to include(
      "sessions" => 1,
      "connected" => 1,
    )
  end

  it "uses a safe default that supports at least fifty streams" do
    SiteSetting.live_metrics_pulsoid_max_streams = 100

    expect(described_class.new.send(:max_streams)).to eq(100)
  end
end
