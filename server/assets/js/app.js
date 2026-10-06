import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
new LiveSocket("/live", Socket, {longPollFallbackMs: 2500, params: {_csrf_token: csrfToken}}).connect()
