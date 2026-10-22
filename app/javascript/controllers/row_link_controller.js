import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Makes a whole table row open its order. The order number stays a real
// link, for keyboards, screen readers and opening it in a new tab.
export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (event.target.closest("a, button") || window.getSelection().toString()) return

    Turbo.visit(this.urlValue)
  }
}
