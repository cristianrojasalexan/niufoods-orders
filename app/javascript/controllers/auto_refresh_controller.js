import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Refreshes the page every few seconds while it shows dispatches in
// progress. The server only renders this controller while some dispatch is
// pending or being sent, so the refreshes stop by themselves once all of
// them end. Refreshes are morphs (see the layout): only what changed is
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
    // A hidden tab waits until it is visible again instead of polling.
    if (document.hidden) {
      document.addEventListener("visibilitychange", () => this.refresh(), { once: true })
    } else {
      Turbo.visit(window.location.href, { action: "replace" })
    }
  }
}
