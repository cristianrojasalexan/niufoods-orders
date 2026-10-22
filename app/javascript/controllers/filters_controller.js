import { Controller } from "@hotwired/stimulus"

// Applies the filters as soon as they change: right away for the selects,
// and once the person stops typing for the search.
//
// The live refresh must never overwrite filters being used. From the first
// keystroke until the results load, or fail to, the form is marked as
// pending and the refresh waits; and a refresh that already started leaves
// the form as it is while it is pending or the search field has the focus.
export default class extends Controller {
  connect() {
    // Pending is transient: a page restored from the Turbo cache brings new
    // elements, so this runs again and drops a mark no search stands behind.
    // Not on turbo:before-cache, which also fires during a live refresh,
    // while the search may still be on its way.
    this.clearPending()
    this.loaded = this.loaded.bind(this)
    this.keep = this.keep.bind(this)
    // The frame either loads the results or reports why it could not; a
    // failed request is reported on this form too.
    this.frameEvents = [ "turbo:frame-load", "turbo:frame-missing", "turbo:fetch-request-error", "turbo:submit-end" ]
    this.frameEvents.forEach((name) => document.addEventListener(name, this.loaded))
    document.addEventListener("turbo:before-morph-element", this.keep)
  }

  disconnect() {
    this.frameEvents.forEach((name) => document.removeEventListener(name, this.loaded))
    document.removeEventListener("turbo:before-morph-element", this.keep)
    clearTimeout(this.timer)
    this.timer = null
    this.clearPending()
  }

  submit() {
    clearTimeout(this.timer)
    this.timer = null
    this.markPending()
    // Empty fields are left out of the URL, so it only shows the filters in use.
    const empty = [ ...this.element.elements ].filter((field) => field.name && !field.disabled && field.value === "")
    empty.forEach((field) => (field.disabled = true))
    this.element.requestSubmit()
    empty.forEach((field) => (field.disabled = false))
  }

  search() {
    clearTimeout(this.timer)
    this.markPending()
    this.timer = setTimeout(() => this.submit(), 400)
  }

  // A refresh morphs the whole page except this form while a search is on
  // its way or being typed. A select keeps the focus after a change, but its
  // value is already in the URL, so it does not block the refresh.
  keep(event) {
    if (event.target !== this.element) return

    const typing = document.activeElement?.type === "search" && this.element.contains(document.activeElement)
    if (this.element.dataset.pending || typing) event.preventDefault()
  }

  markPending() {
    this.element.dataset.pending = "true"
    // Never left pending if the results do not arrive.
    clearTimeout(this.safety)
    this.safety = setTimeout(() => this.clearPending(), 5000)
  }

  // Unless the person kept typing and another search is waiting to be sent.
  loaded(event) {
    const ours = event.target === this.element || event.target.closest?.(`turbo-frame#${this.element.dataset.turboFrame}`)
    // A successful submission still has to render its results.
    const succeeded = event.type === "turbo:submit-end" && event.detail.success
    if (ours && !succeeded && !this.timer) this.clearPending()
  }

  clearPending() {
    clearTimeout(this.safety)
    delete this.element.dataset.pending
  }
}
