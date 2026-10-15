# frozen_string_literal: true

RSpec.describe "LiveMetrics activities API", type: :request do
  fab!(:member)
  fab!(:viewer)
  fab!(:admin)
  fab!(:account) do
    LiveMetrics::ProviderAccount.create!(
      user: member,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "activity-device",
      visibility: "logged_in",
      active: true,
      show_on_profile: true,
      show_on_user_card: true,
      show_in_directory: true,
    )
  end

  before do
    Jobs.stubs(:enqueue)
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_hyperate_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_directory_enabled = true
    SiteSetting.live_metrics_activity_enabled = true
    SiteSetting.live_metrics_activity_predefined_enabled = true
    SiteSetting.live_metrics_activity_custom_enabled = true
    SiteSetting.live_metrics_activity_details_enabled = true
    SiteSetting.live_metrics_activity_expiry_mode = "user_selectable"
    SiteSetting.live_metrics_activity_allow_no_expiry = false
    SiteSetting.live_metrics_viewer_groups = ""
    SiteSetting.live_metrics_allowed_sharer_groups = ""
    sign_in(member)
  end

  after do
    LiveMetrics::Activity.where(user_id: member.id).delete_all
    LiveMetrics::RefreshCoordinator.stop(account)
    LiveMetrics::CurrentStateStore.delete(account)
  end

  def set_activity(label: "Exercising", details: "Weightlifting", duration: 180)
    put "/live-metrics/api/me/activity", params: {
      label: label,
      details: details,
      duration_minutes: duration,
      custom: "false",
    }
  end

  def live_reading
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 92,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
  end

  it "advertises the editable options and expiration controls" do
    get "/live-metrics/api/config"
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("activities", "options")).to include("NSFW", "Leisurely cycling")
    expect(response.parsed_body.dig("activities", "default_durations", "Sleeping")).to eq(480)
    expect(response.parsed_body.dig("activities", "expiry_mode")).to eq("user_selectable")
  end

  it "saves an activity independently from the provider and expires it" do
    freeze_time do
      set_activity
      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("activity", "text")).to eq("Exercising · Weightlifting")
      expect(LiveMetrics::Activity.find_by!(user_id: member.id).expires_at).to be_within(1.second).of(3.hours.from_now)
      get "/live-metrics/api/me"
      expect(response.parsed_body.dig("activity", "text")).to eq("Exercising · Weightlifting")
      LiveMetrics::Activity.where(user_id: member.id).update_all(expires_at: 1.minute.ago)
      get "/live-metrics/api/me"
      expect(response.parsed_body["activity"]).to be_nil
    end
  end

  it "shares activities only with a fresh authorized live reading" do
    set_activity
    expect(response.status).to eq(200)
    sign_in(viewer)
    get "/live-metrics/api/directory"
    expect(response.parsed_body["users"]).to be_empty

    live_reading
    get "/live-metrics/api/directory"
    expect(response.parsed_body.dig("users", 0, "activity", "text")).to eq("Exercising · Weightlifting")
    get "/live-metrics/api/user-cards", params: { usernames: [member.username] }
    expect(response.parsed_body.dig("readings", 0, "activity", "text")).to eq("Exercising · Weightlifting")

    account.update!(visibility: "private")
    get "/live-metrics/api/directory"
    expect(response.parsed_body["users"]).to be_empty
    get "/live-metrics/api/user-cards", params: { usernames: [member.username] }
    expect(response.parsed_body["readings"]).to be_empty
  end

  it "rejects unsupported selections and overlong text" do
    set_activity(label: "NotAnOption")
    expect(response.status).to eq(422)
    set_activity(details: "x" * 41)
    expect(response.status).to eq(422)
    expect(LiveMetrics::Activity.where(user_id: member.id)).to be_empty
  end

  it "supports custom text but hides it immediately when disabled by staff" do
    put "/live-metrics/api/me/activity", params: { custom: "true", text: "Listening to heartbeats", duration_minutes: 240 }
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("activity", "text")).to eq("Listening to heartbeats")

    SiteSetting.live_metrics_activity_custom_enabled = false
    get "/live-metrics/api/me"
    expect(response.parsed_body["activity"]).to be_nil
    put "/live-metrics/api/me/activity", params: { custom: "true", text: "Sneaky", duration_minutes: 240 }
    expect(response.status).to eq(422)
  end

  it "honors explicit no-expiry permission and manual clearing" do
    set_activity(duration: 0)
    expect(response.status).to eq(422)
    SiteSetting.live_metrics_activity_allow_no_expiry = true
    set_activity(duration: 0)
    expect(response.status).to eq(200)
    expect(LiveMetrics::Activity.find_by!(user_id: member.id).expires_at).to be_nil
    delete "/live-metrics/api/me/activity"
    expect(response.status).to eq(200)
    expect(LiveMetrics::Activity.where(user_id: member.id)).to be_empty
  end

  it "hides every activity when the master activity switch is off" do
    set_activity
    SiteSetting.live_metrics_activity_enabled = false
    get "/live-metrics/api/me"
    expect(response.parsed_body["activity"]).to be_nil
    get "/live-metrics/api/config"
    expect(response.parsed_body.dig("activities", "enabled")).to eq(false)
  end

  it "lets administrators moderate an activity but denies ordinary members" do
    set_activity
    delete "/admin/plugins/live-metrics/activities/#{member.username}"
    expect(response.status).not_to eq(200)
    sign_in(admin)
    delete "/admin/plugins/live-metrics/activities/#{member.username}"
    expect(response.status).to eq(200)
    expect(response.parsed_body["cleared"]).to eq(true)
    expect(LiveMetrics::Activity.where(user_id: member.id)).to be_empty
  end

  it "applies fixed and disabled expiry modes without consulting the member's choice" do
    SiteSetting.live_metrics_activity_expiry_mode = "fixed"
    SiteSetting.live_metrics_activity_fixed_duration_minutes = 90
    set_activity(duration: 1440)
    expect(response.status).to eq(200)
    expect(LiveMetrics::Activity.find_by!(user_id: member.id).expires_at).to be_within(3.seconds).of(90.minutes.from_now)

    SiteSetting.live_metrics_activity_expiry_mode = "disabled"
    set_activity(duration: -12)
    expect(response.status).to eq(200)
    expect(LiveMetrics::Activity.find_by!(user_id: member.id).expires_at).to be_nil
  end

  it "removes a disabled detail from the public response without erasing the selection" do
    set_activity
    SiteSetting.live_metrics_activity_details_enabled = false
    get "/live-metrics/api/me"
    expect(response.parsed_body.dig("activity", "text")).to eq("Exercising")
  end

  it "rejects sharing when the member is no longer allowed to share" do
    SiteSetting.live_metrics_allowed_sharer_groups = "staff"
    set_activity
    expect(response.status).to eq(403)
    expect(LiveMetrics::Activity.where(user_id: member.id)).to be_empty
  end

  it "keeps activity after a provider account is changed" do
    set_activity
    expect(response.status).to eq(200)
    account.update!(provider_uid: "new-device-id")
    get "/live-metrics/api/me"
    expect(response.parsed_body.dig("activity", "text")).to eq("Exercising · Weightlifting")
  end
end
