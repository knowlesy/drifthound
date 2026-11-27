import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "button"]

  toggle(event) {
    if (!this.hasContentTarget) return
    if (event?.target.closest("[data-expandable-ignore]")) return

    const isHidden = this.contentTarget.hidden
    this.contentTarget.hidden = !isHidden
    this.element.classList.toggle("expanded", isHidden)
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", String(isHidden))
      const label = this.buttonTarget.getAttribute("aria-label")
      if (label) this.buttonTarget.setAttribute("aria-label", label.replace(/^(Show|Hide)\b/, isHidden ? "Hide" : "Show"))
    }
  }
}
