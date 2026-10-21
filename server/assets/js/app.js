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

let downHits = []
const downHit = (cell) => {
  const now = Date.now()
  downHits = downHits.filter((t) => now - t < 4000).concat(now)
  const box = document.getElementById("day-game")
  if (downHits.length < 5 || !box || box.firstChild) return
  downHits = []
  const open = () => {
    const found = document.createElement("p")
    found.className = "kg-found"
    found.innerHTML = '<span>You found it.</span><button class="btn" type="button"><i class="ph ph-arrow-left" aria-hidden="true"></i>Back to the last day</button>'
    const root = document.createElement("div")
    box.replaceChildren(found, root)
    const game = window.KeepGreen.mount(root)
    root.querySelector("[data-k=start]").focus()
    found.querySelector("button").onclick = () => {
      game.stop()
      box.replaceChildren()
      if (cell.isConnected) cell.focus()
    }
  }
  if (window.KeepGreen) return open()
  const s = document.createElement("script")
  s.src = "/js/keep-green.js"
  s.onload = open
  document.head.appendChild(s)
}
document.addEventListener("click", (e) => {
  const cell = e.target.closest("#day .lane .bad")
  if (cell) downHit(cell)
})
document.addEventListener("keydown", (e) => {
  if ((e.key === "Enter" || e.key === " ") && e.target.matches("#day .lane .bad")) {
    e.preventDefault()
    downHit(e.target)
  }
})

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
