defmodule DokkitWeb.DemoHTML do
  use DokkitWeb, :html

  def line(assigns) do
    ~H"""
    <main class="door">
      <div class="card">
        <h1><Layouts.mark />The demo is full</h1>

        <div id="waiting" class="stack" hidden={@turn}>
          <p class="mute">
            All {@stats.seats} seats are taken. You're in line, and this page takes you in as soon as a seat frees up.
          </p>

          <div class="line" role="status" aria-live="polite">
            <span class="place" id="place">{@place}</span>
            <span>
              <b id="place-text">You're {ordinal(@place)} in line</b>
              <small><span class="pulse" aria-hidden="true"></span>Keep this tab open. Checked <span id="ago">just now</span>.</small>
            </span>
          </div>

          <div>
            <div class="seats" id="seats" aria-hidden="true">
              <i :for={n <- 1..@stats.seats} class={n > @stats.taken && "free"}></i>
            </div>

            <div class="meta">
              <span id="taken">{@stats.taken} of {@stats.seats} seats taken</span>
              <span id="freed">{@stats.freed} freed in the last 5 min</span>
            </div>
          </div>

          <div class="why">
            <p>
              <i class="ph ph-hourglass-medium" aria-hidden="true"></i>Seats open up when someone leaves, or after 6 minutes of not doing anything.
            </p>

            <p>
              <i class="ph ph-arrow-counter-clockwise" aria-hidden="true"></i>The demo starts fresh on the hour. Everything in it is made up.
            </p>
          </div>

          <p class="alt">
            Or look around <a href="https://dokkit.dev/">the sample on dokkit.dev</a> while you wait.
          </p>
        </div>

        <form id="turn" hidden={!@turn} method="post" action={~p"/demo/seat"} class="stack">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <p class="mute">A seat is free and it's held for you for 2 minutes.</p>
          <button class="btn primary" type="submit">Take your seat</button>
        </form>
      </div>
    </main>

    <script>
      (function () {
        var last = Date.now(), ord = function (n) { var s = ["th", "st", "nd", "rd"], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); };
        function show(id, on) { document.getElementById(id).hidden = !on; }
        function check() {
          fetch("/demo/line", {headers: {accept: "application/json"}}).then(function (r) { return r.json(); }).then(function (d) {
            last = Date.now();
            if (d.state === "gone") { location.href = "/demo"; return; }
            if (d.state === "turn") { show("waiting", false); show("turn", true); document.title = "Your seat is ready · Dokkit"; return; }
            document.getElementById("place").textContent = d.place;
            document.getElementById("place-text").textContent = "You're " + ord(d.place) + " in line";
            document.getElementById("taken").textContent = d.taken + " of " + d.seats + " seats taken";
            document.getElementById("freed").textContent = d.freed + " freed in the last 5 min";
            document.querySelectorAll("#seats i").forEach(function (e, i) { e.className = i < d.taken ? "" : "free"; });
          }).catch(function () {});
        }
        setInterval(check, 3000);
        setInterval(function () { var s = Math.round((Date.now() - last) / 1000); document.getElementById("ago").textContent = s < 2 ? "just now" : s + " s ago"; }, 1000);
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
