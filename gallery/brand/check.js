const EX = {
  web: `schema = 1

[service]
id = "upload-portal"
name = "Upload portal"
kind = "service"

[[check]]
type = "http"
url = "http://localhost:8080/healthz"
every = "30s"
slow = "2s"

[[check]]
type = "tcp"
port = 5432

[logs]
path = "logs/*.jsonl"
`,
  worker: `schema = 1

[service]
id = "report-builder"
kind = "job"

[[check]]
type = "beat"
name = "worker"

[[job]]
id = "nightly-purge"
schedule = "0 1 * * *"
grace = "30m"

[[job]]
id = "weekly-report"
schedule = "0 6 * * 1"
max_runtime = "2h"
`,
  win: `schema = 1

[service]
id = "image-resizer"

[[check]]
type = "windows-service"
name = "ImageResizer"

[[check]]
type = "process"
name = "python.exe"
command_has = '\\apps\\resizer\\'
at_least = 4
`,
  bad: `schema = 1

[service]
id = "Upload Portal"

[[check]]
type = "http"
url = "http://localhost:8080/healthz"
`,
};
const src = $("#src"), hl = $("#hl"), gut = $("#gut");
const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

function paint(line) {
  if (/^\s*#/.test(line)) return `<i class="t-c">${esc(line)}</i>`;
  if (/^\s*\[/.test(line)) return `<i class="t-s">${esc(line)}</i>`;
  const m = line.match(/^(\s*)([\w.-]+)(\s*=\s*)(.*)$/);
  if (!m) return esc(line);
  const val = m[4].replace(/("(?:[^"\\]|\\.)*"|'[^']*')|(#.*$)|(\b\d+(?:\.\d+)?\b|\btrue\b|\bfalse\b)/g, (all, str, cmt, num) =>
    `\u0000${str ? "t-v" : cmt ? "t-c" : "t-n"}\u0001${all}\u0002`);
  return `${m[1]}<i class="t-k">${esc(m[2])}</i>${esc(m[3])}${esc(val).replace(/\u0000([\w-]+)\u0001/g, '<i class="$1">').replace(/\u0002/g, "</i>")}`;
}

let ready = false, bad = 0;
function run() {
  const lines = src.value.split("\n");
  hl.innerHTML = lines.map(paint).join("\n") + "\n";
  const r = ready ? JSON.parse(window.dokkitCheck(src.value)) : null;
  bad = r && !r.ok ? +((r.error.match(/line (\d+)/) || [])[1] || 0) : 0;
  gut.innerHTML = lines.map((_, i) => `<span${i + 1 === bad ? ' class="err"' : ""}>${i + 1}</span>`).join("\n");
  if (!r) return;
  const v = $("#verdict");
  if (!r.ok) {
    v.innerHTML = `<i class="s bad"></i><span><b>Refused.</b> ${esc(r.error.replace(/^toml: /, ""))}</span>`;
    $("#plan").innerHTML = "";
    $("#sendsCard").hidden = true;
    return;
  }
  const n = r.checks.length;
  v.innerHTML = `<i class="s ok"></i><span><b>Accepted.</b> <code>${esc(r.service)}</code>, ${n} check${n === 1 ? "" : "s"}${r.jobs.length ? `, ${r.jobs.length} job${r.jobs.length === 1 ? "" : "s"}` : ""}.</span>`;
  const rows = r.checks.map((c) => `<div class="pl"><code>${esc(c.name)}</code><span>${esc(c.target || c.type)}</span><small>${c.runs ? `the program checks it every ${c.every.replace(/m0s$/, "m").replace(/h0m$/, "h")}` : "your app reports it"}</small></div>`)
    .concat(r.jobs.map((j) => `<div class="pl"><code>${esc(j)}</code><span>a job</span><small>expected on its schedule</small></div>`))
    .concat(r.logs ? [`<div class="pl"><code>logs</code><span>${esc(r.logs)}</span><small>read and kept a year</small></div>`] : []);
  $("#plan").innerHTML = rows.length ? `<div class="plan">${rows.join("")}</div>` : "";
  $("#sendsCard").hidden = false;
  $("#sends").textContent = JSON.stringify(r.sends, null, 2);
}

function show(name) {
  $$("[data-ex]").forEach((b) => b.classList.toggle("on", b.dataset.ex === name));
  src.value = EX[name];
  run();
}
let typed = false;
src.addEventListener("input", () => { typed = true; run(); });
src.addEventListener("scroll", () => { hl.scrollTop = gut.scrollTop = src.scrollTop; hl.scrollLeft = src.scrollLeft; });
src.addEventListener("keydown", (e) => {
  if (e.key !== "Tab" || e.shiftKey) return;
  e.preventDefault();
  document.execCommand("insertText", false, "  ");
});
const pos = () => { const before = src.value.slice(0, src.selectionStart).split("\n"); $("#edPos").textContent = `line ${before.length}, column ${before.at(-1).length + 1}`; };
["keyup", "click", "input"].forEach((ev) => src.addEventListener(ev, pos));
document.addEventListener("click", (e) => { const b = e.target.closest("[data-ex]"); if (b) { typed = true; show(b.dataset.ex); } });

src.value = EX.web;
run();
const go = new Go();
WebAssembly.instantiateStreaming(fetch("check.wasm"), go.importObject).then(({ instance }) => {
  go.run(instance);
  ready = true;
  run();
}, () => { $("#verdict").innerHTML = '<i class="s bad"></i><span>The checker could not load in this browser. <code>dokkit check</code> on your machine does the same.</span>'; });

// The sample file types itself in, checked as it goes, while the page waits.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  const text = EX.web, p = { v: 0 };
  const tl = gsap.timeline({ paused: true });
  tl.call(() => { if (!typed) { src.value = ""; run(); } })
    .to(p, { v: 1, duration: 2.6, ease: "none", onUpdate: () => { if (!typed) { src.value = text.slice(0, Math.round(p.v * text.length)); run(); } } })
    .to({}, { duration: 0.5 });
  holdFor("#play", tl, "top 12%");
}
