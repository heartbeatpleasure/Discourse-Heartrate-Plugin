# frozen_string_literal: true

class AddLiveMetricsProviderAccountUserForeignKey < ActiveRecord::Migration[7.0]
  FOREIGN_KEY_NAME = "fk_live_metrics_provider_accounts_user"

  def up
    return unless table_exists?(:live_metrics_provider_accounts)
    return unless table_exists?(:users)

    # Repair only pre-existing orphan rows so the foreign key can be validated.
    # Current-state and refresh keys have short hard TTLs and are also reconciled
    # by the collector after the account row disappears.
    execute <<~SQL.squish
      DELETE FROM live_metrics_provider_accounts AS accounts
      WHERE NOT EXISTS (
        SELECT 1
        FROM users
        WHERE users.id = accounts.user_id
      )
    SQL

    if column_exists?(:live_metrics_provider_accounts, :specific_user_ids) &&
         column_exists?(:live_metrics_provider_accounts, :blocked_user_ids)
      # Remove references to users that were deleted before lifecycle cleanup was
      # introduced. WITH ORDINALITY preserves the user's existing list order.
      execute <<~SQL.squish
        UPDATE live_metrics_provider_accounts AS accounts
        SET
          specific_user_ids = ARRAY(
            SELECT audience.user_id
            FROM unnest(accounts.specific_user_ids) WITH ORDINALITY AS audience(user_id, position)
            WHERE EXISTS (
              SELECT 1 FROM users WHERE users.id = audience.user_id
            )
            ORDER BY audience.position
          ),
          blocked_user_ids = ARRAY(
            SELECT audience.user_id
            FROM unnest(accounts.blocked_user_ids) WITH ORDINALITY AS audience(user_id, position)
            WHERE EXISTS (
              SELECT 1 FROM users WHERE users.id = audience.user_id
            )
            ORDER BY audience.position
          )
      SQL
    end

    unless foreign_key_exists?(
      :live_metrics_provider_accounts,
      :users,
      column: :user_id,
      name: FOREIGN_KEY_NAME,
    )
      add_foreign_key(
        :live_metrics_provider_accounts,
        :users,
        column: :user_id,
        on_delete: :cascade,
        name: FOREIGN_KEY_NAME,
        validate: false,
      )
    end

    validate_foreign_key(
      :live_metrics_provider_accounts,
      :users,
      name: FOREIGN_KEY_NAME,
    )
  end

  def down
    remove_foreign_key(
      :live_metrics_provider_accounts,
      name: FOREIGN_KEY_NAME,
      if_exists: true,
    )
  end
end
