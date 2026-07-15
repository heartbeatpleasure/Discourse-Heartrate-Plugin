# frozen_string_literal: true

class EnforceSingleActiveLiveMetricsProvider < ActiveRecord::Migration[7.0]
  INDEX_NAME = "idx_live_metrics_accounts_one_active_per_user"

  def up
    # Repair only impossible duplicate-active states, preserving the most recently
    # updated account. Normal installations should update zero rows here.
    execute <<~SQL.squish
      WITH ranked_active_accounts AS (
        SELECT
          id,
          ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY updated_at DESC, id DESC
          ) AS active_rank
        FROM live_metrics_provider_accounts
        WHERE active = TRUE
      )
      UPDATE live_metrics_provider_accounts
      SET active = FALSE, updated_at = CURRENT_TIMESTAMP
      WHERE id IN (
        SELECT id
        FROM ranked_active_accounts
        WHERE active_rank > 1
      )
    SQL

    add_index(
      :live_metrics_provider_accounts,
      :user_id,
      unique: true,
      where: "active = TRUE",
      name: INDEX_NAME,
    )
  end

  def down
    remove_index :live_metrics_provider_accounts, name: INDEX_NAME, if_exists: true
  end
end
