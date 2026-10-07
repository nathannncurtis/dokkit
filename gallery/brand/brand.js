// Sample data for the mock. Nothing here talks to a server.
const DATA = {
  need: [
    { id: "DOK-12", s: "bad", t: "nightly-purge did not run", m: "db-01", w: "34 min",
      more: "Expected at 01:00. Its last good run was the night before and took 4 minutes. Paged at 01:33." },
    { id: "DOK-09", s: "warn", t: "upload portal answers slowly", m: "web-02", w: "12 min",
      more: "Three checks in a row took over two seconds, the limit its file sets. It is still answering. Pushed, not paged." },
    { id: "DOK-13", s: "warn", t: "disk at 91%", m: "nas", w: "since 09:12",
      more: "The limit is 90%. At this week's rate it is full in about 9 days." },
  ],
  soon: [
    { id: "DOK-14", s: "warn", t: "certificate for mail expires in 21 days", m: "mail", w: "30 Oct",
      more: "Dokkit warns thirty days ahead. This closes by itself when a newer certificate is seen." },
    { id: "DOK-15", s: "warn", t: "backup ran long", m: "nas", w: "Thu",
      more: "It took 3 hours against a limit of 2. 2 times in the last 7 days. Both runs finished, so nobody was woken." },
  ],
  snoozed: [
    { id: "DOK-11", s: "warn", t: "report builder is slow", m: "sql", w: "until 09:00", back: true,
      more: "Snoozed until 09:00. It comes back then if it is still open, and closes by itself if the thing recovers first." },
  ],
  found: [
    { id: "found", s: "none", t: "sshd is listening on port 22", m: "build", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "found", s: "none", t: "a scheduled task named defrag", m: "sql", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "found", s: "none", t: "something is listening on port 8443", m: "web-02", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "found", s: "none", t: "the print spooler service", m: "build", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
  ],
};
const fresh = JSON.stringify(DATA);
let lists = JSON.parse(fresh);
let tab = "need", fine = 57;
const $ = (q) => document.querySelector(q);
const $$ = (q) => [...document.querySelectorAll(q)];

function draw() {
  const rows = lists[tab];
  $("#nNeed").textContent = lists.need.length;
  $("#paneTitle").textContent = { need: "This needs your attention.", soon: "Soon, not yet.", found: "Found, and nothing is watching it.", snoozed: "Snoozed, for now." }[tab];
  $("#nSnoozed").textContent = lists.snoozed.length;
  $("#nFound").textContent = lists.found.length;
  if (!rows.length) {
    $("#list").innerHTML = `<div class="empty"><b>${tab === "need" ? "Nothing here needs you." : "Nothing here."}</b>${tab === "need" ? "Everything else is fine. " : ""}<button data-reset>Put the samples back</button></div>`;
    return;
  }
  $("#list").innerHTML = rows.map((r, i) => `
    <div class="item" data-i="${i}">
      <button aria-expanded="false"><i class="s ${r.s}"></i><code>${r.id === "found" ? "" : r.id}</code><b>${r.t}</b><span class="m">${r.m}</span><time>${r.w}</time></button>
      <div class="more"><div><div class="in"><p>${r.more}</p><div class="acts">${
        r.back ? `<button class="btn sm pri" data-act>Bring back</button>`
        : r.watch ? `<button class="btn sm pri" data-act>Watch it</button><button class="btn sm" data-act>Leave it</button>`
                : `<button class="btn sm pri" data-act>Snooze an hour</button><button class="btn sm" data-act>Mark as seen</button>`
      }</div></div></div></div>
    </div>`).join("") + (tab === "need" ? `<div class="fine"><i class="s ok"></i>${fine} more are fine, on 7 machines.</div>` : "");
}

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-tab],[data-act],[data-reset],[data-copy],[data-q],.item > button");
  if (!t) return;
  if (t.dataset.q) { $$(".qs button").forEach((b) => b.classList.toggle("on", b === t)); return ask(+t.dataset.q); }
  if (t.dataset.tab) { tab = t.dataset.tab; $$(".win aside button").forEach((b) => b.classList.toggle("on", b === t)); draw(); }
  else if ("reset" in t.dataset) { lists = JSON.parse(fresh); fine = 57; draw(); }
  else if ("act" in t.dataset) {
    const item = t.closest(".item");
    item.classList.add("gone");
    setTimeout(() => {
      const [row] = lists[tab].splice(+item.dataset.i, 1);
      // Snoozing moves it to Snoozed, and bringing it back returns it.
      if (t.textContent === "Snooze an hour") lists.snoozed.push({ ...row, was: tab, w: "for an hour", back: true });
      if (t.textContent === "Bring back") lists[row.was || "need"].push({ ...row, back: false, w: "back" });
      draw();
    }, 300);
  } else if (t.dataset.copy) {
    const text = $("#" + t.dataset.copy).textContent;
    const done = () => { t.textContent = "Copied"; setTimeout(() => (t.textContent = "Copy"), 1400); };
    // The clipboard needs https; on plain http the command is selected instead.
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done);
    else { getSelection().selectAllChildren($("#" + t.dataset.copy)); t.textContent = "Selected"; setTimeout(() => (t.textContent = "Copy"), 1400); }
  } else {
    const item = t.parentElement, open = item.classList.toggle("open");
    t.setAttribute("aria-expanded", open);
  }
});

// One day: 7 machines by 48 half-hours.
const MACHINES = ["db-01", "web-02", "nas", "mail", "build", "front-desk-pc", "sql"];
const MARKS = { "db-01": { 3: "bad", 4: "bad" }, "web-02": { 19: "warn", 20: "warn", 21: "warn" }, nas: { 4: "warn" }, "front-desk-pc": {} };
for (let i = 18; i < 27; i++) MARKS.nas[i] = "warn";
for (let i = 0; i < 16; i++) MARKS["front-desk-pc"][i] = "none";
const SAY = { bad: "something was down", warn: "something needed a look", none: "no signal", undefined: "all quiet" };
$("#lanes").innerHTML = MACHINES.map((m) => `<span>${m}</span><div class="lane">${
  Array.from({ length: 48 }, (_, i) => `<i class="${(MARKS[m] || {})[i] || ""}" style="--c:${i}" data-m="${m}" data-i="${i}"></i>`).join("")}</div>`).join("");
$("#lanes").addEventListener("mouseover", (e) => {
  const c = e.target.closest("i[data-m]");
  if (!c) return;
  const i = +c.dataset.i, time = String(Math.floor(i / 2)).padStart(2, "0") + ":" + (i % 2 ? "30" : "00");
  $("#tip").textContent = `${c.dataset.m} at ${time}: ${SAY[(MARKS[c.dataset.m] || {})[i]]}.`;
});

// Who is told: the choices write the sentence.
function say() {
  const how = $('input[name="how"]:checked').value, night = $("#night").checked, late = $("#late").value, long = $("#long").value;
  $("#lateOut").textContent = late + " min";
  $("#longOut").textContent = long + " min";
  const what = { page: "page you", push: "send a silent push", email: "email you", digest: "put it in the morning digest" }[how];
  const when = how === "digest" ? "" : night ? ", even at night" : ", and wait for morning if it is night";
  $("#said").innerHTML = `If nightly-purge has not run ${late} minutes after 01:00, Dokkit will <b>${what}</b>${when}. A run that finishes over ${long} minutes goes under Soon and wakes nobody. One still going past it needs you.`;
}
$("#told").addEventListener("input", say);

// What an agent is offered follows its token.
const TOOLS = {
  read: ["attention", "find", "service", "jobs", "job_runs", "errors", "since_deploy", "tasks", "machines", "machine", "issues", "issue", "deploys", "versions", "rules", "proposals", "task_runs", "series", "day", "alert_settings", "alert_suggestions"],
  "read-logs": ["logs", "archives"],
  act: ["snooze", "acknowledge", "run_task", "unsnooze", "note", "bulk", "watch", "unwatch", "routing", "hold", "accept_proposal", "dismiss_proposal", "keep_messages", "set_job_timing"],
  admin: ["add_rule", "update_rule", "delete_rule", "set_checks", "allow_restart", "keys", "make_key", "revoke_key", "people", "add_person", "remove_person", "accept_task", "dismiss_task", "update_program", "add_job", "set_alert_settings", "test_alert", "accept_suggestion", "dismiss_suggestion", "restore_archive"],
};
function offer() {
  const all = $("#scAll").checked;
  const on = { read: true, "read-logs": all || $("#scLogs").checked, act: all || $("#scAct").checked, admin: all };
  let n = 0;
  $("#tools").innerHTML = Object.entries(TOOLS).map(([s, names]) => names.map((t) => { n += on[s]; return `<code class="${on[s] ? (s === "admin" ? "adm" : "") : "off"}">${t}</code>`; }).join("")).join("");
  $("#toolSay").textContent = `This token is offered ${n} of 57 tools. ` + (all ? "It can do anything you can, keys and people included." : (on.act ? "It can act on issues and run tasks you accepted. It cannot touch keys, people or rules." : "It cannot change anything.") + (on["read-logs"] ? "" : " Log contents are left out of every answer."));
}
// Full control is not a switch you can just flip.
let sure = false;
$("#token").addEventListener("input", (e) => {
  const box = $("#scAll");
  if (e.target === box) {
    if (box.checked && !sure) { box.checked = false; $("#sure").hidden = false; return $("#sureText").focus(); }
    if (!box.checked) sure = false;
  }
  if (e.target.id === "sureText") return ($("#sureYes").disabled = e.target.value.trim() !== "dokkit.brightwater.example");
  offer(); ask(asked);
});
$("#sureYes").onclick = () => { sure = true; $("#scAll").checked = true; shut(); offer(); ask(asked); };
const shut = () => { $("#sure").hidden = true; $("#sureText").value = ""; $("#sureYes").disabled = true; };
$("#sureNo").onclick = shut;

// What an agent does with it. The calls are the MCP tools; a tool the token lacks is never called.
const ASK = [
  () => [["call", "attention"], ["got", "3 need you · 2 soon · 4 not watched"],
    ["says", "Three things. nightly-purge did not run at 01:00 on db-01 (DOK-12), and that one paged you. The upload portal is answering slowly (DOK-09). The disk on nas is at 91% (DOK-13)."]],
  (on) => [["call", 'job_runs { id: "nightly-purge" }'], ["got", "last good run yesterday 01:00, 4 min · no start reported today"],
    ...(on.logs
      ? [["call", 'logs { service: "nightly-purge", level: "error" }'], ["got", "00:58 db-01 cron: cannot start purge.sh: /var/spool is over quota"],
         ["says", "It never started. At 00:58 cron on db-01 could not start it because /var/spool was over its quota. The run the night before was normal, so this is new."]]
      : [["says", "It never started: no start was reported after 01:00, and the run before it was normal. I cannot say why. This token is not offered the logs tool."],
         ["note", "Let the token read the logs, on the left, and it can."]])],
  () => [["call", 'since_deploy { id: "upload-portal" }'], ["got", "2.4.1 onto web-02 at 09:31 · 1 new error group · 1 issue opened"],
    ["says", "Version 2.4.1 went onto web-02 at 09:31. Nine minutes later the portal began answering slowly (DOK-09), and there is one new error group: TimeoutError in resize.py, 14 reports. Nothing else changed."]],
  (on) => on.act
    ? [["call", 'snooze { id: "DOK-13", until: "Monday 09:00" }'], ["got", "snoozed"], ["says", "Done. DOK-13 is snoozed until Monday 09:00. It closes by itself before then if the disk drops under 90%."]]
    : [["says", "I cannot. This token reads, and is not offered snooze."], ["note", "Let the token act, on the left, and ask again."]],
  (on) => on.all
    ? [["call", 'add_rule { kind: "machine", machine: "db-01", state: "down", channel: "page" }'], ["got", "rule added, last in the list"], ["says", "Done. If db-01 goes down, you are paged. A service's own routing and earlier rules still win."]]
    : [["says", "I cannot. Rules decide who is told, and this token is not offered add_rule."], ["note", "Full control, on the left, makes you confirm first."]],
];
const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
let asked = 0, turn = 0;
function ask(q) {
  asked = q;
  const mine = ++turn, talk = $("#talk");
  const all = $("#scAll").checked;
  const lines = [["you", $(`.qs [data-q="${q}"]`).textContent], ...ASK[q]({ logs: all || $("#scLogs").checked, act: all || $("#scAct").checked, all })];
  talk.innerHTML = "";
  lines.forEach(([kind, text], i) => setTimeout(() => {
    if (mine !== turn) return;
    talk.querySelector(".wait")?.classList.remove("wait");
    const p = document.createElement("p");
    p.className = kind + (i < lines.length - 1 ? " wait" : "");
    p.textContent = (kind === "call" ? "→ " : "") + text;
    talk.append(p);
  }, still ? 0 : i * 650));
}

// The file, lightly coloured.
$("#toml").innerHTML = $("#toml").textContent.replace(/"[^"]*"/g, '<span class="str">$&</span>').replace(/^\[.*\]$/gm, '<span class="k">$&</span>').replace(/#.*$/gm, '<span class="c">$&</span>');

// Things arrive as they are reached.
document.documentElement.classList.add("js");
const seen = new IntersectionObserver((es) => es.forEach((e) => {
  if (!e.isIntersecting) return;
  e.target.classList.add("in");
  seen.unobserve(e.target);
  if (e.target.id === "ask") ask(0);
}), { threshold: 0.15 });
$$(".head, .panel, .events, .told h2, .saidcol, .stick, .how dl > div, .steps li, .ways li, .needs").forEach((el) => {
  el.classList.add("rv");
  el.style.transitionDelay = Math.min([...el.parentElement.children].indexOf(el), 5) * 70 + "ms";
  seen.observe(el);
});
const here = new IntersectionObserver((es) => es.forEach((e) => {
  if (e.isIntersecting) $$(".nav nav a").forEach((a) => a.classList.toggle("cur", a.getAttribute("href") === "#" + e.target.id));
}), { rootMargin: "-45% 0px -50% 0px" });
$$("main section[id]").forEach((s) => here.observe(s));

// The slow portal recovers while you watch, and its issue closes by itself.
setTimeout(() => {
  const at = () => lists.need.findIndex((r) => r.id === "DOK-09");
  const el = $(`.item[data-i="${at()}"]`);
  if (tab !== "need" || !el || el.classList.contains("open")) return;
  el.classList.add("well");
  el.querySelector(".s").className = "s ok";
  el.querySelector("time").textContent = "recovered";
  setTimeout(() => {
    if (tab !== "need" || at() < 0) return;
    $(`.item[data-i="${at()}"]`).classList.add("gone");
    setTimeout(() => { lists.need.splice(at(), 1); fine++; draw(); }, 300);
  }, 2200);
}, 9000);

draw();
say();
offer();
