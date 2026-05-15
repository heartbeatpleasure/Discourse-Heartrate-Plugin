// assets/javascripts/discourse/live-metrics-route-map.js
//
// Registers the /live-metrics Ember route in the main Discourse app.
// The separate theme component supplies the route class and template.
export default function liveMetrics() {
  this.route("live-metrics", { path: "/live-metrics" });
}
