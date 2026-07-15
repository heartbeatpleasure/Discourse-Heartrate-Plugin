# frozen_string_literal: true

RSpec.describe LiveMetrics::ProviderAccount do
  fab!(:owner) { Fabricate(:user) }
  fab!(:viewer) { Fabricate(:user) }

  it "accepts specific-users visibility and bounded audience arrays" do
    account = described_class.create!(
      user: owner,
      provider: described_class::PROVIDER_HYPERATE,
      provider_uid: "audience-test-device",
      visibility: "specific_users",
      specific_user_ids: [viewer.id],
      blocked_user_ids: [],
    )

    expect(account.visibility).to eq("specific_users")
    expect(account.specific_user_ids).to eq([viewer.id])
    expect(described_class::MAX_AUDIENCE_USERS).to eq(100)
  end
  it "keeps exactly one active provider when switching accounts" do
    first = described_class.create!(
      user: owner,
      provider: described_class::PROVIDER_HYPERATE,
      provider_uid: "active-provider-device",
      visibility: "private",
      active: true,
    )
    second = described_class.new(
      user: owner,
      provider: described_class::PROVIDER_PULSOID,
      visibility: "private",
      active: false,
    )
    second.access_token = "access-token"
    second.refresh_token = "refresh-token"
    second.save!

    second.activate!

    expect(described_class.where(user: owner, active: true).pluck(:id)).to eq([second.id])
    expect(first.reload.active).to eq(false)
  end

end
