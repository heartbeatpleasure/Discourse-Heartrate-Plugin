# frozen_string_literal: true

module Jobs
  module LiveMetrics
    class RecoverRefreshLoops < ::Jobs::Scheduled
      every 1.minute
      sidekiq_options queue: "low", retry: false

      def execute(_args = nil)
        return unless ::LiveMetrics::RefreshCoordinator.async_enabled?

        ::LiveMetrics::RefreshCoordinator.sync_all
      end
    end
  end
end
