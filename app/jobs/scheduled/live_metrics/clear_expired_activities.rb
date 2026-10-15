# frozen_string_literal: true

module ::Jobs
  module LiveMetrics
    class ClearExpiredActivities < ::Jobs::Scheduled
      every 1.hour

      def execute(_args)
        return unless ::LiveMetrics::Activity.table_exists?

        ::LiveMetrics::Activity.where("expires_at <= ?", Time.zone.now).delete_all
      end
    end
  end
end
