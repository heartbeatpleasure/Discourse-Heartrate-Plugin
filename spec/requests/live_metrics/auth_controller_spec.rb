# frozen_string_literal: true

RSpec.describe "LiveMetrics Pulsoid OAuth", type: :request do
  fab!(:user)

  let(:token_payload) do
    {
      "access_token" => "access-token",
      "refresh_token" => "refresh-token",
      "expires_in" => 3600,
      "scope" => "data:heart_rate:read",
    }
  end

  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_client_id = "client-id"
    SiteSetting.live_metrics_pulsoid_client_secret = "client-secret"
    SiteSetting.live_metrics_allowed_sharer_groups = "trust_level_0"
    LiveMetrics::AdminEventLog.clear
    sign_in(user)
  end

  after { LiveMetrics::AdminEventLog.clear }

  def start_oauth
    get "/live-metrics/api/connect/pulsoid"
    expect(response.status).to eq(302)
    Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
  end

  def stub_valid_exchange(expires_in: 1800)
    LiveMetrics::PulsoidClient.stubs(:exchange_code!).returns(token_payload)
    LiveMetrics::PulsoidClient.stubs(:validate_token_payload!).returns(
      "expires_in" => expires_in,
      "scopes" => ["data:heart_rate:read"],
    )
  end

  def complete_oauth(state, code: "authorization-code")
    get "/live-metrics/auth/pulsoid/callback", params: { state: state, code: code }
  end

  it "records a broad client context when OAuth leaves Discourse" do
    LiveMetrics::PulsoidClient.stubs(:authorization_url).returns(
      "https://pulsoid.example/oauth/authorize",
    )

    get "/live-metrics/api/connect/pulsoid",
        headers: {
          "HTTP_USER_AGENT" =>
            "Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36",
        }

    expect(response.status).to eq(302)
    expect(response.location).to eq("https://pulsoid.example/oauth/authorize")
    expect(LiveMetrics::AdminEventLog.recent.first).to include(
      provider: "pulsoid",
      event: "oauth_start",
      result: "redirected",
      client_context: "embedded_webview",
    )
  end

  it "validates the token before storing a new Pulsoid connection" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    stub_valid_exchange(expires_in: 900)
    LiveMetrics::PulsoidClient.expects(:profile).never

    state = start_oauth
    complete_oauth(state)

    expect(response.location).to include("connected=pulsoid")
    connected = LiveMetrics::ProviderAccount.find_by!(user: user, provider: "pulsoid")
    expect(connected.token_expires_at).to be_within(10.seconds).of(15.minutes.from_now)
    expect(connected).to have_attributes(
      provider_uid: nil,
      display_name: "Pulsoid account",
      profile_data: nil,
      last_profile_synced_at: nil,
    )
  end

  it "applies the preferred sharing defaults to a new Pulsoid connection" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    SiteSetting.live_metrics_allowed_visibility_options = "private|logged_in"
    stub_valid_exchange

    state = start_oauth
    complete_oauth(state)

    expect(response.status).to eq(302)
    expect(response.location).to include("connected=pulsoid")
    connected = LiveMetrics::ProviderAccount.find_by!(user: user, provider: "pulsoid")
    expect(connected).to have_attributes(
      active: true,
      visibility: "logged_in",
      show_on_user_card: true,
      show_in_directory: true,
      show_on_profile: false,
    )
  end

  it "preserves sharing preferences and removes old profile metadata on reauthorization" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    existing = LiveMetrics::ProviderAccount.new(
      user: user,
      provider: "pulsoid",
      visibility: "private",
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
      active: true,
      provider_uid: "private-provider-identity",
      display_name: "private@example.test",
      profile_data: { "username" => "private@example.test" },
      last_profile_synced_at: 1.day.ago,
    )
    existing.access_token = "old-access-token"
    existing.refresh_token = "old-refresh-token"
    existing.save!
    stub_valid_exchange

    state = start_oauth
    complete_oauth(state)

    expect(response.status).to eq(302)
    expect(existing.reload).to have_attributes(
      visibility: "private",
      show_on_user_card: false,
      show_in_directory: false,
      show_on_profile: false,
      provider_uid: nil,
      display_name: "Pulsoid account",
      profile_data: nil,
      last_profile_synced_at: nil,
    )
  end

  it "supports multiple parallel OAuth attempts and rejects replay" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    stub_valid_exchange

    first_state = start_oauth
    second_state = start_oauth

    complete_oauth(first_state, code: "first-code")
    expect(response.location).to include("connected=pulsoid")

    complete_oauth(second_state, code: "second-code")
    expect(response.location).to include("connected=pulsoid")

    complete_oauth(first_state, code: "replayed-code")
    expect(response.location).to include("error=oauth_state_mismatch")
  end

  it "expires pending OAuth states after ten minutes" do
    state = start_oauth

    travel_to(11.minutes.from_now) do
      complete_oauth(state)
      expect(response.location).to include("error=oauth_state_mismatch")
    end
  end

  it "keeps at most five pending OAuth states" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    stub_valid_exchange

    states = 6.times.map { start_oauth }

    complete_oauth(states.first)
    expect(response.location).to include("error=oauth_state_mismatch")

    complete_oauth(states.last)
    expect(response.location).to include("connected=pulsoid")
  end

  it "removes only the matched state when Pulsoid returns an OAuth error" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    stub_valid_exchange
    first_state = start_oauth
    second_state = start_oauth

    get "/live-metrics/auth/pulsoid/callback",
        params: { state: first_state, error: "access_denied" }
    expect(response.location).to include("error=access_denied")

    complete_oauth(second_state)
    expect(response.location).to include("connected=pulsoid")
  end

  it "does not store credentials when token validation fails" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    LiveMetrics::PulsoidClient.stubs(:exchange_code!).returns(token_payload)
    LiveMetrics::PulsoidClient.stubs(:validate_token_payload!).raises(
      LiveMetrics::PulsoidClient::ValidationError.new(
        "missing scope",
        classification: :scope_required,
      ),
    )

    complete_oauth(start_oauth)

    expect(response.location).to include("error=pulsoid_scope_required")
    expect(LiveMetrics::ProviderAccount.find_by(user: user, provider: "pulsoid")).to be_nil
  end

  it "invalidates Pulsoid stream ownership and current state on disconnect" do
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_pulsoid_streaming_enabled = true
    SiteSetting.live_metrics_pulsoid_ws_url =
      "wss://dev.pulsoid.net/api/v1/data/real_time"

    account = LiveMetrics::ProviderAccount.new(
      user: user,
      provider: "pulsoid",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
    account.access_token = "disconnect-access"
    account.refresh_token = "disconnect-refresh"
    account.token_expires_at = 1.hour.from_now
    account.save!

    stream_token = "disconnect-session"
    expect(LiveMetrics::PulsoidStreamingRegistry.activate_session(account, stream_token)).to eq(true)
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 89,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
    LiveMetrics::PulsoidClient.expects(:revoke).with { |candidate| candidate.id == account.id }.returns(true)

    delete "/live-metrics/auth/pulsoid"

    expect(response.status).to eq(200)
    expect(LiveMetrics::ProviderAccount.find_by(id: account.id)).to be_nil
    expect(LiveMetrics::PulsoidStreamingRegistry.session_current?(account.id, stream_token)).to eq(false)
    expect(LiveMetrics::CurrentStateStore.read(account.id)).to be_nil
  end

  it "always completes local disconnect when remote revoke fails" do
    account = LiveMetrics::ProviderAccount.new(user: user, provider: "pulsoid", active: true)
    account.access_token = "disconnect-access"
    account.refresh_token = "disconnect-refresh"
    account.save!
    LiveMetrics::PulsoidClient.stubs(:revoke).returns(false)

    delete "/live-metrics/auth/pulsoid"

    expect(response.status).to eq(200)
    expect(LiveMetrics::ProviderAccount.find_by(id: account.id)).to be_nil
    expect(LiveMetrics::AdminEventLog.recent).to include(
      include(provider: "pulsoid", event: "provider_disconnect", result: "revoke_failed"),
    )
  end

  it "records an OAuth state mismatch without weakening state validation" do
    get "/live-metrics/auth/pulsoid/callback",
        params: { state: "unexpected", code: "authorization-code" }

    expect(response.status).to eq(302)
    expect(response.location).to include("error=oauth_state_mismatch")
    expect(LiveMetrics::AdminEventLog.recent.first).to include(
      provider: "pulsoid",
      event: "oauth_callback",
      result: "state_mismatch",
      severity: "warning",
    )
  end

  it "maps arbitrary provider errors to a bounded code without logging descriptions" do
    LiveMetrics::SafeLog.expects(:warn).with(
      "pulsoid_oauth_provider_error",
      user_id: user.id,
      oauth_error: "oauth_error",
    )

    get "/live-metrics/auth/pulsoid/callback",
        params: {
          error: "unexpected provider value",
          error_description: "access_token=must-never-be-logged",
        }

    expect(response.status).to eq(302)
    expect(response.location).to include("error=oauth_error")
    expect(response.location).not_to include("must-never-be-logged")
  end
end
