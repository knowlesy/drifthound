import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "drifthound-theme"

export default class extends Controller {
  connect() {
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.handleSystemChange = this.handleSystemChange.bind(this)
    this.media.addEventListener("change", this.handleSystemChange)

    if (!document.documentElement.dataset.theme) {
      const stored = this.stored
      document.documentElement.dataset.theme =
        stored === "light" || stored === "dark" ? stored : (this.media.matches ? "dark" : "light")
    }

    this.render()
  }

  disconnect() {
    this.media.removeEventListener("change", this.handleSystemChange)
  }

  toggle() {
    const theme = this.current === "dark" ? "light" : "dark"
    this.store(theme)
    this.apply(theme)
  }

  handleSystemChange(event) {
    if (this.stored) return
    this.apply(event.matches ? "dark" : "light")
  }

  apply(theme) {
    document.documentElement.dataset.theme = theme
    this.render()
    this.dispatch("change", { target: document, detail: { theme } })
  }

  render() {
    const dark = this.current === "dark"
    this.element.setAttribute("aria-pressed", String(dark))
    this.element.title = dark ? "Switch to light mode" : "Switch to dark mode"
  }

  get current() {
    return document.documentElement.dataset.theme === "dark" ? "dark" : "light"
  }

  get stored() {
    try {
      return localStorage.getItem(STORAGE_KEY)
    } catch {
      return null
    }
  }

  store(theme) {
    try {
      localStorage.setItem(STORAGE_KEY, theme)
    } catch {}
  }
}
