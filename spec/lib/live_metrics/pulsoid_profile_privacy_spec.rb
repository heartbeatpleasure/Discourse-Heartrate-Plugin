# frozen_string_literal: true

require_relative "../../../db/migrate/20260716000100_purge_pulsoid_profile_metadata"

RSpec.describe PurgePulsoidProfileMetadata do
  fab!(:pulsoid_user) { Fabricate(:user) }
  fab!(:hyperate_user) { Fabricate(:user) }

  it "removes only Pulsoid profile metadata while preserving credentials and sharing" do
    pulsoid = LiveMetrics::ProviderAccount.new(
      user: pulsoid_user,
      provider: "pulsoid",
      provider_uid: "private-profile-id",
      display_name: "private@example.test",
      profile_data: { "email" => "private@example.test" }.to_json,
      last_profile_synced_at: 1.day.ago,
      visibility: "specific_users",
      show_on_profile: true,
      show_on_user_card: true,
      show_in_directory: true,
      active: true,
    )
    pulsoid.access_token = "preserved-access"
    pulsoid.refresh_token = "preserved-refresh"
    pulsoid.token_expires_at = 1.hour.from_now
    pulsoid.save!

    hyperate = LiveMetrics::ProviderAccount.create!(
      user: hyperate_user,
      provider: "hyperate",
      provider_uid: "device-id",
      display_name: "HypeRate device",
      profile_data: { "safe" => "unchanged" }.to_json,
      visibility: "private",
      active: true,
    )

    described_class.new.up

    expect(pulsoid.reload).to have_attributes(
      provider_uid: nil,
      display_name: "Pulsoid account",
      profile_data: nil,
      last_profile_synced_at: nil,
      visibility: "specific_users",
      show_on_profile: true,
      show_on_user_card: true,
      show_in_directory: true,
      active: true,
    )
    expect(pulsoid.access_token).to eq("preserved-access")
    expect(pulsoid.refresh_token).to eq("preserved-refresh")
    expect(hyperate.reload).to have_attributes(
      provider_uid: "device-id",
      display_name: "HypeRate device",
      profile_data: { "safe" => "unchanged" }.to_json,
    )
  end
end
