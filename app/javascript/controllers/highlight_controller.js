import { Controller } from "@hotwired/stimulus"

// Lights up an order row for a moment when a live refresh adds it or
// changes its dispatch state, so the eye finds what moved. The state comes
// from the server; a morph updates the attribute and Stimulus calls
// stateValueChanged.
let morphing = false
document.addEventListener("turbo:before-render", (event) => { morphing = event.detail.renderMethod === "morph" })
document.addEventListener("turbo:morph", () => { morphing = false })

export default class extends Controller {
  static values = { state: String }

  connect() {
    // A row that appears during a morph is new; on a normal load, none is.
    if (morphing) this.flash()
    this.ready = true
  }

  stateValueChanged(state, previous) {
    if (this.ready && previous && state !== previous) this.flash()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  flash() {
    this.element.classList.add("bg-amber-100")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.classList.remove("bg-amber-100"), 1500)
  }
}
