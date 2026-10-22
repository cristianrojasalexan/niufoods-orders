import { Controller } from "@hotwired/stimulus"

// Hides a notice after a few seconds, or right away with its close button.
export default class extends Controller {
  static values = { after: { type: Number, default: 6000 } }

  connect() {
    this.timer = setTimeout(() => this.close(), this.afterValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  close() {
    this.element.classList.add("opacity-0")
    setTimeout(() => this.element.remove(), 300)
  }
}
