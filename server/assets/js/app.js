import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const hooks = {
  Look: {mounted() { dokkitLook() }},
  Partial: {
    mounted() { this.sync() },
    updated() { this.sync() },
    sync() { this.el.indeterminate = this.el.dataset.some === "true" }
  },
  MachineKeys: {
    mounted() {
      this.reveal()
      this.el.addEventListener("keydown", (e) => {
        const items = [...this.el.querySelectorAll("[role=option]")]
        let i = items.findIndex((x) => x.getAttribute("aria-current") === "true")
        if (e.key === "ArrowDown") i = Math.min(items.length - 1, i + 1)
        else if (e.key === "ArrowUp") i = Math.max(0, i - 1)
        else if (e.key === "Home") i = 0
        else if (e.key === "End") i = items.length - 1
        else return
        e.preventDefault()
        items[i].click()
        items[i].focus()
      })
    },
    updated() { this.reveal() },
    reveal() {
      const chosen = this.el.querySelector("[aria-current=true]")
      if (chosen && chosen.id !== this.shown) chosen.scrollIntoView({block: "nearest"})
      this.shown = chosen && chosen.id
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
new LiveSocket("/live", Socket, {longPollFallbackMs: 2500, params: {_csrf_token: csrfToken}, hooks}).connect()

document.addEventListener("click", (e) => {
  const button = e.target.closest("[data-copy]")
  const source = button && document.querySelector(button.dataset.copy)
  if (!source) return
  const label = button.textContent
  navigator.clipboard.writeText(source.textContent.trim()).then(() => {
    button.textContent = "Copied"
    setTimeout(() => (button.textContent = label), 2000)
  })
})

window.addEventListener("phx:download", ({detail}) => {
  const a = document.createElement("a")
  a.href = URL.createObjectURL(new Blob([detail.text], {type: "text/plain"}))
  a.download = detail.file
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
})
