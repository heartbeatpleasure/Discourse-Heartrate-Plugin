import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";

export default class LiveMetricsActivityModeration extends Component {
  @tracked username = "";
  @tracked confirming = false;
  @tracked busy = false;
  @tracked result = null;
  @tracked error = null;

  @action
  changeUsername(event) {
    this.username = event.target.value;
    this.confirming = false;
    this.result = null;
    this.error = null;
  }

  @action
  askToClear(event) {
    event.preventDefault();
    if (this.username.trim()) {
      this.confirming = true;
    }
  }

  @action
  cancel() {
    this.confirming = false;
  }

  @action
  async clearActivity() {
    if (this.busy || !this.confirming) { return; }
    this.busy = true;
    this.error = null;
    this.result = null;
    try {
      const username = encodeURIComponent(this.username.trim());
      const response = await ajax(`/admin/plugins/live-metrics/activities/${username}`, {
        type: "DELETE",
      });
      this.result = response.cleared ? "Activity cleared." : "No saved activity for this member.";
      this.confirming = false;
    } catch (error) {
      this.error = error?.jqXHR?.status === 404
        ? "Member not found."
        : "Could not clear this activity.";
      this.confirming = false;
    } finally {
      this.busy = false;
    }
  }

  <template>
    <section class="lm-landing__hero" aria-label="Activity moderation">
      <div class="lm-landing__hero-copy">
        <h2>Activity moderation</h2>
        <p>Clear a member's current activity without changing their heartrate connection or privacy settings.</p>
        <form {{on "submit" this.askToClear}}>
          <label for="lm-activity-username">Username</label>
          <input id="lm-activity-username" type="text" value={{this.username}} {{on "input" this.changeUsername}} />
          <button class="btn btn-default" type="submit" disabled={{this.busy}}>Clear member activity…</button>
        </form>
        {{#if this.confirming}}
          <div role="group" aria-label="Confirm activity removal">
            <p>Clear the activity for {{this.username}}?</p>
            <button type="button" class="btn btn-danger" disabled={{this.busy}} {{on "click" this.clearActivity}}>Confirm removal</button>
            <button type="button" class="btn btn-default" disabled={{this.busy}} {{on "click" this.cancel}}>Cancel</button>
          </div>
        {{/if}}
        {{#if this.result}}<p role="status">{{this.result}}</p>{{/if}}
        {{#if this.error}}<p role="alert">{{this.error}}</p>{{/if}}
      </div>
    </section>
  </template>
}
