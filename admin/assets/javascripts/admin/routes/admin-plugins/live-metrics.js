import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

export default class AdminPluginsLiveMetricsRoute extends DiscourseRoute {
  titleToken() {
    return i18n("admin.live_metrics.title");
  }
}
