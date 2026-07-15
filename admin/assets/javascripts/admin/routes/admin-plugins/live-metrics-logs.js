import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

export default class AdminPluginsLiveMetricsLogsRoute extends DiscourseRoute {
  titleToken() {
    return i18n("admin.live_metrics.logs.title");
  }

  setupController(controller) {
    super.setupController(...arguments);
    if (typeof controller?.resetState === "function") {
      controller.resetState();
      if (typeof controller?.loadLogs === "function") {
        controller.loadLogs();
      }
    }
  }
}
