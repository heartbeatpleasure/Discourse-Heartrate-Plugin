export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("liveMetricsHealth", { path: "/live-metrics-health" });
  },
};
