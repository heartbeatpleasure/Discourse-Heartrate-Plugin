# frozen_string_literal: true

RSpec.describe LiveMetrics::PulsoidStreamingSession do
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
    account.access_token = "session-access"
    account.refresh_token = "session-refresh"
    account.token_expires_at = 1.hour.from_now
    account.save!
    account
  end

  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_streaming_enabled = true
    SiteSetting.live_metrics_pulsoid_client_id = "client-id"
    SiteSetting.live_metrics_pulsoid_client_secret = "client-secret"
    SiteSetting.live_metrics_pulsoid_ws_url =
      "wss://dev.pulsoid.net/api/v1/data/real_time"
  end

  after do
    LiveMetrics::PulsoidStreamingRegistry.invalidate_session(account)
    LiveMetrics::CurrentStateStore.delete(account)
  end

  it "tracks transport frames and readings independently" do
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )
    session.stubs(:monotonic_now).returns(100.0, 101.0, 103.0, 104.0)

    session.send(:record_frame_received)
    session.send(:record_frame_received)
    session.send(:record_reading_received)

    expect(session.frame_count).to eq(2)
    expect(session.reading_count).to eq(1)
    expect(session.last_frame_age_seconds).to eq(3)
    expect(session.last_event_age_seconds).to eq(1)
  end

  it "uses exponential reconnect backoff with jitter and a hard maximum" do
    SecureRandom.stubs(:random_number).returns(0)
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )

    expect((1..6).map { |attempt| session.send(:reconnect_delay, attempt) }).to eq(
      [1.0, 2.0, 4.0, 8.0, 16.0, 30.0],
    )
    expect(session.send(:reconnect_delay, 100)).to be <= 30
  end

  it "classifies subscription and scope failures without a fast reconnect loop" do
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )
    subscription_error = LiveMetrics::PulsoidStreamingClient::ProviderError.new(
      "safe",
      status: 402,
      classification: :subscription_required,
      provider_code: "7007",
    )
    scope_error = LiveMetrics::PulsoidStreamingClient::ProviderError.new(
      "safe",
      status: 400,
      classification: :scope_required,
      provider_code: "7011",
    )

    expect(session.send(:retry_delay_for, subscription_error, 1)).to eq(5.minutes.to_i)
    expect(session.send(:retry_delay_for, scope_error, 1)).to eq(5.minutes.to_i)
  end

  it "does not replace a recent reading with a transient transport error" do
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )
    expect(LiveMetrics::PulsoidStreamingRegistry.activate_session(account, session.token)).to eq(true)
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 82,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )

    session.send(:write_error_state, "unavailable")

    expect(LiveMetrics::CurrentStateStore.read(account)[:heart_rate]).to eq(82)
  end

  it "does not let an older WebSocket reading overwrite a newer current state" do
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )
    expect(LiveMetrics::PulsoidStreamingRegistry.activate_session(account, session.token)).to eq(true)

    newer_ms = (Time.zone.now.to_f * 1000).to_i
    newer = { status: "live", heart_rate: 88, measured_at_ms: newer_ms }
    older = { status: "live", heart_rate: 67, measured_at_ms: newer_ms - 5_000 }

    expect(session.send(:write_reading, newer)).to eq(true)
    expect(session.send(:write_reading, older)).to eq(false)

    current = LiveMetrics::CurrentStateStore.read(account)
    expect(current[:heart_rate]).to eq(88)
    expect(current[:measured_at_ms]).to eq(newer_ms)
  end


  it "performs only one immediate forced refresh after a handshake authorization failure" do
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )
    expect(LiveMetrics::PulsoidStreamingRegistry.activate_session(account, session.token)).to eq(true)
    snapshot = LiveMetrics::PulsoidTokenManager.snapshot(account)
    error = LiveMetrics::PulsoidStreamingClient::ProviderError.new(
      "safe",
      status: 403,
      classification: :authorization_failed,
      provider_code: "7005",
    )

    session.stubs(:with_database).yields
    session.stubs(:session_current?).returns(true, true, false)
    session.stubs(:account_eligible?).returns(true)
    session.stubs(:sleep_interruptibly)
    LiveMetrics::PulsoidTokenManager.expects(:snapshot).with(account.id).once.returns(snapshot)
    LiveMetrics::PulsoidTokenManager
      .expects(:snapshot)
      .with(account.id, force_refresh: true)
      .once
      .returns(snapshot)
    LiveMetrics::PulsoidStreamingClient.expects(:stream).once.raises(error)

    session.send(:run)
  end

  it "records an authorization failure with only a safe internal state" do
    session = described_class.new(
      database: "default",
      account_id: account.id,
      fingerprint: "fingerprint",
    )
    expect(LiveMetrics::PulsoidStreamingRegistry.activate_session(account, session.token)).to eq(true)
    snapshot = LiveMetrics::PulsoidTokenManager.snapshot(account)
    error = LiveMetrics::PulsoidStreamingClient::ProviderError.new(
      "safe",
      status: 403,
      classification: :authorization_failed,
      provider_code: "7005",
    )

    session.send(:handle_error, error, snapshot, 0)

    expect(session.unauthorized?).to eq(true)
    expect(session.authorization_failure_count).to eq(1)
    expect(account.reload.last_error).to eq("reconnect_required")
    state = LiveMetrics::CurrentStateStore.read(account)
    expect(state[:status]).to eq("unauthorized")
    expect(state[:heart_rate]).to be_nil
  end
end
