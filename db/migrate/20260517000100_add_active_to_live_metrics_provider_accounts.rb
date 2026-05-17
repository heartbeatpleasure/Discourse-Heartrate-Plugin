# frozen_string_literal: true

class AddActiveToLiveMetricsProviderAccounts < ActiveRecord::Migration[7.0]
  def up
    add_column :live_metrics_provider_accounts, :active, :boolean, null: false, default: false
    add_index :live_metrics_provider_accounts, [:user_id, :active], name: "idx_live_metrics_accounts_user_active"

    execute <<~SQL.squish
      UPDATE live_metrics_provider_accounts
      SET active = TRUE
      WHERE id IN (
        SELECT DISTINCT ON (user_id) id
        FROM live_metrics_provider_accounts
        ORDER BY user_id, updated_at DESC, id DESC
      )
    SQL
  end

  def down
    remove_index :live_metrics_provider_accounts, name: "idx_live_metrics_accounts_user_active", if_exists: true
    remove_column :live_metrics_provider_accounts, :active, if_exists: true
  end
end
