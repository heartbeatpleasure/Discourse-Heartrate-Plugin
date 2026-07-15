# frozen_string_literal: true

class ProblemCheck::LiveMetricsOperationalHealth < ProblemCheck
  self.priority = "high"
  self.perform_every = 10.minutes
  self.max_retries = 0
  self.max_blips = 1

  def run(&block)
    super(&block)
  ensure
    rearm_after_recovery
  end

  def call
    issues = ::LiveMetrics::OperationalAlerts.issues
    return no_problem if issues.blank?

    issues_html = build_issues_html(issues)
    problem(
      override_data: { issues: issues_html },
      details: {
        issues: issues_html,
        issue_codes: issues.map { |issue| issue[:code].to_s }.join(","),
      },
    )
  end

  private

  def rearm_after_recovery
    tracker.watch! if tracker.passing? && tracker.ignored?
  rescue => e
    ::LiveMetrics::SafeLog.warn("operational_alert_rearm_failed", error: e)
  end

  def build_issues_html(issues)
    items =
      issues.map do |issue|
        text = I18n.t(
          "live_metrics.admin_alerts.#{issue[:code]}",
          **issue.fetch(:values, {}).symbolize_keys,
        )
        "<li>#{ERB::Util.html_escape(text)}</li>"
      end

    "<ul>#{items.join}</ul>"
  end
end
