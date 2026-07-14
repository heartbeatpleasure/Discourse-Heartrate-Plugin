export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("liveMetrics", { path: "/live-metrics" });
  },
};
