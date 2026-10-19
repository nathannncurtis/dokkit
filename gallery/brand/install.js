let server = "linux", db = "own", machine = "windows";

function address() {
  return server === "linux" ? "https://" + ($("#domain").value.trim() || "dokkit.example.com") : "https://<your server>";
}
function render() {
  const d = $("#domain").value.trim() || "dokkit.example.com", url = $("#dburl").value.trim();
  $("#cmdLinux").textContent = `curl -fsSL https://dokkit.dev/install.sh | sudo sh -s -- ${d}`;
  $("#cmdWindows").textContent = db === "own"
    ? "irm https://dokkit.dev/install.ps1 | iex"
    : `& ([scriptblock]::Create((irm https://dokkit.dev/install.ps1))) -DatabaseUrl '${url}'`;
  $("#cmdAdd").textContent = `irm ${address()}/add/<token from Add a machine> | iex`;
  $("#cmdEnrol").textContent = `dokkit enrol ${address()} <token>`;
  $$("[data-echo=domain]").forEach((e) => (e.textContent = d));
  $$("[data-echo=address]").forEach((e) => (e.textContent = server === "linux" ? address() : "http://localhost:4000, on the server itself,"));
  $("#didOwn").hidden = db !== "own";
}
function pick(attr, value) {
  $$(`[data-${attr}]`).forEach((b) => b.setAttribute("aria-checked", b.dataset[attr] === value));
}
document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-server],[data-db],[data-machine]");
  if (!b) return;
  if (b.dataset.server) {
    server = b.dataset.server;
    pick("server", server);
    $$("[data-for]").forEach((el) => (el.hidden = el.dataset.for !== server));
  }
  if (b.dataset.db) { db = b.dataset.db; pick("db", db); $("#dbWrap").hidden = db !== "yours"; }
  if (b.dataset.machine) {
    machine = b.dataset.machine;
    pick("machine", machine);
    $("[data-machine-for=windows]").hidden = machine !== "windows";
    $("[data-machine-for=unix]").hidden = machine === "windows";
  }
  render();
  window.ScrollTrigger?.refresh();
});
$("#domain").addEventListener("input", render);
$("#dburl").addEventListener("input", render);

// The rail marks the step you are reading and fills as you go.
const steps = $$(".step"), links = $$(".rail a");
function where() {
  const mid = innerHeight * 0.4;
  let current = steps[0];
  steps.forEach((s) => { if (s.getBoundingClientRect().top < mid) current = s; });
  links.forEach((a) => a.toggleAttribute("aria-current", a.dataset.step === current.id));
  const first = steps[0].getBoundingClientRect().top, last = steps[steps.length - 1].getBoundingClientRect().bottom;
  const p = Math.min(1, Math.max(0, (mid - first) / (last - first)));
  $("#railFill").style.transform = `scaleY(${p})`;
}
addEventListener("scroll", where, { passive: true });
render();
where();
