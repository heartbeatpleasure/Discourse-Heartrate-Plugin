export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("liveMetricsLogs", { path: "/live-metrics-logs" });
  },
};
