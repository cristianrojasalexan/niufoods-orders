import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Refreshes the page every few seconds. The server sets the interval: short
// while some dispatch is pending or being sent, longer otherwise, so new
// orders still show up. Pages that cannot change anymore do not render this
// controller. Refreshes are morphs (see the layout): only what changed is
// replaced and the scroll position is kept.
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    this.schedule = this.schedule.bind(this)
    // A morph keeps this element, so connect() does not run again.
    document.addEventListener("turbo:morph", this.schedule)
    this.schedule()
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.schedule)
    clearTimeout(this.timer)
  }

  schedule() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.refresh(), this.intervalValue)
  }

  refresh() {
    // A search still being typed would be overwritten; try again later.
    if (document.querySelector("form[data-pending]")) {
      this.schedule()
    } else if (document.hidden) {
      // A hidden tab waits until it is visible again instead of polling.
      document.addEventListener("visibilitychange", () => this.refresh(), { once: true })
    } else {
      Turbo.visit(window.location.href, { action: "replace" })
    }
  }
}
