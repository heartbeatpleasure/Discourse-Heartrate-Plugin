# frozen_string_literal: true

RSpec.describe "LiveMetrics API", type: :request do
  fab!(:user)
  fab!(:viewer)
  fab!(:other_viewer)
  fab!(:admin)
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
    SiteSetting.live_metrics_directory_enabled = true
    SiteSetting.live_metrics_viewer_groups = ""
    SiteSetting.live_metrics_allowed_sharer_groups = ""
    sign_in(user)
    LiveMetrics::RefreshCoordinator.stop(account)
  end

  after do
    LiveMetrics::RefreshCoordinator.stop(account)
    LiveMetrics::CurrentStateStore.delete(account)
  end

  def write_live_reading(heart_rate: 92)
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: heart_rate,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
  end

  def directory_usernames
    get "/live-metrics/api/directory"
    expect(response.status).to eq(200)
    response.parsed_body.fetch("users", []).filter_map { |row| row.dig("user", "username") }
  end

  def user_card_usernames
    get "/live-metrics/api/user-cards", params: { usernames: [user.username] }
    expect(response.status).to eq(200)
    response.parsed_body.fetch("readings", []).filter_map { |row| row["username"] }
  end

  def status_count
    get "/live-metrics/api/status"
    expect(response.status).to eq(200)
    response.parsed_body.fetch("count")
  end

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

  it "hides private readings from regular members on the overview and user cards" do
    account.update!(
      visibility: "private",
      show_in_directory: true,
      show_on_user_card: true,
    )
    write_live_reading

    sign_in(viewer)

    expect(directory_usernames).not_to include(user.username)
    expect(user_card_usernames).not_to include(user.username_lower)
    expect(status_count).to eq(0)
  end

  it "shows private readings to the owner and staff" do
    account.update!(
      visibility: "private",
      show_in_directory: true,
      show_on_user_card: true,
    )
    write_live_reading

    sign_in(user)
    expect(directory_usernames).to include(user.username)
    expect(user_card_usernames).to include(user.username_lower)
    expect(status_count).to eq(1)

    sign_in(admin)
    expect(directory_usernames).to include(user.username)
    expect(user_card_usernames).to include(user.username_lower)
    expect(status_count).to eq(1)
  end

  it "only shows specific-user readings to selected members and staff" do
    account.update!(
      visibility: "specific_users",
      specific_user_ids: [viewer.id],
      show_in_directory: true,
      show_on_user_card: true,
    )
    write_live_reading

    sign_in(viewer)
    expect(directory_usernames).to include(user.username)
    expect(user_card_usernames).to include(user.username_lower)
    expect(status_count).to eq(1)

    sign_in(other_viewer)
    expect(directory_usernames).not_to include(user.username)
    expect(user_card_usernames).not_to include(user.username_lower)
    expect(status_count).to eq(0)

    sign_in(admin)
    expect(directory_usernames).to include(user.username)
    expect(user_card_usernames).to include(user.username_lower)
    expect(status_count).to eq(1)
  end

  it "excludes blocked members but never blocks staff" do
    account.update!(
      visibility: "logged_in",
      blocked_user_ids: [viewer.id, admin.id],
      show_in_directory: true,
      show_on_user_card: true,
    )
    write_live_reading

    sign_in(viewer)
    expect(directory_usernames).not_to include(user.username)
    expect(user_card_usernames).not_to include(user.username_lower)
    expect(status_count).to eq(0)

    sign_in(other_viewer)
    expect(directory_usernames).to include(user.username)
    expect(user_card_usernames).to include(user.username_lower)
    expect(status_count).to eq(1)

    sign_in(admin)
    expect(directory_usernames).to include(user.username)
    expect(user_card_usernames).to include(user.username_lower)
    expect(status_count).to eq(1)
  end

  it "never calls providers while calculating the personalized badge count" do
    account.update!(visibility: "logged_in", show_in_directory: true)
    write_live_reading
    SiteSetting.live_metrics_async_current_readings_enabled = false
    sign_in(viewer)

    LiveMetrics::HypeRateClient.expects(:latest).never
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never
    LiveMetrics::PulsoidClient.expects(:latest).never
    LiveMetrics::PulsoidClient.expects(:fetch_latest).never

    expect(status_count).to eq(1)
  end

  it "returns zero badge count when the overview is disabled" do
    account.update!(visibility: "logged_in", show_in_directory: true)
    write_live_reading
    SiteSetting.live_metrics_directory_enabled = false

    get "/live-metrics/api/status"

    expect(response.status).to eq(200)
    expect(response.parsed_body["live"]).to eq(false)
    expect(response.parsed_body["count"]).to eq(0)
    expect(response.parsed_body["directory_enabled"]).to eq(false)
  end

  it "does not return staff in blocked-user search and refuses direct blocked-list writes" do
    sign_in(user)

    get "/live-metrics/api/user-search", params: { q: admin.username, mode: "blocked" }
    expect(response.status).to eq(200)
    expect(response.parsed_body.fetch("users", []).map { |row| row["username"] }).not_to include(
      admin.username,
    )

    put "/live-metrics/api/accounts/hyperate/audience-users",
        params: {
          mode: "blocked",
          username: admin.username,
        }

    expect(response.status).to eq(422)
    expect(response.parsed_body["error"]).to eq("staff_cannot_be_blocked")
    expect(account.reload.blocked_user_ids).not_to include(admin.id)
  end

end
