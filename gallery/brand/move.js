const SAMPLES = {
  hc: JSON.stringify({ checks: [
    { name: "Nightly backup", slug: "nightly-backup", tags: "db", desc: "", grace: 1800, n_pings: 412, status: "up", started: false, last_ping: "2026-10-18T02:03:11+00:00", next_ping: "2026-10-19T02:00:00+00:00", manual_resume: false, methods: "", ping_url: "https://hc-ping.com/5b8f4a8e-0c1e-4b5f-9e6d-2a7c3f1d9b04", schedule: "0 2 * * *", tz: "UTC" },
    { name: "Invoice export", slug: "invoice-export", tags: "billing", desc: "", grace: 3600, n_pings: 210, status: "up", started: false, manual_resume: false, methods: "", ping_url: "https://hc-ping.com/0d7e2c41-93b8-4a6f-b1c2-7f5e8a9d3c60", schedule: "30 6 * * 1-5", tz: "Europe/Lisbon" },
    { name: "Queue drain", slug: "queue-drain", tags: "", desc: "", grace: 120, n_pings: 9031, status: "up", started: false, manual_resume: false, methods: "", ping_url: "https://hc-ping.com/a19c6f30-58d2-4e7b-8c41-0b3e9d7f2a15", timeout: 300 },
    { name: "Photo resync", slug: "photo-resync", tags: "", desc: "", grace: 600, n_pings: 77, status: "up", started: false, manual_resume: false, methods: "", ping_url: "https://hc-ping.com/c3f08b2d-7e14-4a9c-a6d5-91b2e0f4c8a7", timeout: 5400 },
    { name: "Disk report", slug: "disk-report", tags: "", desc: "", grace: 3600, n_pings: 40, status: "up", started: false, manual_resume: false, methods: "", ping_url: "https://hc-ping.com/e8b51a07-2c6f-4d93-b0e4-6a1f7c3d5b92", schedule: "Mon *-*-* 03:00:00", tz: "UTC" },
  ] }, null, 2),
  kuma: JSON.stringify({ version: "1.23.16", notificationList: [], monitorList: [
    { id: 1, name: "Shop front", type: "http", url: "https://shop.example.com/", method: "GET", interval: 60, timeout: 48, maxretries: 2, accepted_statuscodes: ["200-299"], ignoreTls: false, upsideDown: false, active: true, tags: [] },
    { id: 2, name: "Mail relay", type: "port", hostname: "mail.example.internal", port: 25, interval: 120, timeout: 96, maxretries: 0, active: true, tags: [] },
    { id: 3, name: "Status page text", type: "keyword", url: "https://status.example.com/", keyword: "All systems go", interval: 300, maxretries: 1, active: true, tags: [] },
    { id: 4, name: "Office router", type: "ping", hostname: "10.0.0.1", interval: 60, maxretries: 0, active: true, tags: [] },
    { id: 5, name: "Photo sync", type: "push", pushToken: "Xk29fLq0Ze", interval: 3600, maxretries: 0, active: true, tags: [] },
  ] }, null, 2),
  urls: `https://hc-ping.com/fJ3kq9Xc2LmZ0aPqR7sT1w/nightly-backup
https://hc-ping.com/5b8f4a8e-0c1e-4b5f-9e6d-2a7c3f1d9b04
https://status.example.net/api/push/Xk29fLq0Ze?status=up&msg=OK&ping=
https://ping.example.org/report-builder/done
`,
};

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const str = (s) => JSON.stringify(String(s));
// Single-unit times: the server reads grace as one number and one unit, the program reads every as a Go duration; both read these.
const dur = (s) => { s = Math.max(1, Math.round(s)); return s % 3600 === 0 ? s / 3600 + "h" : s % 60 === 0 ? s / 60 + "m" : s + "s"; };
const slug = (t) => String(t || "").toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^[^a-z0-9]+|-+$/g, "").slice(0, 100);
const UTC = ["UTC", "Etc/UTC", "Etc/GMT", "GMT", "Z"];

function namer() {
  const used = new Set();
  return (want, fallback) => {
    let base = slug(want) || fallback, id = base, n = 2;
    while (used.has(id)) id = `${base}-${n++}`;
    used.add(id);
    return id;
  };
}

// A period since the last ping, as the nearest schedule: one slot each period, late only once the whole period passes.
function period(sec) {
  const m = sec / 60, h = sec / 3600;
  let cron = null;
  if (Number.isInteger(m) && m >= 1 && m < 60 && 60 % m === 0) cron = m === 1 ? "* * * * *" : `*/${m} * * * *`;
  else if (Number.isInteger(h) && h >= 1 && h < 24 && 24 % h === 0) cron = h === 1 ? "0 * * * *" : `0 */${h} * * *`;
  else if (sec === 86400) cron = "0 0 * * *";
  else if (sec === 604800) cron = "0 0 * * 0";
  return cron && { cron, grace: dur(sec - Math.min(60, sec / 2)) };
}

function jobFile(id, name, job, comments) {
  const lines = ["schema = 1", "", "[service]", `id = ${str(id)}`];
  if (name) lines.push(`name = ${str(name)}`);
  lines.push('kind = "job"', "", ...comments.map((c) => "# " + c), "[[job]]", `id = ${str(id)}`);
  if (job.schedule) lines.push(`schedule = ${str(job.schedule)}`);
  if (job.grace) lines.push(`grace = ${str(job.grace)}`);
  if (job.max_runtime) lines.push(`max_runtime = ${str(job.max_runtime)}`);
  return lines.join("\n") + "\n";
}

function fromHealthchecks(list) {
  const id = namer(), files = [], skipped = [];
  list.forEach((c, i) => {
    const label = c.name || c.slug || `Check ${i + 1}`;
    const sched = typeof c.schedule === "string" ? c.schedule.trim() : "";
    if (sched && sched.split(/\s+/).length !== 5) {
      skipped.push([label, `Its schedule <code>${esc(sched)}</code> is a systemd OnCalendar line. Dokkit reads five-field cron only; write the cron line by hand.`]);
      return;
    }
    const sid = id(c.slug || c.name, `check-${i + 1}`), notes = [], comments = [];
    const grace = c.grace ? dur(c.grace) : null;
    let job;
    if (sched) {
      job = { schedule: sched, grace, max_runtime: grace };
      notes.push(`A cron check: the same schedule, <code>grace = ${grace || "30m"}</code> from its grace, and <code>max_runtime</code> the same, because Healthchecks also calls a started run down once its grace passes without a success.`);
      if (c.tz && !UTC.includes(c.tz)) {
        comments.push(`Healthchecks read this schedule in ${c.tz}. Dokkit reads it as UTC: change it before applying.`);
        notes.push(`<b class="warn-t">Adjust the schedule.</b> Healthchecks read <code>${esc(sched)}</code> in <code>${esc(c.tz)}</code>. Dokkit reads every schedule as UTC, so it is kept as written and must be shifted by hand (and again when the clocks change).`);
      }
    } else {
      const sec = Number(c.timeout) || 86400, p = period(sec);
      if (p) {
        job = { schedule: p.cron, grace: p.grace, max_runtime: grace };
        notes.push(`A simple check, expected every ${dur(sec)}. Dokkit has no &ldquo;since the last ping&rdquo; job, so it becomes a schedule of one slot every ${dur(sec)} with <code>grace = ${p.grace}</code>: a ping any time in the period counts. It can call the job late up to one period after Healthchecks would have, and Healthchecks' own grace (${grace || "none"}) becomes <code>max_runtime</code>.`);
      } else {
        job = { max_runtime: grace };
        notes.push(`A simple check, expected every ${dur(sec)}, which no cron line repeats evenly. The job is kept without a schedule: Dokkit records its runs and failures but cannot call it late until you add a <code>schedule</code>.`);
      }
      notes.push("A <code>beat</code> check works from the last report, as this did, but only an app's library or <code>POST /api/v1/report</code> sends beats, not a ping URL.");
    }
    if (c.ping_url) comments.push(`Healthchecks pinged ${c.ping_url}`);
    files.push({ id: sid, from: label, text: jobFile(sid, c.name, job, comments), notes, ping: c.ping_url ? hcEvents(c.ping_url) : null, job: sid });
  });
  return { kind: "A Healthchecks export", files, skipped };
}

const hcEvents = (u) => [[u, "ok"], [u + "/start", "start"], [u + "/fail", "fail"], [u + "/<exit code>", "ok for 0, fail for any other"], [u + "/log", "no event of its own: POST the text to ok or fail"], [u + "?rid=…", "?run=… on the same call"]];

const KUMA_NO = {
  keyword: "It looks for a word in the page. Dokkit's http check judges the answer's status, not its text.",
  "json-query": "It reads a value out of a JSON answer. Dokkit's http check judges the status only; a stats document or a threshold check is the way to watch a value.",
  "grpc-keyword": "Dokkit has no gRPC check.",
  ping: "It sends ICMP pings. Dokkit has no ping check; a tcp check on a port the host answers is the nearest.",
  dns: "Dokkit has no DNS check.",
  docker: "Dokkit has no container check; a process check on the machine running it is the nearest.",
  group: "A group is a folder in Uptime Kuma. Its monitors are converted one by one.",
  "real-browser": "Dokkit does not drive a browser.",
};

function fromKuma(doc) {
  const id = namer(), files = [], skipped = [];
  doc.monitorList.forEach((m, i) => {
    const label = m.name || `Monitor ${i + 1}`;
    const no = (why) => skipped.push([label, why]);
    if (m.upsideDown) return no("It is upside down (healthy when it fails). Dokkit has no inverted check.");
    const notes = [], every = m.interval ? dur(m.interval) : null;
    const fail = Math.min(100, Math.max(1, (Number(m.maxretries) || 0) + 1));
    if (m.active === false) notes.push("It was paused in Uptime Kuma; the Dokkit check is active as soon as it is declared.");
    let body;
    if (m.type === "http") {
      if (m.authMethod && m.authMethod !== "null") return no(`It signs in (${esc(m.authMethod)}). Dokkit's http check sends no credentials.`);
      if ((m.method && m.method !== "GET") || m.body) return no(`It sends a ${esc(m.method || "request")} with a body. Dokkit's http check only makes a GET.`);
      body = ['type = "http"', `url = ${str(m.url)}`];
      if (every) body.push(`every = ${str(every)}`);
      if (m.timeout > 0) body.push(`timeout = ${str(dur(m.timeout))}`);
      const codes = (m.accepted_statuscodes || []).filter((s) => /^\d{3}(-\d{3})?$/.test(s));
      if (codes.length) body.push(`status = [${codes.map((s) => (s.includes("-") ? str(s) : +s)).join(", ")}]`);
      body.push(`fail_after = ${fail}`);
      notes.push(`http: <code>interval</code> becomes <code>every</code>, <code>accepted_statuscodes</code> become <code>status</code>, and ${m.maxretries || 0} retries become <code>fail_after = ${fail}</code>.`);
      const dropped = [m.headers && "headers", m.ignoreTls && "ignore TLS errors", m.maxredirects === 0 && "no redirects", m.proxy_id && "a proxy"].filter(Boolean);
      if (dropped.length) notes.push(`Not carried, Dokkit has no field for it: ${dropped.join(", ")}.`);
    } else if (m.type === "port") {
      body = ['type = "tcp"', `host = ${str(m.hostname)}`, `port = ${+m.port}`];
      if (every) body.push(`every = ${str(every)}`);
      body.push(`fail_after = ${fail}`);
      notes.push(`port: a tcp check on <code>${esc(m.hostname)}:${+m.port}</code>, with ${m.maxretries || 0} retries as <code>fail_after = ${fail}</code>. Kuma's timeout is not carried; a tcp check has none.`);
    } else if (m.type === "push") {
      const sid = id(m.name, `monitor-${i + 1}`), p = period(m.interval || 60);
      const job = p ? { schedule: p.cron, grace: p.grace } : {};
      notes.push(p ? `push: a job expected every ${dur(m.interval || 60)}, as one slot each period with <code>grace = ${p.grace}</code>. It can be called late up to one period after Kuma would have.` : `push: every ${dur(m.interval)} repeats evenly on no cron line, so the job has no schedule and is never called late until you add one.`);
      const url = `/api/push/${m.pushToken || "<token>"}`;
      files.push({ id: sid, from: label, text: jobFile(sid, m.name, job, [`Uptime Kuma was pushed at ${url}`]), notes, job: sid,
        ping: [[url + "?status=up", "ok"], [url + "?status=down", "fail"], ["?msg=…", "a POST body, kept as the last output"]] });
      return;
    } else return no(KUMA_NO[m.type] || `Dokkit has no check like Uptime Kuma's ${esc(m.type)} monitor.`);
    const sid = id(m.name, `monitor-${i + 1}`);
    const text = ["schema = 1", "", "[service]", `id = ${str(sid)}`, `name = ${str(label)}`, "", "[[check]]", ...body].join("\n") + "\n";
    files.push({ id: sid, from: label, text, notes, machine: true });
  });
  return { kind: `An Uptime Kuma backup${doc.version ? " from " + esc(doc.version) : ""}`, files, skipped };
}

const EVENT = /^(start|fail|log|ok|success|done|finish|end|\d{1,3})$/i;
const token = (s) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s) || /^[0-9a-f]{32}$/i.test(s) || (/[a-z]/.test(s) && /[A-Z]/.test(s) && /\d/.test(s) && !/[-_.]/.test(s));

function fromUrls(text) {
  const id = namer(), jobs = [], skipped = [], counts = {};
  text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#")).forEach((line) => {
    let u;
    try { u = new URL(line); } catch { return skipped.push([line, "Not a web address."]); }
    if (!/^https?:$/.test(u.protocol)) return skipped.push([line, "Not an http or https address."]);
    const segs = u.pathname.split("/").filter(Boolean);
    const named = segs.filter((s) => !EVENT.test(s) && !token(s) && !["api", "push", "ping"].includes(s.toLowerCase())).pop();
    const host = u.hostname.replace(/^www\./, "").split(".").slice(0, -1).join("-") || "job";
    const jid = named ? id(named) : id(`${host}-${(counts[host] = (counts[host] || 0) + 1)}`);
    const what = u.hostname.endsWith("hc-ping.com") ? "a Healthchecks ping" : /\/api\/push\//.test(u.pathname) ? "an Uptime Kuma push" : "a ping URL";
    jobs.push({ jid, line, what, named: !!named });
  });
  if (!jobs.length) return { kind: "A list of ping URLs", files: [], skipped };
  const sid = "moved-jobs";
  const t = ["schema = 1", "", "[service]", `id = ${str(sid)}`, 'name = "Moved jobs"', 'kind = "job"'];
  jobs.forEach((j) => t.push("", `# was ${j.line}`, "[[job]]", `id = ${str(j.jid)}`));
  const notes = [
    "One job for each line, all in one service so one app key pings them all.",
    "A URL says nothing of when the job runs, so no job has a <code>schedule</code>: Dokkit records runs and failures but calls nothing late until you add one.",
    ...jobs.map((j) => `<code>${esc(j.jid)}</code>: ${j.what}, named ${j.named ? "from its address" : "after its host, since the address holds only a key"}.`),
  ];
  return { kind: "A list of ping URLs", files: [{ id: sid, from: `${jobs.length} URL${jobs.length === 1 ? "" : "s"}`, text: t.join("\n") + "\n", notes, job: jobs[0].jid, ping: null }], skipped };
}

function convert(text) {
  const t = text.trim();
  if (!t) return null;
  if (/^[[{]/.test(t)) {
    let doc;
    try { doc = JSON.parse(t); } catch (e) { return { error: `This looks like JSON but does not parse: ${esc(e.message)}` }; }
    if (doc && Array.isArray(doc.monitorList)) return fromKuma(doc);
    const list = Array.isArray(doc) ? doc : doc && Array.isArray(doc.checks) ? doc.checks : doc && doc.name && (doc.timeout || doc.schedule) ? [doc] : null;
    if (list) return fromHealthchecks(list);
    return { error: "This JSON is neither a Healthchecks export (a <code>checks</code> list) nor an Uptime Kuma backup (a <code>monitorList</code>)." };
  }
  return fromUrls(t);
}

const src = $("#mvSrc");
let ready = false, last = null, typing = false;

function verdictOf(text) {
  if (!ready) return '<i class="s none"></i><span>Waiting for the checker</span>';
  const r = JSON.parse(window.dokkitCheck(text));
  if (!r.ok) return `<i class="s bad"></i><span><b>Refused.</b> ${esc(r.error.replace(/^toml: /, ""))}</span>`;
  const n = r.checks.length, j = r.jobs.length;
  return `<i class="s ok"></i><span><b>Accepted.</b> ${[n && `${n} check${n === 1 ? "" : "s"}`, j && `${j} job${j === 1 ? "" : "s"}`].filter(Boolean).join(", ")}.</span>`;
}

function pingRows(f) {
  const base = `https://your.domain.com/api/v1/in/&lt;app key&gt;/job/${esc(f.job)}`;
  const old = f.ping ? `<div class="mv-was">${f.ping.map(([a, b]) => `<div><code>${esc(a)}</code><span>${esc(b)}</span></div>`).join("")}</div>` : "";
  return `<p class="mv-h">The job also calls</p><div class="mv-was"><div><code>${base}/start</code><span>when it starts</span></div><div><code>${base}/ok</code><span>when it succeeds</span></div><div><code>${base}/fail</code><span>when it fails</span></div></div>${old ? `<p class="mv-h">What the old calls become</p>${old}` : ""}`;
}

function render() {
  const out = $("#mvOut"), sum = $("#mvSum");
  if (typing) return;
  const r = (last = convert(src.value));
  $("#mvKind").textContent = r && !r.error ? r.kind.replace(/&\w+;/g, "") : "";
  $("#mvAll").hidden = !(r && r.files && r.files.length);
  if (!r) { sum.innerHTML = '<i class="s none"></i><span>Paste or drop an export to begin</span>'; out.innerHTML = ""; return; }
  if (r.error) { sum.innerHTML = `<i class="s bad"></i><span>${r.error}</span>`; out.innerHTML = ""; return; }
  const ok = ready ? r.files.filter((f) => JSON.parse(window.dokkitCheck(f.text)).ok).length : 0;
  sum.innerHTML = `<i class="s ${!r.files.length ? "bad" : ready && ok === r.files.length ? "ok" : ready ? "warn" : "none"}"></i><span><b>${r.kind}.</b> ${r.files.length} file${r.files.length === 1 ? "" : "s"}${ready ? `, ${ok === r.files.length ? "all" : ok} accepted by the checker` : ""}${r.skipped.length ? `; ${r.skipped.length} not converted` : ""}.</span>`;
  out.innerHTML = r.files.map((f, i) => `<details class="card mv-file"${i ? "" : " open"}><summary>${verdictOf(f.text).replace(/<span>.*$/, "")}<code>${esc(f.id)}.dokkit.toml</code><small>${esc(f.from)}</small></summary><div class="card-body">
  <p class="verdict">${verdictOf(f.text)}</p>
  <div class="prompt small"><pre id="mvF${i}">${esc(f.text)}</pre><button type="button" class="copy" data-copy="mvF${i}">Copy</button></div>
  <div class="mv-acts"><button type="button" class="copy small" data-dl="${i}">Download</button><small>${f.machine ? "Runs from a machine with <code>dokkit</code>: put it in a folder <code>dokkit</code> reads, as <code>dokkit.toml</code>." : "Send it with <code>dokkit apply</code> and the service's app key."}</small></div>
  <ul class="did mv-notes">${f.notes.map((n) => `<li>${n}</li>`).join("")}</ul>
  ${f.job ? `<details class="card inner mv-calls"><summary>The calls <small>${f.ping ? "old and new" : "new"}</small></summary><div class="card-body">${pingRows(f)}</div></details>` : ""}
</div></details>`).join("") + (r.skipped.length ? `<details class="card mv-file mv-skip" open><summary><i class="s bad"></i>Not converted<small>${r.skipped.length}</small></summary><div class="card-body"><ul class="did no">${r.skipped.map(([n, why]) => `<li><b>${esc(n)}</b>: ${why}</li>`).join("")}</ul></div></details>` : "");
}

function save(f) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([f.text], { type: "application/toml" }));
  a.download = `${f.id}.dokkit.toml`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
document.addEventListener("click", (e) => {
  const d = e.target.closest("[data-dl]");
  if (d && last?.files) save(last.files[+d.dataset.dl]);
  if (e.target.closest("#mvAll") && last?.files) last.files.forEach((f, i) => setTimeout(() => save(f), i * 350));
  const b = e.target.closest("[data-mv]");
  if (b) { typed = true; show(b.dataset.mv); }
});

function show(name) {
  $$("[data-mv]").forEach((b) => b.classList.toggle("on", b.dataset.mv === name));
  src.value = SAMPLES[name];
  render();
}

let typed = false;
src.addEventListener("input", () => { typed = true; render(); });
$("#mvFile").addEventListener("change", (e) => e.target.files[0]?.text().then((t) => { typed = true; src.value = t; render(); }));
const drop = $("#mvDrop");
["dragenter", "dragover"].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add("over"); }));
["dragleave", "drop"].forEach((ev) => drop.addEventListener(ev, () => drop.classList.remove("over")));
drop.addEventListener("drop", (e) => {
  e.preventDefault();
  const f = e.dataTransfer.files[0];
  if (f) f.text().then((t) => { typed = true; src.value = t; render(); });
});

show("hc");
const go = new Go();
WebAssembly.instantiateStreaming(fetch("check.wasm"), go.importObject).then(({ instance }) => {
  go.run(instance);
  ready = true;
  render();
}, () => { $("#mvSum").innerHTML = '<i class="s bad"></i><span>The checker could not load in this browser. The files are still converted; <code>dokkit check</code> on your machine checks them.</span>'; });

// The export pastes itself in, then the files it becomes appear, while the page waits.
if (!still && window.gsap && window.ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  const text = SAMPLES.hc, p = { v: 0 };
  const tl = gsap.timeline({ paused: true });
  tl.call(() => { if (!typed) { typing = true; src.value = ""; $("#mvOut").innerHTML = ""; } })
    .to(p, { v: 1, duration: 1.8, ease: "power1.in", onUpdate: () => { if (!typed) src.value = text.slice(0, Math.round(p.v * text.length)); } })
    .call(() => { typing = false; if (!typed) { render(); gsap.from(".mv-file", { y: 24, opacity: 0, duration: 0.5, stagger: 0.12, ease: "power3.out" }); } })
    .to({}, { duration: 1.1 });
  holdFor("#mvPlay", tl, "top 12%");
}
