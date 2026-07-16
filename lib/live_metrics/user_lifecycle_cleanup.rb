# frozen_string_literal: true

module ::LiveMetrics
  class UserLifecycleCleanup
    SHARING_COLUMNS = %i[active show_on_profile show_in_directory show_on_user_card].freeze

    class << self
      # Permanently removes all locally stored Live Metrics data for a user.
      #
      # This method is deliberately idempotent and fail-safe because it is called
      # from core user lifecycle callbacks. A cleanup failure must never prevent
      # Discourse from anonymizing or deleting an account; errors are recorded via
      # the privacy-safe logger, and deletion receives an additional post-commit
      # cleanup pass.
      def purge_user!(user_or_id, reason: "unknown")
        user_id = user_id_for(user_or_id)
        return empty_result(success: false) if user_id.blank?
        return empty_result(success: true) unless provider_accounts_table_ready?

        account_ids = provider_account_ids(user_id)

        # Fail closed before touching credentials. If a later database operation
        # fails, these accounts no longer remain active or publicly visible.
        disable_owned_accounts(user_id)
        stop_accounts(account_ids)

        removed_accounts = delete_owned_accounts(user_id)
        updated_audiences = remove_audience_references(user_id)

        # A second direct delete covers partial Redis failures in the coordinator
        # and remains harmless when the keys were already removed.
        ::LiveMetrics::CurrentStateStore.delete_many(account_ids)

        success = !removed_accounts.nil? && !updated_audiences.nil?
        result = {
          success: success,
          removed_accounts: removed_accounts.to_i,
          updated_audiences: updated_audiences.to_i,
          account_ids: account_ids,
        }

        if account_ids.present? || removed_accounts.to_i.positive? || updated_audiences.to_i.positive?
          ::LiveMetrics::SafeLog.info(
            "user_lifecycle_data_purged",
            user_id: user_id,
            reason: reason,
            accounts: removed_accounts.to_i,
            audience_rows: updated_audiences.to_i,
          )
        end

        result
      rescue => e
        ::LiveMetrics::SafeLog.error(
          "user_lifecycle_cleanup_failed",
          error: e,
          user_id: user_id,
          reason: reason,
        )
        empty_result(success: false, account_ids: account_ids)
      end

      private

      def provider_account_ids(user_id)
        ::LiveMetrics::ProviderAccount.where(user_id: user_id).pluck(:id).map(&:to_i)
      end

      def disable_owned_accounts(user_id)
        attributes = { updated_at: Time.zone.now }
        SHARING_COLUMNS.each { |column| attributes[column] = false if provider_account_column?(column) }
        ::LiveMetrics::ProviderAccount.where(user_id: user_id).update_all(attributes)
      rescue => e
        ::LiveMetrics::SafeLog.warn(
          "user_lifecycle_disable_failed",
          error: e,
          user_id: user_id,
        )
      end

      def stop_accounts(account_ids)
        Array(account_ids).each do |account_id|
          ::LiveMetrics::RefreshCoordinator.stop(account_id)
        rescue => e
          ::LiveMetrics::SafeLog.warn(
            "user_lifecycle_stop_failed",
            error: e,
            account_id: account_id,
          )
          # Keep lifecycle cleanup idempotent and fail-closed even when the
          # coordinator cannot complete one of its Redis actions. Numeric ids
          # deliberately invalidate both provider registries.
          ::LiveMetrics::HypeRateStreamingRegistry.invalidate_session(account_id) if defined?(::LiveMetrics::HypeRateStreamingRegistry)
          ::LiveMetrics::PulsoidStreamingRegistry.invalidate_session(account_id) if defined?(::LiveMetrics::PulsoidStreamingRegistry)
          ::LiveMetrics::CurrentStateStore.delete(account_id)
        end
      end

      def delete_owned_accounts(user_id)
        ::LiveMetrics::ProviderAccount.where(user_id: user_id).delete_all
      rescue => e
        ::LiveMetrics::SafeLog.error(
          "user_lifecycle_account_delete_failed",
          error: e,
          user_id: user_id,
        )
        nil
      end

      def remove_audience_references(user_id)
        return 0 unless audience_columns_ready?

        relation =
          ::LiveMetrics::ProviderAccount.where(
            "specific_user_ids @> ARRAY[?]::integer[] OR blocked_user_ids @> ARRAY[?]::integer[]",
            user_id,
            user_id,
          )

        quoted_id = ::LiveMetrics::ProviderAccount.connection.quote(user_id)
        relation.update_all(
          specific_user_ids: Arel.sql("array_remove(specific_user_ids, #{quoted_id})"),
          blocked_user_ids: Arel.sql("array_remove(blocked_user_ids, #{quoted_id})"),
          updated_at: Time.zone.now,
        )
      rescue => e
        ::LiveMetrics::SafeLog.error(
          "user_lifecycle_audience_cleanup_failed",
          error: e,
          user_id: user_id,
        )
        nil
      end

      def provider_accounts_table_ready?
        ::LiveMetrics::ProviderAccount.table_exists? &&
          %w[user_id provider].all? do |column|
            ::LiveMetrics::ProviderAccount.column_names.include?(column)
          end
      rescue
        false
      end

      def audience_columns_ready?
        %w[specific_user_ids blocked_user_ids].all? do |column|
          ::LiveMetrics::ProviderAccount.column_names.include?(column)
        end
      end

      def provider_account_column?(column)
        ::LiveMetrics::ProviderAccount.column_names.include?(column.to_s)
      end

      def user_id_for(user_or_id)
        value = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
        id = value.to_i
        id.positive? ? id : nil
      end

      def empty_result(success:, account_ids: nil)
        {
          success: success,
          removed_accounts: 0,
          updated_audiences: 0,
          account_ids: Array(account_ids).compact,
        }
      end
    end
  end
end
