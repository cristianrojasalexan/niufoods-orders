import { Controller } from "@hotwired/stimulus"

// Applies the filters as soon as they change: right away for the selects,
// and once the person stops typing for the search.
export default class extends Controller {
  submit() {
    // Empty fields are left out of the URL, so it only shows the filters in use.
    const empty = [ ...this.element.elements ].filter((field) => field.name && !field.disabled && field.value === "")
    empty.forEach((field) => (field.disabled = true))
    this.element.requestSubmit()
    empty.forEach((field) => (field.disabled = false))
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submit(), 400)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
