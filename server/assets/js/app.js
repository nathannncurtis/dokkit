import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
new LiveSocket("/live", Socket, {longPollFallbackMs: 2500, params: {_csrf_token: csrfToken}, hooks: {Look: {mounted() { dokkitLook() }}}}).connect()

document.addEventListener("click", (e) => {
  const button = e.target.closest("[data-copy]")
  const source = button && document.querySelector(button.dataset.copy)
  if (!source) return
  navigator.clipboard.writeText(source.textContent.trim()).then(() => {
    button.textContent = "Copied"
    setTimeout(() => (button.textContent = "Copy"), 2000)
  })
})
