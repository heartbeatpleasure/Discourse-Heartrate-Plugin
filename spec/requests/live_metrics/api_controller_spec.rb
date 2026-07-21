# frozen_string_literal: true

RSpec.describe "LiveMetrics API", type: :request do
  fab!(:user)
  fab!(:viewer)
  fab!(:other_viewer)
  fab!(:new_user)
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

  it "enables overview and user-card sharing for a new HypeRate connection" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    SiteSetting.live_metrics_allowed_visibility_options = "private|logged_in"
    sign_in(new_user)

    LiveMetrics::HypeRateClient.stubs(:configured?).returns(true)
    LiveMetrics::HypeRateClient.stubs(:normalize_device_id).returns("new-device")
    LiveMetrics::HypeRateClient.stubs(:valid_device_id?).returns(true)

    put "/live-metrics/api/connect/hyperate", params: { device_id: "new-device" }

    expect(response.status).to eq(200)
    connected = LiveMetrics::ProviderAccount.find_by!(
      user: new_user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
    )
    expect(connected).to have_attributes(
      active: true,
      visibility: "logged_in",
      show_on_user_card: true,
      show_in_directory: true,
      show_on_profile: false,
    )
  end

  it "preserves sharing preferences when an existing HypeRate connection is updated" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    account.update!(
      visibility: "private",
      show_on_user_card: false,
      show_in_directory: false,
      show_on_profile: false,
    )

    LiveMetrics::HypeRateClient.stubs(:configured?).returns(true)
    LiveMetrics::HypeRateClient.stubs(:normalize_device_id).returns("replacement-device")
    LiveMetrics::HypeRateClient.stubs(:valid_device_id?).returns(true)

    put "/live-metrics/api/connect/hyperate", params: { device_id: "replacement-device" }

    expect(response.status).to eq(200)
    expect(account.reload).to have_attributes(
      visibility: "private",
      show_on_user_card: false,
      show_in_directory: false,
      show_on_profile: false,
    )
  end

  it "restarts the active HypeRate connection without deleting its account" do
    LiveMetrics::RefreshCoordinator
      .expects(:restart)
      .with { |candidate| candidate.id == account.id }
      .returns(true)

    put "/live-metrics/api/accounts/hyperate/reconnect"

    expect(response.status).to eq(200)
    expect(response.parsed_body["reconnected"]).to eq(true)
    expect(response.parsed_body["provider"]).to eq("hyperate")
    expect(account.reload.provider_uid).to eq("test-device")
    expect(response.parsed_body.dig("account", "active")).to eq(true)
  end

  it "does not reconnect an inactive provider" do
    account.update!(active: false)
    LiveMetrics::RefreshCoordinator.expects(:restart).never

    put "/live-metrics/api/accounts/hyperate/reconnect"

    expect(response.status).to eq(422)
    expect(response.parsed_body["error"]).to eq("provider_not_active")
  end

  it "hides manual reconnect when background readings are disabled" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    LiveMetrics::RefreshCoordinator.expects(:restart).never

    get "/live-metrics/api/config"
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("providers", "hyperate", "reconnect_supported")).to eq(false)

    put "/live-metrics/api/accounts/hyperate/reconnect"
    expect(response.status).to eq(422)
    expect(response.parsed_body["error"]).to eq("reconnect_unavailable")
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

  context "with an active Pulsoid account" do
    fab!(:pulsoid_account) do
      created = LiveMetrics::ProviderAccount.new(
        user: user,
        provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
        display_name: "Pulsoid account",
        visibility: "logged_in",
        active: false,
        show_on_profile: true,
        show_on_user_card: true,
        show_in_directory: true,
        scopes: "data:heart_rate:read data:statistics:read",
      )
      created.access_token = "pulsoid-access"
      created.refresh_token = "pulsoid-refresh"
      created.token_expires_at = 1.hour.from_now
      created.save!
      created
    end

    before do
      SiteSetting.live_metrics_pulsoid_enabled = true
      account.update!(active: false)
      pulsoid_account.activate!
      LiveMetrics::RefreshCoordinator.stop(pulsoid_account)
    end

    after do
      LiveMetrics::RefreshCoordinator.stop(pulsoid_account)
      LiveMetrics::CurrentStateStore.delete(pulsoid_account)
    end

    it "restarts the active Pulsoid connection without removing OAuth credentials" do
      access_cipher = pulsoid_account.access_token_cipher
      refresh_cipher = pulsoid_account.refresh_token_cipher
      LiveMetrics::RefreshCoordinator
        .expects(:restart)
        .with { |candidate| candidate.id == pulsoid_account.id }
        .returns(true)

      put "/live-metrics/api/accounts/pulsoid/reconnect"

      expect(response.status).to eq(200)
      expect(response.parsed_body["reconnected"]).to eq(true)
      expect(response.parsed_body["provider"]).to eq("pulsoid")
      expect(pulsoid_account.reload.access_token_cipher).to eq(access_cipher)
      expect(pulsoid_account.refresh_token_cipher).to eq(refresh_cipher)
    end

    it "returns detailed Pulsoid status only to the account owner" do
      pulsoid_account.update!(last_error: "scope_required")

      get "/live-metrics/api/me"
      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("account", "owner_status")).to eq(
        "code" => "scope_required",
        "message" => "Pulsoid permission is incomplete. Reconnect your account.",
      )

      sign_in(viewer)
      get "/live-metrics/api/users/#{user.username}"
      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("account", "owner_status")).to be_nil
      expect(response.body).not_to include("scope_required")
    end

    it "maps no-data state to a private owner status without exposing it publicly" do
      LiveMetrics::CurrentStateStore.delete(pulsoid_account)

      get "/live-metrics/api/live-preview"
      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("account", "owner_status", "code")).to eq("no_data")
      expect(response.parsed_body.dig("account", "owner_status", "message")).to eq(
        "No heart-rate signal from Pulsoid.",
      )
    end

    it "never performs Pulsoid statistics requests for profile payloads" do
      SiteSetting.live_metrics_statistics_enabled = true
      LiveMetrics::PulsoidClient.expects(:statistics).never
      LiveMetrics::PulsoidClient.expects(:latest).never
      LiveMetrics::PulsoidClient.expects(:fetch_latest).never
      LiveMetrics::CurrentStateStore.write(
        pulsoid_account,
        status: "live",
        heart_rate: 88,
        measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
      )

      get "/live-metrics/api/users/#{user.username}"

      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("account", "statistics")).to be_nil
    end
  end

end
