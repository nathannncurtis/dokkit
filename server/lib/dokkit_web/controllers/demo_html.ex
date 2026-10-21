defmodule DokkitWeb.DemoHTML do
  use DokkitWeb, :html

  def line(assigns) do
    ~H"""
    <main class="dfull">
      <header class="dfull-top">
        <a class="dfull-brand" href="https://dokkit.dev/" aria-label="Dokkit"><Layouts.mark /></a>
        <div class="dfull-title">
          <h1>The demo is full</h1>
          <p>Keep this tab open. It takes you in the moment a seat is free, even mid-game.</p>
        </div>
        <button class="btn dfull-theme" id="theme" type="button" aria-label="Switch theme">
          <i class="ph ph-moon" aria-hidden="true"></i>
        </button>
      </header>

      <section class="dfull-console" aria-label="Your place in line, and a game while you wait">
        <div class="dfull-ticker" id="waiting" role="status" aria-live="polite">
          <span class="tk place-tk">
            <span class="pulse" aria-hidden="true"></span>
            <span class="place mono" id="place">{@place}</span>
            <b :if={!@turn} id="place-text">You're {ordinal(@place)} in line</b>
            <b :if={@turn} id="place-text">It's your turn</b>
          </span>
          <span class="tk">
            <span class="k">seats</span>
            <span class="mono" id="taken">{@stats.taken}/{@stats.seats}</span>
            <span class="seats" id="seats" aria-hidden="true">
              <i :for={n <- 1..@stats.seats} class={n > @stats.taken && "free"}></i>
            </span>
          </span>
          <span class="tk">
            <span class="mono" id="freed">{@stats.freed}</span> <span class="k">freed in 5 min</span>
          </span>
          <span class="tk"><span class="k">checked</span> <span class="mono" id="ago">just now</span></span>
        </div>
        <div id="game"></div>
      </section>

      <footer class="dfull-notes">
        <p>
          <i class="ph ph-hourglass-medium" aria-hidden="true"></i>Seats open when someone leaves, or after 6 minutes of doing nothing.
        </p>
        <p>
          <i class="ph ph-arrow-counter-clockwise" aria-hidden="true"></i>The demo starts fresh on the hour, with made-up data.
        </p>
        <p>
          <i class="ph ph-compass" aria-hidden="true"></i><span>Rather not wait?
          <a href="https://dokkit.dev/">Look around the sample on dokkit.dev</a></span>
        </p>
      </footer>
    </main>

    <dialog class="dfull-turn" id="turn-box" open={@turn} aria-labelledby="turn-h">
      <form id="turn" method="post" action={~p"/demo/seat"}>
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <span class="ic" aria-hidden="true"><i class="ph ph-armchair"></i></span>
        <h2 id="turn-h">A seat is free</h2>
        <p>It's held for you for <b class="mono" id="hold">2:00</b>. The game is paused.</p>
        <p class="kept" id="kept"></p>
        <button class="btn primary big" id="take" type="submit">
          Take your seat <i class="ph ph-arrow-right" aria-hidden="true"></i>
        </button>
      </form>
    </dialog>

    <script src={~p"/js/keep-green.js"}>
    </script>
    <script>
      (function () {
        var $ = function (id) { return document.getElementById(id); };
        var game = window.KeepGreen && KeepGreen.mount($("game")), turn = false, last = Date.now();
        var ord = function (n) { var s = ["th", "st", "nd", "rd"], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); };
        function paintTheme() {
          var dark = document.documentElement.classList.contains("t-dark");
          $("theme").innerHTML = '<i class="ph ph-' + (dark ? "sun" : "moon") + '" aria-hidden="true"></i>';
          $("theme").setAttribute("aria-label", "Switch to " + (dark ? "light" : "dark") + " theme");
        }
        $("theme").onclick = function () {
          dokkitLook("theme", document.documentElement.classList.contains("t-dark") ? "light" : "dark");
          paintTheme();
        };
        paintTheme();
        function yourTurn() {
          if (turn) return;
          turn = true;
          var kept = "";
          if (game) {
            game.lock();
            var s = game.state();
            if (s.started) kept = "You kept " + s.score + " min of uptime. Best: " + s.best + " min.";
          }
          $("place").innerHTML = '<i class="ph ph-check-circle" aria-hidden="true"></i>';
          $("place-text").textContent = "It's your turn";
          $("kept").textContent = kept;
          document.title = "Your seat is ready · Dokkit";
          var d = $("turn-box");
          d.addEventListener("cancel", function (e) { e.preventDefault(); });
          if (d.open) d.close();
          d.showModal();
          $("take").focus();
          var left = 120, t = setInterval(function () {
            left--;
            $("hold").textContent = Math.floor(left / 60) + ":" + String(left % 60).padStart(2, "0");
            if (left <= 0) clearInterval(t);
          }, 1000);
        }
        $("turn").addEventListener("submit", function () { $("take").disabled = true; $("take").firstChild.textContent = "Taking you in… "; });
        function check() {
          fetch("/demo/line", {headers: {accept: "application/json"}}).then(function (r) { return r.json(); }).then(function (d) {
            last = Date.now();
            if (d.state === "gone") { location.href = "/demo"; return; }
            if (d.state === "turn") return yourTurn();
            $("place").textContent = d.place;
            $("place-text").textContent = "You're " + ord(d.place) + " in line";
            $("taken").textContent = d.taken + "/" + d.seats;
            $("freed").textContent = d.freed;
            document.querySelectorAll("#seats i").forEach(function (e, i) { e.className = i < d.taken ? "" : "free"; });
          }).catch(function () {});
        }
        if ($("turn-box").open) yourTurn();
        setInterval(check, 3000);
        setInterval(function () { var s = Math.round((Date.now() - last) / 1000); $("ago").textContent = s < 2 ? "just now" : s + " s ago"; }, 1000);
      })();
    </script>
    """
  end

  def away(assigns) do
    ~H"""
    <main class="door">
      <div class="card">
        <h1>
          <Layouts.mark />{if @why == "left",
            do: "You left the demo",
            else: "Your seat went to someone else"}
        </h1>

        <p class="mute">{reason(@why)}</p>
        <a class="btn primary" href={~p"/demo"}>Take a seat again</a>
      </div>
    </main>
    """
  end

  def limit(assigns) do
    ~H"""
    <main class="door">
      <div class="card">
        <h1><Layouts.mark />That's enough seats for now</h1>

        <p class="mute">
          Your address already holds three seats or places in line. Close a demo tab, then try again in a couple of minutes.
        </p>
        <a class="btn primary" href={~p"/demo"}>Try again</a>
      </div>
    </main>
    """
  end

  defp reason("idle"),
    do: "You hadn't done anything in Dokkit for 6 minutes, so your seat went to the next person."

  defp reason("gone"),
    do:
      "Your demo tab was closed or lost its connection for 2 minutes, so your seat went to the next person."

  defp reason("long"),
    do: "You had a seat for 20 minutes and people were waiting, so it went to the next person."

  defp reason("left"), do: "Thanks for looking around. Take a seat again any time."
  defp reason(_), do: "Your seat is no longer held."

  defp ordinal(nil), do: ""

  defp ordinal(n) do
    suffix =
      cond do
        rem(n, 100) in 11..13 -> "th"
        rem(n, 10) == 1 -> "st"
        rem(n, 10) == 2 -> "nd"
        rem(n, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{n}#{suffix}"
  end
end
