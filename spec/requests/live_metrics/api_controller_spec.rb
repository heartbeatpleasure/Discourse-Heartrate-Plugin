# frozen_string_literal: true

RSpec.describe "LiveMetrics API", type: :request do
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

  before do
    Jobs.stubs(:enqueue)
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_hyperate_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_viewer_groups = ""
    sign_in(user)
    LiveMetrics::RefreshCoordinator.stop(account)
  end

  after { LiveMetrics::RefreshCoordinator.stop(account) }

  it "reads live preview data from Redis without calling a provider" do
    now_ms = (Time.zone.now.to_f * 1000).to_i
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 87,
      measured_at_ms: now_ms,
    )

    LiveMetrics::HypeRateClient.expects(:latest).never
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never
    LiveMetrics::PulsoidClient.expects(:latest).never
    LiveMetrics::PulsoidClient.expects(:fetch_latest).never

    get "/live-metrics/api/live-preview"

    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("account", "live", "heart_rate")).to eq(87)
    expect(response.parsed_body.dig("account", "live", "status")).to eq("live")
  end

  it "returns immediately with no_data when Redis has no state" do
    LiveMetrics::HypeRateClient.expects(:latest).never
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never

    get "/live-metrics/api/live-preview"

    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("account", "live", "status")).to eq("no_data")
    expect(response.parsed_body.dig("account", "live", "heart_rate")).to be_nil
  end

  it "serves user-card readings from the batched current-state store" do
    account.update!(show_on_user_card: true, visibility: "logged_in")
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 92,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )

    LiveMetrics::HypeRateClient.expects(:latest).never
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never

    get "/live-metrics/api/user-cards", params: { usernames: [user.username] }

    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("readings", 0, "heart_rate")).to eq(92)
    expect(response.parsed_body.dig("readings", 0, "username")).to eq(user.username_lower)
  end

  it "keeps the legacy synchronous path available while the feature flag is disabled" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    LiveMetrics::HypeRateClient.expects(:latest).with(
      instance_of(LiveMetrics::ProviderAccount),
    ).returns(
      status: "live",
      heart_rate: 79,
      measured_at: Time.zone.now.iso8601,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
      age_seconds: 0,
    )
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never

    get "/live-metrics/api/live-preview"

    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("account", "live", "heart_rate")).to eq(79)
  end
end
