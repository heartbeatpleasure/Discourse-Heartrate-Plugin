# frozen_string_literal: true

RSpec.describe LiveMetrics::UserLifecycleCleanup do
  fab!(:target_user) { Fabricate(:user) }
  fab!(:other_user) { Fabricate(:user) }
  fab!(:audience_owner) { Fabricate(:user) }
  fab!(:admin) { Fabricate(:admin) }

  let!(:hyperate_account) do
    LiveMetrics::ProviderAccount.create!(
      user: target_user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "lifecycle-hyperate-device",
      visibility: "logged_in",
      active: true,
      show_on_profile: true,
      show_on_user_card: true,
      show_in_directory: true,
    )
  end

  let!(:pulsoid_account) do
    account = LiveMetrics::ProviderAccount.new(
      user: target_user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      visibility: "private",
      active: false,
    )
    account.access_token = "lifecycle-access-token"
    account.refresh_token = "lifecycle-refresh-token"
    account.save!
    account
  end

  let!(:audience_account) do
    LiveMetrics::ProviderAccount.create!(
      user: audience_owner,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "audience-owner-device",
      visibility: "specific_users",
      specific_user_ids: [target_user.id, other_user.id],
      blocked_user_ids: [target_user.id],
      active: true,
    )
  end

  before do
    Jobs.stubs(:enqueue)
    now_ms = (Time.zone.now.to_f * 1000).to_i
    LiveMetrics::CurrentStateStore.write(
      hyperate_account,
      status: "live",
      heart_rate: 81,
      measured_at_ms: now_ms,
    )
    LiveMetrics::CurrentStateStore.write(
      pulsoid_account,
      status: "live",
      heart_rate: 82,
      measured_at_ms: now_ms,
    )
    Discourse.redis.set(
      LiveMetrics::RefreshCoordinator.loop_key(hyperate_account.id),
      "lifecycle-generation",
      ex: 120,
    )
    Discourse.redis.set(
      LiveMetrics::RefreshCoordinator.fetch_lock_key(hyperate_account.id),
      "lifecycle-lock",
      ex: 120,
    )
  end

  after do
    [hyperate_account.id, pulsoid_account.id, audience_account.id].each do |account_id|
      LiveMetrics::RefreshCoordinator.stop(account_id)
      LiveMetrics::CurrentStateStore.delete(account_id)
    end
  end

  it "purges provider accounts, current state, refresh ownership, and audience references" do
    result = described_class.purge_user!(target_user, reason: "spec")

    expect(result[:success]).to eq(true)
    expect(result[:removed_accounts]).to eq(2)
    expect(LiveMetrics::ProviderAccount.where(user_id: target_user.id)).to be_empty
    expect(LiveMetrics::CurrentStateStore.read(hyperate_account.id)).to be_nil
    expect(LiveMetrics::CurrentStateStore.read(pulsoid_account.id)).to be_nil
    expect(
      Discourse.redis.get(LiveMetrics::RefreshCoordinator.loop_key(hyperate_account.id)),
    ).to be_nil
    expect(
      Discourse.redis.get(LiveMetrics::RefreshCoordinator.fetch_lock_key(hyperate_account.id)),
    ).to be_nil

    audience_account.reload
    expect(audience_account.specific_user_ids).to contain_exactly(other_user.id)
    expect(audience_account.blocked_user_ids).to be_empty
  end

  it "is idempotent" do
    first = described_class.purge_user!(target_user, reason: "spec")
    second = described_class.purge_user!(target_user, reason: "spec_repeat")

    expect(first[:success]).to eq(true)
    expect(second[:success]).to eq(true)
    expect(second[:removed_accounts]).to eq(0)
    expect(audience_account.reload.specific_user_ids).to contain_exactly(other_user.id)
  end

  it "purges Live Metrics data when a user is anonymized" do
    UserAnonymizer.make_anonymous(target_user, admin)

    expect(LiveMetrics::ProviderAccount.where(user_id: target_user.id)).to be_empty
    expect(LiveMetrics::CurrentStateStore.read(hyperate_account.id)).to be_nil
    expect(audience_account.reload.specific_user_ids).to contain_exactly(other_user.id)
    expect(audience_account.blocked_user_ids).to be_empty
  end

  it "purges Live Metrics data before a user is destroyed" do
    target_user.destroy!

    expect(LiveMetrics::ProviderAccount.where(user_id: target_user.id)).to be_empty
    expect(LiveMetrics::CurrentStateStore.read(hyperate_account.id)).to be_nil
    expect(audience_account.reload.specific_user_ids).to contain_exactly(other_user.id)
    expect(audience_account.blocked_user_ids).to be_empty
  end
end
