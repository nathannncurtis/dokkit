// The sample's data is made up. Nothing here talks to a server.
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
      more: "It took 3 hours against a limit of 2. Both runs finished, so nobody was woken." },
  ],
  snoozed: [
    { id: "DOK-11", s: "warn", t: "report builder is slow", m: "sql", w: "until 09:00", back: true,
      more: "Snoozed until 09:00. It comes back then if it is still open, and closes by itself if the thing recovers first." },
  ],
  found: [
    { id: "", s: "none", t: "sshd is listening on port 22", m: "build", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "", s: "none", t: "a scheduled task named defrag", m: "sql", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "", s: "none", t: "something is listening on port 8443", m: "web-02", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
    { id: "", s: "none", t: "the print spooler service", m: "build", w: "found", watch: true, more: "Found when the machine was scanned. Nothing checks it yet." },
  ],
};
const MACHINES = ["db-01", "web-02", "nas", "mail", "build", "front-desk-pc", "sql"];
const TITLES = { need: "This needs your attention.", soon: "Soon, not yet.", found: "Found, and nothing is watching it.", snoozed: "Snoozed, for now." };
const fresh = JSON.stringify(DATA);
let lists = JSON.parse(fresh), tab = "need", fine = 57;

function draw() {
  $("#nNeed").textContent = lists.need.length;
  $("#nSnoozed").textContent = lists.snoozed.length;
  $("#nFound").textContent = lists.found.length;
  $("#paneTitle").textContent = TITLES[tab];
  const rows = lists[tab];
  if (!rows.length) {
    $("#list").innerHTML = `<div class="empty"><b>${tab === "need" ? "Nothing here needs you." : "Nothing here."}</b>${tab === "need" ? "Everything else is fine. " : ""}<button data-reset>Put the samples back</button></div>`;
    return;
  }
  $("#list").innerHTML = rows.map((r, i) => `
    <div class="item" data-i="${i}">
      <button aria-expanded="false"><i class="s ${r.s}"></i><code>${r.id}</code><b>${r.t}</b><span class="m">${r.m}</span><time>${r.w}</time></button>
      <div class="more"><div><div class="in"><p>${r.more}</p><div class="acts">${
        r.back ? `<button class="pri" data-act="back">Bring back</button>`
        : r.watch ? `<button class="pri" data-act="leave">Watch it</button><button data-act="leave">Leave it</button>`
        : `<button class="pri" data-act="snooze">Snooze an hour</button><button data-act="seen">Mark as seen</button>`
      }</div></div></div></div>
    </div>`).join("") + (tab === "need" ? `<div class="fine"><i class="s ok"></i><span><b>${fine}</b> more are fine, on 7 machines.</span></div>` : "");
}

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-tab],[data-act],[data-reset],[data-os],.item > button");
  if (!t) return;
  if (t.dataset.os) return setOs(t.dataset.os);
  if (t.dataset.tab) {
    tab = t.dataset.tab;
    $$(".tabs button").forEach((b) => b.setAttribute("aria-selected", b === t));
    return draw();
  }
  if ("reset" in t.dataset) { lists = JSON.parse(fresh); fine = 57; return draw(); }
  if (t.dataset.act) {
    const item = t.closest(".item");
    item.classList.add("gone");
    return setTimeout(() => {
      const [row] = lists[tab].splice(+item.dataset.i, 1);
      if (t.dataset.act === "snooze") lists.snoozed.push({ ...row, was: tab, w: "for an hour", back: true });
      if (t.dataset.act === "back") lists[row.was || "need"].push({ ...row, back: false, w: "back" });
      draw();
    }, still ? 0 : 300);
  }
  const item = t.parentElement, open = item.classList.toggle("open");
  t.setAttribute("aria-expanded", open);
});

// The install sentence writes the command.
let os = "linux", typing = 0;
function commands() {
  const host = $("#host").value.trim() || "your.domain.com";
  return os === "linux"
    ? [`curl -fsSL https://dokkit.dev/install.sh | sudo sh -s -- ${host}`, "curl -fsSL https://dokkit.dev/get.sh | sh"]
    : ["irm https://dokkit.dev/install.ps1 | iex", "irm https://dokkit.dev/get.ps1 | iex"];
}
function write(animate) {
  const [cmd, get] = commands(), el = $("#cmd"), mine = ++typing;
  $("#get").textContent = get;
  if (!animate || still) { el.textContent = cmd; el.classList.remove("caret"); return; }
  el.classList.add("caret");
  let i = 0;
  const step = () => {
    if (mine !== typing) return;
    i = Math.min(cmd.length, i + 3);
    el.textContent = cmd.slice(0, i);
    if (i < cmd.length) requestAnimationFrame(step);
    else setTimeout(() => mine === typing && el.classList.remove("caret"), 900);
  };
  step();
}
function setOs(next) {
  os = next;
  $$("[data-os]").forEach((b) => b.setAttribute("aria-checked", b.dataset.os === os));
  $("#atWrap").hidden = os !== "linux";
  write(true);
}
$("#host").addEventListener("input", () => write(false));

// One round of checks: all of them arrive, the fine ones fold into one line, three stay.
function round() {
  const list = $("#list"), pane = $(".pane");
  if (still || tab !== "need" || !list.querySelector(".fine")) return;
  const kinds = ["http", "disk", "tcp :443", "process", "service", "backup", "cert", "memory"];
  const flagged = { 7: 0, 23: 1, 41: 2 };
  const box = document.createElement("div");
  box.className = "round";
  box.style.top = list.offsetTop + "px";
  box.innerHTML = Array.from({ length: 60 }, (_, i) => {
    const f = flagged[i], r = lists.need[f];
    return f === undefined
      ? `<span style="--n:${i}"><i class="s ok"></i>${MACHINES[i % 7]} · ${kinds[(i * 3) % 8]}</span>`
      : `<span class="flag" data-f="${f}" style="--n:${i}"><i class="s ${r.s}"></i>${r.m} · ${r.t}</span>`;
  }).join("");
  list.classList.add("prep");
  pane.append(box);
  const line = list.querySelector(".fine"), count = line.querySelector("b");
  count.textContent = "0";
  let done = false, landed = 0;
  const finish = () => {
    if (done) return;
    done = true;
    box.remove();
    list.classList.remove("prep");
    $(".frame").removeEventListener("pointerdown", finish, true);
    draw();
  };
  $(".frame").addEventListener("pointerdown", finish, true);
  setTimeout(() => {
    if (done) return;
    const to = line.querySelector(".s").getBoundingClientRect();
    line.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300, fill: "forwards" });
    const oks = [...box.children].filter((t) => !t.dataset.f);
    oks.forEach((t, i) => {
      const r = t.getBoundingClientRect();
      t.animate([{ transform: "none", opacity: 1 }, { transform: `translate(${to.left - r.left}px, ${to.top - r.top}px) scale(0.18)`, opacity: 0, filter: "blur(2px)" }],
        { duration: 560, delay: 120 + i * 9, easing: "cubic-bezier(0.55, 0, 0.85, 0.35)", fill: "forwards" })
        .onfinish = () => { count.textContent = ++landed; };
    });
    const settle = 120 + oks.length * 9 + 420;
    $$(".flag", box).forEach((t) => {
      const row = list.querySelector(`.item[data-i="${t.dataset.f}"]`), a = t.getBoundingClientRect(), b = row.getBoundingClientRect();
      t.animate([{ opacity: 1 }, { transform: `translate(${b.left - a.left}px, ${b.top - a.top}px)`, opacity: 0 }], { duration: 640, delay: settle - 40, easing: "cubic-bezier(0.16, 1, 0.3, 1)", fill: "forwards" });
      row.animate([{ transform: `translate(${a.left - b.left}px, ${a.top - b.top}px)`, opacity: 0 }, { transform: "none", opacity: 1 }], { duration: 760, delay: settle, easing: "cubic-bezier(0.16, 1, 0.3, 1)", fill: "backwards" });
      row.style.opacity = 1;
    });
    setTimeout(finish, settle + 820);
  }, 60 * 11 + 380 + 450);
}

// A round every thirty seconds while the sample is on screen.
let lastRound = Date.now(), showing = false;
function newRound() {
  lastRound = Date.now();
  const sw = $("#sweep");
  sw.classList.remove("run");
  void sw.offsetWidth;
  if (!still) sw.classList.add("run");
  $(".fine .s")?.animate([{ boxShadow: "0 0 0 0 color-mix(in srgb, var(--ok) 60%, transparent)" }, { boxShadow: "0 0 0 10px transparent" }], { duration: 900, easing: "ease-out" });
}
setInterval(() => {
  if (!showing || document.hidden) { lastRound += 1000; return; }
  const s = Math.round((Date.now() - lastRound) / 1000);
  $("#beat").textContent = s < 2 ? "checked just now" : `checked ${s}s ago`;
  if (s >= 30) newRound();
}, 1000);

// The slow portal recovers while you watch, and its issue closes by itself.
function recover() {
  const at = () => lists.need.findIndex((r) => r.id === "DOK-09");
  const el = $(`.item[data-i="${at()}"]`);
  if (tab !== "need" || !el || el.classList.contains("open")) return;
  el.classList.add("well");
  el.querySelector(".s").className = "s ok";
  el.querySelector("time").textContent = "recovered";
  setTimeout(() => {
    if (tab !== "need" || at() < 0) return;
    $(`.item[data-i="${at()}"]`)?.classList.add("gone");
    setTimeout(() => { lists.need.splice(at(), 1); fine++; draw(); }, 300);
  }, 2200);
}


draw();
write(false);

const pinned = !still && window.gsap && window.ScrollTrigger;
let started = false;
new IntersectionObserver(([e]) => {
  showing = e.isIntersecting;
  if (showing && !started) {
    started = true;
    newRound();
    if (!pinned) { setTimeout(round, still ? 0 : 300); setTimeout(recover, 12000); }
  }
}, { threshold: 0.35 }).observe($(".frame"));

// With motion on, these moments play by themselves when they reach the top, and the page waits for them.
if (pinned) {
  gsap.registerPlugin(ScrollTrigger);
  document.documentElement.classList.add("pinned");
  holdRound();
  holdWatches();
}

function holdRound() {
  const list = $("#list"), pane = $(".pane"), frame = $(".frame");
  const kinds = ["http", "disk", "tcp :443", "process", "service", "backup", "cert", "memory"];
  const flagged = { 7: 0, 23: 1, 41: 2 };
  const box = document.createElement("div");
  box.className = "round scrub";
  box.style.top = list.offsetTop + "px";
  box.innerHTML = Array.from({ length: 60 }, (_, i) => {
    const f = flagged[i], r = lists.need[f];
    return f === undefined
      ? `<span><i class="s ok"></i>${MACHINES[i % 7]} · ${kinds[(i * 3) % 8]}</span>`
      : `<span class="flag" data-f="${f}"><i class="s ${r.s}"></i>${r.m} · ${r.t}</span>`;
  }).join("");
  pane.append(box);
  const tiles = [...box.children], oks = tiles.filter((t) => !t.dataset.f), flags = tiles.filter((t) => t.dataset.f);
  const line = list.querySelector(".fine"), count = line.querySelector("b"), rows = flags.map((t) => list.querySelector(`.item[data-i="${t.dataset.f}"]`));
  const to = line.querySelector(".s").getBoundingClientRect();
  const fold = oks.map((t) => { const r = t.getBoundingClientRect(); return [to.left - r.left, to.top - r.top]; });
  const lift = flags.map((t, i) => { const a = t.getBoundingClientRect(), b = rows[i].getBoundingClientRect(); return [b.left - a.left, b.top - a.top]; });
  const caps = $$("#cap span"), n = { v: 0 }, label = $(".sample .label");
  label.removeAttribute("data-type");
  gsap.set([...rows, line], { opacity: 0 });
  gsap.set(tiles, { opacity: 0, y: 14, scale: 0.94 });
  gsap.set(caps, { opacity: 0, y: 10 });
  frame.style.pointerEvents = "none";

  const tl = gsap.timeline({ paused: true, onComplete: () => { frame.style.pointerEvents = ""; box.remove(); setTimeout(recover, 6000); } });
  tl.to(caps[0], { opacity: 1, y: 0, duration: 0.3 }, 0)
    .to(tiles, { opacity: 1, y: 0, scale: 1, stagger: 0.011, duration: 0.3, ease: "power2.out" }, 0.1)
    .to({}, { duration: 0.6 })
    .to(caps[0], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[1], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to(line, { opacity: 1, duration: 0.3 }, "<")
    .to(oks, { x: (i) => fold[i][0], y: (i) => fold[i][1], scale: 0.18, opacity: 0, stagger: 0.009, duration: 0.5, ease: "power2.in" }, "<")
    .to(n, { v: 57, duration: 0.5 + 0.009 * 56, ease: "none", onUpdate: () => (count.textContent = Math.round(n.v)) }, "<")
    .to({}, { duration: 0.3 })
    .to(caps[1], { opacity: 0, y: -10, duration: 0.2 })
    .to(caps[2], { opacity: 1, y: 0, duration: 0.3 }, "<0.18")
    .to(flags, { x: (i) => lift[i][0], y: (i) => lift[i][1], opacity: 0, duration: 0.6, ease: "power3.inOut" }, "<")
    .fromTo(rows, { x: (i) => -lift[i][0], y: (i) => -lift[i][1], opacity: 0 }, { x: 0, y: 0, opacity: 1, duration: 0.7, ease: "power3.out" }, "<0.05")
    .to({}, { duration: 0.1 });
  typeIn(tl, label, 0.5, ">");
  tl.timeScale(tl.duration() / 3.5);
  holdFor("#sample", tl, "top top");
}

function holdWatches() {
  const sec = $(".watches"), h = $("h2", sec), cards = $$(".watch-table .tr:not(.th)", sec);
  h.removeAttribute("data-type");
  cards.forEach((c) => c.removeAttribute("data-fly"));
  gsap.set(cards, { opacity: 0, y: 24 });
  gsap.set(".sub-lede", { opacity: 0, y: 14 });
  const tl = gsap.timeline({ paused: true });
  typeIn(tl, h, 0.9, 0);
  tl.to(".sub-lede", { opacity: 1, y: 0, duration: 0.3 }, 0.8)
    .to(cards, { opacity: 1, y: 0, stagger: 0.08, duration: 0.45, ease: "power3.out" }, 0.95);
  holdFor(sec, tl, "top 12%");
}

let downHits = [];
document.addEventListener("click", (e) => {
  const row = e.target.closest(".item > button");
  if (!row || !row.querySelector(".s.bad")) return;
  const now = Date.now(), pane = $(".pane");
  downHits = downHits.filter((t) => now - t < 4000).concat(now);
  if (downHits.length < 5 || pane.classList.contains("playing")) return;
  downHits = [];
  const open = () => {
    const found = document.createElement("p"), root = document.createElement("div");
    found.className = "kg-found";
    found.innerHTML = '<span>You found it.</span><button type="button">Back to the sample</button>';
    pane.classList.add("playing");
    pane.prepend(found, root);
    const game = KeepGreen.mount(root);
    $("[data-k=start]", root).focus();
    $("button", found).onclick = () => {
      game.stop();
      found.remove();
      root.remove();
      pane.classList.remove("playing");
      $(".item .s.bad")?.closest("button").focus();
    };
  };
  if (window.KeepGreen) return open();
  const css = document.createElement("link"), js = document.createElement("script");
  css.rel = "stylesheet";
  css.href = "keep-green.css?v=20";
  js.src = "keep-green.js?v=20";
  js.onload = open;
  document.head.append(css, js);
});
