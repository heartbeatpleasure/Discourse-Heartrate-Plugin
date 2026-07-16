# frozen_string_literal: true

class PurgePulsoidProfileMetadata < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:live_metrics_provider_accounts)

    assignments = []
    assignments << "profile_data = NULL" if column_exists?(:live_metrics_provider_accounts, :profile_data)
    assignments << "provider_uid = NULL" if column_exists?(:live_metrics_provider_accounts, :provider_uid)
    assignments << "last_profile_synced_at = NULL" if column_exists?(:live_metrics_provider_accounts, :last_profile_synced_at)
    assignments << "display_name = 'Pulsoid account'" if column_exists?(:live_metrics_provider_accounts, :display_name)
    return if assignments.empty?

    execute <<~SQL.squish
      UPDATE live_metrics_provider_accounts
      SET #{assignments.join(", ")}
      WHERE provider = 'pulsoid'
    SQL
  end

  # The removed provider profile metadata may contain personal information and
  # is intentionally not recoverable during rollback. Tokens and sharing
  # settings are not touched by this migration.
  def down
  end
end
