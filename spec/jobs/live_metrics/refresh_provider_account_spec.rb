# frozen_string_literal: true

RSpec.describe Jobs::LiveMetrics::RefreshProviderAccount do
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
    SiteSetting.live_metrics_hyperate_streaming_enabled = false
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_provider_refresh_interval_seconds = 3
    LiveMetrics::RefreshCoordinator.stop(account)
  end

  after { LiveMetrics::RefreshCoordinator.stop(account) }

  it "writes a provider reading and schedules the next run" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    LiveMetrics::HypeRateClient.stubs(:fetch_latest).returns(
      status: "live",
      heart_rate: 88,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
    LiveMetrics::RefreshCoordinator.expects(:enqueue_refresh).returns(true)

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )

    expect(LiveMetrics::CurrentStateStore.read(account)[:heart_rate]).to eq(88)
  end


  it "cannot reintroduce state when the generation changes immediately before write" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    LiveMetrics::HypeRateClient.stubs(:fetch_latest).returns(
      status: "live",
      heart_rate: 90,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
    job = described_class.new
    job.define_singleton_method(:persist_provider_state) do |fetched_account, state, token|
      LiveMetrics::RefreshCoordinator.stop(fetched_account)
      LiveMetrics::RefreshCoordinator.write_state_if_current(fetched_account, state, token)
    end

    job.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )

    expect(LiveMetrics::CurrentStateStore.read(account)).to be_nil
  end

  it "persists reconnect-required state without writing heart-rate history" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    LiveMetrics::HypeRateClient.stubs(:fetch_latest).returns(
      status: "unauthorized",
      heart_rate: nil,
      measured_at_ms: nil,
    )
    LiveMetrics::RefreshCoordinator.stubs(:enqueue_refresh).returns(true)

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )

    expect(account.reload.last_error).to eq("unauthorized")
    state = LiveMetrics::CurrentStateStore.read(account)
    expect(state[:status]).to eq("unauthorized")
    expect(state[:heart_rate]).to be_nil
  end

  it "clears a prior reconnect-required state after a successful reading" do
    account.update!(last_error: "unauthorized")
    generation = LiveMetrics::RefreshCoordinator.start(account)
    LiveMetrics::HypeRateClient.stubs(:fetch_latest).returns(
      status: "live",
      heart_rate: 86,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
    LiveMetrics::RefreshCoordinator.stubs(:enqueue_refresh).returns(true)

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )

    expect(account.reload.last_error).to be_nil
  end

  it "never performs a provider request for an invalidated generation" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    LiveMetrics::RefreshCoordinator.stop(account)
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )
  end

  it "keeps a recent valid reading when a provider temporarily returns no_data" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    now_ms = (Time.zone.now.to_f * 1000).to_i
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 84,
      measured_at_ms: now_ms,
    )
    LiveMetrics::HypeRateClient.stubs(:fetch_latest).returns(
      status: "no_data",
      heart_rate: nil,
      measured_at_ms: nil,
    )
    LiveMetrics::RefreshCoordinator.stubs(:enqueue_refresh).returns(true)

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )

    expect(LiveMetrics::CurrentStateStore.read(account)[:heart_rate]).to eq(84)
  end

  it "retries HypeRate no_data quickly without exponential backoff" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    LiveMetrics::HypeRateClient.stubs(:fetch_latest).returns(
      status: "no_data",
      heart_rate: nil,
      measured_at_ms: nil,
    )
    LiveMetrics::RefreshCoordinator
      .expects(:enqueue_refresh)
      .with(account.id, generation, delay_seconds: 1, attempt: 0)
      .returns(true)

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 4,
    )
  end

  it "reschedules the current generation when an older fetch still owns the lock" do
    generation = LiveMetrics::RefreshCoordinator.start(account)
    lock_token = LiveMetrics::RefreshCoordinator.acquire_fetch_lock(account)
    LiveMetrics::HypeRateClient.expects(:fetch_latest).never
    LiveMetrics::RefreshCoordinator
      .expects(:enqueue_refresh)
      .with(account.id, generation, delay_seconds: 2, attempt: 0)
      .returns(true)

    described_class.new.execute(
      account_id: account.id,
      generation: generation,
      attempt: 0,
    )
  ensure
    LiveMetrics::RefreshCoordinator.release_fetch_lock(account, lock_token) if lock_token
  end
end
