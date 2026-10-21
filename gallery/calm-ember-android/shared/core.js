// What every direction shows, worked out the way the Android app does it today (core/Home.kt, core/Screens.kt),
// plus the scenarios the review page switches between and the phone settings with their defaults.
window.CORE = (function () {
  var P = window.PHONE, MIN = 60000;
  var q = new URLSearchParams(location.search);
  var scenario = q.get("s") || "normal";

  // ---------- settings: today's built-in values are the defaults ----------
  var SETTINGS = [
    { key: "theme", title: "Theme", sub: "Light or dark. Follows the phone until you pick one.", def: "System", choices: ["System", "Light", "Dark"] },
    { key: "accent", title: "Accent", sub: "The colour of buttons and the selected tab.", def: "Orange", choices: ["Orange", "Teal"] },
    { key: "refresh", title: "Look for a new snapshot", sub: "While the app is in front. It also looks when opened and when you pull down.", def: 30, unit: "seconds", words: ["Every", "seconds"], min: 10, max: 600 },
    { key: "late", title: "Snapshot is late", sub: "Past this age the snapshot gets a warning.", def: 5, words: ["After", "minutes"], min: 1, max: 120 },
    { key: "hot", title: "Busy meters", sub: "A processor, memory or disk meter turns amber above this.", def: 85, words: ["Above", "%"], min: 1, max: 100 },
    { key: "fineShown", title: "Fine services listed", sub: "On a machine, the rest fold under \"and more that are fine\".", def: 8, words: ["Show", "then fold"], min: 1, max: 100 },
    { key: "relayWait", title: "Relay timeout", sub: "How long to wait for the relay before saying it could not be reached.", def: 15, words: ["Wait", "seconds"], min: 5, max: 120 },
    { key: "lock", title: "Ask to unlock", sub: "Fingerprint, face or screen lock before anything shows.", def: "Every launch and every return", choices: ["Every launch and every return", "Every launch, and after 1 min away", "Every launch, and after 5 min away"] }
  ];
  var STORE_KEY = "dokkit-android-mock-settings";
  function loadSettings() { try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {}; } catch (e) { return {}; } }
  var saved = loadSettings();
  function setting(key) { var d = SETTINGS.find(function (s) { return s.key === key; }); return saved[key] !== undefined ? saved[key] : d.def; }
  function setSetting(key, v) { saved[key] = v; try { localStorage.setItem(STORE_KEY, JSON.stringify(saved)); } catch (e) {} applyLook(); }
  function resetSetting(key) { delete saved[key]; try { localStorage.setItem(STORE_KEY, JSON.stringify(saved)); } catch (e) {} applyLook(); }
  function isChanged(key) { var d = SETTINGS.find(function (s) { return s.key === key; }); return saved[key] !== undefined && String(saved[key]) !== String(d.def); }
  function defaultText(s) { return s.words ? (s.words[0] + " " + s.def + " " + s.words[1]).replace(" %", "%") : s.def; }

  function applyLook() {
    var t = q.get("theme") || setting("theme");
    var root = document.documentElement;
    if (t === "Light" || t === "light") root.dataset.theme = "light";
    else if (t === "Dark" || t === "dark") root.dataset.theme = "dark";
    else delete root.dataset.theme;
    root.dataset.accent = setting("accent") === "Teal" ? "teal" : "orange";
  }
  applyLook();
  window.addEventListener("storage", function (e) { if (e.key === STORE_KEY) { saved = loadSettings(); applyLook(); } });

  // ---------- scenarios ----------
  var servers = P.servers.map(function (s) { return { id: s.id, name: s.name, relay: s.relay, added_at: s.added_at, state: { snapshot: s.state.snapshot, made_at: s.state.made_at, problem: null } }; });
  var nw = servers[0];
  var clone = function (o) { return JSON.parse(JSON.stringify(o)); };
  if (scenario === "fine") {
    nw.state.snapshot = clone(nw.state.snapshot);
    var sn = nw.state.snapshot;
    sn.inbox.needs_you = []; sn.inbox.soon = []; sn.inbox.snoozed = []; sn.issues = [];
    sn.services.forEach(function (s) { s.open_issue = null; });
    sn.machines.forEach(function (m) { m.services.forEach(function (s) { if (s.environment === "production" && s.state !== "unknown") s.state = "ok"; }); if (m.id === "front-desk-pc") m.down = false; });
  }
  if (scenario === "stale") nw.state.made_at = P.at(9);
  if (scenario === "error") { nw.state.made_at = P.at(14); nw.state.problem = "The relay could not be reached (timeout)."; }
  if (scenario === "nosnap") { nw.state.snapshot = null; nw.state.made_at = null; }
  if (scenario === "leftout") { nw.state.snapshot = clone(nw.state.snapshot); nw.state.snapshot.server.left_out = ["logs", "chart"]; nw.state.snapshot.logs = {}; nw.state.snapshot.services.forEach(function (s) { s.chart = null; }); }
  if (scenario === "one") servers = [nw];
  if (scenario === "none") servers = [];

  var selectedId = (function () { try { return sessionStorage.getItem("dokkit-mock-server"); } catch (e) { return null; } })();
  function selected() { return servers.find(function (s) { return s.id === selectedId; }) || servers[0] || null; }
  function select(id) { selectedId = id; try { sessionStorage.setItem("dokkit-mock-server", id); } catch (e) {} }
  function removeServer(id) { servers = servers.filter(function (s) { return s.id !== id; }); if (selectedId === id) selectedId = null; }

  // ---------- words and times ----------
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function secondsAgo(iso) { return Math.max(0, Math.round((P.now - new Date(iso)) / 1000)); }
  function ago(iso) {
    var s = secondsAgo(iso);
    return s < 5 ? "just now" : s < 60 ? s + " seconds ago" : s < 3600 ? Math.floor(s / 60) + " min ago" : s < 86400 ? Math.floor(s / 3600) + " h ago" : Math.floor(s / 86400) + " d ago";
  }
  function short(iso) { var d = new Date(iso); return d.toLocaleDateString([], { month: "short", day: "numeric" }) + ", " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }); }
  function clock(iso) { return new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }); }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

  var LEVEL = {
    ok: { word: "OK", tone: "ok", rank: 0, icon: "check-circle" },
    degraded: { word: "Degraded", tone: "degraded", rank: 2, icon: "hourglass-medium" },
    down: { word: "Down", tone: "down", rank: 3, icon: "warning-octagon" },
    unknown: { word: "No signal yet", tone: "quiet", rank: 1, icon: "circle-dashed" },
    unwatched: { word: "Not watched", tone: "quiet", rank: 0, icon: "eye-slash" },
    soon: { word: "Coming up", tone: "soon", rank: 1, icon: "calendar" },
    snoozed: { word: "Snoozed", tone: "quiet", rank: 1, icon: "moon" }
  };
  function level(s) { return LEVEL[s] || (s ? { word: cap(s), tone: "quiet", rank: 1, icon: "circle" } : LEVEL.unknown); }

  // ---------- freshness (Screens.kt Freshness.make) ----------
  function freshness(state) {
    var lateSec = setting("late") * 60;
    if (!state.snapshot) return { text: "No snapshot yet", warn: !!state.problem, detail: state.problem, tone: state.problem ? "degraded" : "quiet" };
    if (!state.made_at) return { text: "Snapshot age unknown", warn: true, detail: state.problem, tone: "degraded" };
    var stale = secondsAgo(state.made_at) > lateSec;
    var late = stale ? "The server, its network or the relay is not delivering." : null;
    var detail = [state.problem, late].filter(Boolean).join(" ") || null;
    return { text: "Snapshot made " + ago(state.made_at), warn: stale, detail: detail, tone: stale || state.problem ? "degraded" : "quiet" };
  }
  function leftOut(snap) {
    var parts = (snap.server && snap.server.left_out) || [];
    if (!parts.length) return null;
    var names = { logs: "Log lines", issues: "Issue histories", jobs: "Jobs", services: "Service details", chart: "Charts" };
    return parts.map(function (p) { return names[p] || cap(p); }).join(", ") + " were left out of this snapshot to keep it small.";
  }

  // ---------- issues, in Calm in Ember sentences ----------
  function names(snap) { var o = {}; snap.machines.forEach(function (m) { m.services.forEach(function (s) { o[s.id] = s.name; }); }); snap.services.forEach(function (s) { o[s.id] = s.name; }); return o; }
  function issueState(i) { return i.snoozed_until && new Date(i.snoozed_until) > P.now ? "snoozed" : i.soon ? "soon" : i.state; }
  function sentence(i, snap) {
    var svcName = names(snap)[i.service] || "it";
    var where = /^disk/.test(svcName) ? svcName + " on " + i.machine : svcName + " on " + i.machine;
    var st = issueState(i);
    if (st === "snoozed") return "Snoozed until " + new Date(i.snoozed_until).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) + ". It comes back then if it is still wrong.";
    if (st === "soon") return "Nothing is broken. Plan for it when it suits you.";
    if (st === "down") return "Something is wrong with " + where + " since " + ago(i.since) + ".";
    return "Working, but not as it should: " + where + ", since " + ago(i.since) + ".";
  }
  // The phone cannot change anything, so the one next step always opens something on the phone.
  function nextStep(i) {
    if (i.kind === "job") return "See the last run";
    if (i.kind === "threshold" || i.kind === "forecast") return "Look at the disk";
    if (i.kind === "expiry") return "See the certificate";
    return "Look into it";
  }
  function flags(i) {
    var out = [];
    if (i.snoozed_until && new Date(i.snoozed_until) > P.now) out.push({ text: "Snoozed until " + short(i.snoozed_until), tone: "quiet" });
    if (i.acknowledged_at) out.push({ text: "Seen", tone: "ok" });
    if (i.alert && i.alert.status === "held") out.push({ text: "Alert held for the night" + (i.alert.until ? " until " + short(i.alert.until) : ""), tone: "soon" });
    return out;
  }
  function issueLine(i, snap) {
    var parts = [];
    var n = names(snap)[i.service]; if (n) parts.push(n);
    if (i.machine) parts.push(i.machine);
    parts.push("open " + ago(i.since).replace(" ago", ""));
    if (!i.snoozed_until && i.alert && i.alert.status === "held") parts.push("alert held for the night");
    return parts.join(" · ");
  }

  // ---------- home (Home.kt) ----------
  function isProd(env) { return env == null || env === "production"; }
  function meters(v) {
    var hot = setting("hot"), out = [];
    function m(label, val, subject) { return { label: label, subject: subject, percent: Math.round(val), hot: val > hot, fraction: Math.min(100, Math.max(0, val)) / 100 }; }
    if (v["cpu.percent"] != null) out.push(m("CPU", v["cpu.percent"]));
    if (v["memory.used_percent"] != null) out.push(m("Memory", v["memory.used_percent"]));
    var disks = Object.keys(v).filter(function (k) { return k.indexOf("disk.used_percent.") === 0; })
      .sort(function (a, b) { return v[b] - v[a] || (a < b ? -1 : 1); });
    if (disks.length) out.push(m("Disk", v[disks[0]], disks[0].replace("disk.used_percent.", "")));
    return out;
  }
  function card(m) {
    var trouble = [], fine = [], quiet = [];
    m.services.forEach(function (s) {
      if (!isProd(s.environment)) return;
      var row = { id: s.id, name: s.name, state: s.state, level: level(s.state) };
      if (s.state === "ok") fine.push(row); else if (s.state === "unknown" || !s.state) quiet.push(row); else if (s.state !== "unwatched") trouble.push(row);
    });
    var byName = function (a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; };
    trouble.sort(function (a, b) { return b.level.rank - a.level.rank || byName(a, b); }); fine.sort(byName); quiet.sort(byName);
    var hardware = m.kind === "enrolled", down = hardware && m.down === true;
    var word = !hardware ? null : down ? "Down" : "Up";
    var status = word && (word + (m.last_seen_at ? (down ? " · last reported " : " · ") + ago(m.last_seen_at) : ""));
    var counts = [fine.length ? fine.length + " fine" : null, trouble.length ? trouble.length + " in trouble" : null, quiet.length ? quiet.length + " no signal" : null].filter(Boolean).join(" · ") || "nothing watched";
    var notice = null;
    if (m.planned_downtime) notice = "Planned downtime" + (m.planned_downtime.until ? " until " + short(m.planned_downtime.until) : "");
    else if (m.schedules && m.schedules.length) notice = "Planned downtime scheduled, next " + short(m.schedules[0].next);
    var shown = setting("fineShown");
    return {
      id: m.id, name: m.name, os: m.os, hardware: hardware, down: down, inTrouble: trouble.length > 0,
      mark: down ? "down" : trouble.length ? "degraded" : "ok", word: word, status: status, meters: meters(m.vitals || {}),
      counts: counts, notice: notice, trouble: trouble, fine: fine.slice(0, shown), moreFine: fine.slice(shown),
      quietLine: quiet.length ? quiet.length + " with no signal yet: " + quiet.slice(0, 3).map(function (r) { return r.name; }).join(", ") + (quiet.length > 3 ? "…" : "") : null,
      planned: !!m.planned_downtime, lastDay: hardware ? P.lastDay(m.id) : null
    };
  }
  function home(snap) {
    var cards = snap.machines.map(card);
    var order = function (a, b) { return (b.down - a.down) || (b.inTrouble - a.inTrouble) || (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1); };
    var needs = snap.inbox.needs_you || [], soon = snap.inbox.soon || [], snoozed = snap.inbox.snoozed || [];
    var top;
    if (needs.length || soon.length) {
      var shown = needs.length ? needs : soon;
      top = { kind: "attention", urgent: needs.length > 0, title: needs.length ? needs.length + " need you" : soon.length + " coming up soon", issues: shown };
    } else {
      var hw = snap.machines.filter(function (m) { return m.kind === "enrolled"; });
      var running = 0; snap.machines.forEach(function (m) { m.services.forEach(function (s) { if (isProd(s.environment) && s.state === "ok") running++; }); });
      var things = plural(running, "thing running", "things running");
      top = { kind: "fine", headline: "Everything is fine", detail: hw.length ? hw.filter(function (m) { return !m.down; }).length + " of " + hw.length + " machines up · " + things : things };
    }
    var lede = needs.length
      ? plural(needs.length, "thing needs", "things need") + " you. " + (soon.length ? plural(soon.length, "is", "are") + " coming up" : "Nothing is coming up") + (snoozed.length ? ", and " + snoozed.length + " is snoozed." : ".")
      : soon.length ? "Nothing needs you. " + plural(soon.length, "thing is", "things are") + " coming up when it suits you."
      : "Nothing needs you right now. Dokkit keeps watching.";
    var fine = snap.inbox.fine;
    return {
      top: top, needs: needs, soon: soon, snoozedList: snoozed, snoozed: snoozed.length ? snoozed.length + " snoozed" : null, lede: lede,
      fineLine: fine && fine.services ? "Everything else is fine: " + fine.services + " services on " + fine.machines + " machines." : null,
      hardware: cards.filter(function (c) { return c.hardware; }).sort(order), groups: cards.filter(function (c) { return !c.hardware; }).sort(order)
    };
  }
  function greeting() { var h = new Date(P.now).getHours(); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"; }

  // ---------- service (Screens.kt service) ----------
  function service(snap, id) {
    var all = snap.services.concat(snap.machines.reduce(function (a, m) { return a.concat(m.services); }, []));
    var s = all.find(function (x) { return x.id === id; });
    if (!s) return null;
    var open = s.open_issue || snap.issues.find(function (i) { return i.service === id && !i.closed_at; }) || null;
    var job = snap.jobs.find(function (j) { return j.id === id; });
    var jobLines = [];
    if (job) {
      if (job.schedule) jobLines.push(["Schedule", job.schedule]);
      if (job.last_run) {
        var r = job.last_run, v = r.result || "unknown";
        if (r.exit_code != null) v += ", exit code " + r.exit_code;
        if (r.duration_ms != null) v += ", took " + Math.round(r.duration_ms / 1000) + " s";
        if (r.result === "running" && r.total) v += ", " + Math.floor(r.done / r.total * 100) + " percent";
        jobLines.push(["Last run", v]);
        if (r.started_at) jobLines.push(["Started", short(r.started_at)]);
      }
      if (job.last_good_run) jobLines.push(["Last good run", short(job.last_good_run)]);
      if (job.next_expected) jobLines.push(["Next expected", short(job.next_expected)]);
    }
    return {
      id: id, name: s.name, machine: s.machine, kind: s.kind, state: s.state, level: level(s.state), version: s.version, environment: s.environment, note: s.note,
      checks: (s.checks || []).filter(function (c) { return c.state !== "unwatched"; }).map(function (c) { return { name: c.name, kind: c.type, state: c.state, level: level(c.state), note: c.note, checked: c.checked_at ? ago(c.checked_at) : null }; }),
      issue: open, history: (open && open.history || []).map(function (e) {
        var t = cap(e.event || "event");
        if (e.event === "snoozed" && e.until) t += " until " + short(e.until);
        if (e.note) t += ": " + e.note;
        if (e.by) t += " (" + e.by + ")";
        return { when: e.at ? short(e.at) : null, ago: e.at ? ago(e.at) : null, text: t };
      }),
      chart: (s.chart && s.chart.values) || [], metric: s.chart && s.chart.metric, job: jobLines, jobRaw: job || null,
      logs: (snap.logs[id] || []).map(function (l) { return { time: l.t ? clock(l.t) : "--:--:--", level: l.level || "info", msg: l.msg || "", error: l.level === "error" }; })
    };
  }
  function machineById(snap, id) { return snap.machines.find(function (m) { return m.id === id; }); }

  // ---------- pairing (Pairing.kt messages) ----------
  var PAIR_ERRORS = {
    notacode: "This is not a Dokkit pairing code.",
    damaged: "The pairing code is damaged. Show a new one in Settings, Phones.",
    https: "The relay address in this code is not https, so the app refuses it."
  };

  return {
    P: P, scenario: scenario, servers: function () { return servers; }, selected: selected, select: select, removeServer: removeServer,
    esc: esc, ago: ago, short: short, clock: clock, plural: plural, cap: cap, level: level, LEVEL: LEVEL,
    freshness: freshness, leftOut: leftOut, home: home, card: card, service: service, machineById: machineById, greeting: greeting,
    sentence: sentence, nextStep: nextStep, flags: flags, issueLine: issueLine, issueState: issueState, names: names,
    SETTINGS: SETTINGS, setting: setting, setSetting: setSetting, resetSetting: resetSetting, isChanged: isChanged, defaultText: defaultText,
    PAIR_ERRORS: PAIR_ERRORS, host: function (url) { try { return new URL(url).host; } catch (e) { return url; } },
    reduced: matchMedia("(prefers-reduced-motion: reduce)").matches
  };
})();
