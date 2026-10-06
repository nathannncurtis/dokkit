// Sample data for the mock. Nothing here talks to a server.
const DATA = {
  need: [
    { id: "DOK-12", s: "bad", t: "nightly-purge did not run", m: "db-01", w: "34 min",
      more: "Due at 01:00 and no start was reported. Its last good run was the night before and took 4 minutes. You were paged once, at 01:33." },
    { id: "DOK-09", s: "warn", t: "upload portal answers slowly", m: "web-02", w: "12 min",
      more: "Three checks in a row took over two seconds. It is still answering. A silent push was sent; nobody was paged." },
    { id: "DOK-13", s: "warn", t: "disk at 91%", m: "nas", w: "since 09:12",
      more: "The limit is 90%. At this week's rate it is full in about nine days." },
  ],
  soon: [
    { id: "DOK-14", s: "warn", t: "certificate for mail expires in 21 days", m: "mail", w: "30 Oct",
      more: "Dokkit warns thirty days ahead. This closes by itself when a newer certificate is seen." },
    { id: "DOK-15", s: "warn", t: "backup ran long twice this week", m: "nas", w: "Tue, Thu",
      more: "Both runs finished. It is here because the pattern is new, not because anything failed." },
  ],
  found: [
    { id: "found", s: "none", t: "sshd is listening on port 22", m: "build", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "found", s: "none", t: "a scheduled task named defrag", m: "sql", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "found", s: "none", t: "something is listening on port 8443", m: "web-02", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "found", s: "none", t: "the print spooler service", m: "front-desk-pc", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
  ],
};
const fresh = JSON.stringify(DATA);
let lists = JSON.parse(fresh);
let tab = "need";
const $ = (q) => document.querySelector(q);
const $$ = (q) => [...document.querySelectorAll(q)];

function draw() {
  const rows = lists[tab];
  $("#nNeed").textContent = lists.need.length;
  $("#paneTitle").textContent = { need: "This needs your attention.", soon: "Soon, not yet.", found: "Found, and nothing is watching it." }[tab];
  $("#nFound").textContent = lists.found.length;
  if (!rows.length) {
    $("#list").innerHTML = `<div class="empty"><b>Nothing here needs you.</b>Everything else is fine. <button data-reset>Put the samples back</button></div>`;
    return;
  }
  $("#list").innerHTML = rows.map((r, i) => `
    <div class="item" data-i="${i}">
      <button aria-expanded="false"><i class="s ${r.s}"></i><code>${r.id === "found" ? "" : r.id}</code><b>${r.t}</b><span class="m">${r.m}</span><time>${r.w}</time></button>
      <div class="more"><div><div class="in"><p>${r.more}</p><div class="acts">${
        r.watch ? `<button class="btn sm pri" data-act>Watch it</button><button class="btn sm" data-act>Leave it</button>`
                : `<button class="btn sm pri" data-act>Snooze an hour</button><button class="btn sm" data-act>Mark as seen</button>`
      }</div></div></div></div>
    </div>`).join("") + (tab === "need" ? `<div class="fine"><i class="s ok"></i>57 more are fine, on 7 machines.</div>` : "");
}

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-tab],[data-act],[data-reset],[data-copy],.item > button");
  if (!t) return;
  if (t.dataset.tab) { tab = t.dataset.tab; $$(".win aside button").forEach((b) => b.classList.toggle("on", b === t)); draw(); }
  else if ("reset" in t.dataset) { lists = JSON.parse(fresh); draw(); }
  else if ("act" in t.dataset) {
    const item = t.closest(".item");
    item.classList.add("gone");
    setTimeout(() => { lists[tab].splice(+item.dataset.i, 1); draw(); }, 300);
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
const MARKS = { "db-01": { 2: "bad", 3: "bad" }, "web-02": { 19: "warn", 20: "warn", 21: "warn" }, nas: { 4: "warn" }, "front-desk-pc": {} };
for (let i = 18; i < 27; i++) MARKS.nas[i] = "warn";
for (let i = 0; i < 16; i++) MARKS["front-desk-pc"][i] = "none";
const SAY = { bad: "something was down", warn: "something needed a look", none: "switched off, no signal", undefined: "quiet, every report arrived" };
$("#lanes").innerHTML = MACHINES.map((m) => `<span>${m}</span><div class="lane">${
  Array.from({ length: 48 }, (_, i) => `<i class="${(MARKS[m] || {})[i] || ""}" data-m="${m}" data-i="${i}"></i>`).join("")}</div>`).join("");
$("#lanes").addEventListener("mouseover", (e) => {
  const c = e.target.closest("i[data-m]");
  if (!c) return;
  const i = +c.dataset.i, time = String(Math.floor(i / 2)).padStart(2, "0") + ":" + (i % 2 ? "30" : "00");
  $("#tip").textContent = `${c.dataset.m} at ${time}: ${SAY[(MARKS[c.dataset.m] || {})[i]]}.`;
});

// Who is told: the choices write the sentence.
function say() {
  const how = $('input[name="how"]:checked').value, night = $("#night").checked, restart = $("#restart").checked, late = $("#late").value;
  $("#lateOut").textContent = late + " min";
  const what = { page: "page you", push: "send a silent push", email: "email you", digest: "put it in the morning digest" }[how];
  const when = how === "digest" ? "" : night ? ", even at night" : ", and wait for morning if it is night";
  $("#said").innerHTML = `If nightly-purge has not run ${late} minutes after 01:00, Dokkit will ${restart ? "start it once, and if that fails " : ""}<b>${what}</b>${when}.`;
}
$("#told").addEventListener("input", say);

draw();
say();
