// Dokkit, product-shaped. Data is data.js and more.js, an invented estate. Chart shapes are illustrative.
var METERS = { vault: [["Mem", 88, 90], ["Data", 71, 85]], press02: [["Disk", 78, 85]], gpu01: [["GPU", 58, 90], ["Disk", 49, 85]], web01: [["Disk", 31, 85], ["Mem", 26, 90]], intake: [["Data", 17, 85]] };
var COUNT = { helpdesk: ["2", "failed runs"], loghouse: ["88,204", "failed checks"], "intake-dns": ["1", "failed lookup"] };
var tab = "now", snoozed = {}, watched = {}, dismissed = {}, picked = {}, libOpen = {}, route = {}, ui = {}, newKey = "", keyKind = "App key";
var chan = { push: "ntfy", digest: "07:00", hook: "" }, mcp = { read: true, "read-logs": false, act: false };
function blank() { return { what: "Client intake", when: WHEN[0], after: "3 failed checks", ch: "Page", who: "me" }; }
var draft = blank();
// The mark: a D with one dot, traced from the generated logo so it stays sharp at 30 px and takes the accent colour.
var LOGO = '<svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><circle cx="27.5" cy="30.5" r="5.4"></circle><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"></path></svg>';
// look = theme + dark base + accent. Saved choice wins; with none saved, keep whatever the page painted (system theme).
var look = { theme: /\bt-dark\b/.test(document.documentElement.className) ? "dark" : "light", base: "slate", accent: "teal" };
try { look = Object.assign(look, JSON.parse(localStorage.getItem("dokkit-look") || "{}")); } catch (e) {}
function applyLook() {
  document.documentElement.className = [look.theme === "dark" ? "t-dark" : "", look.base !== "neutral" ? "d-" + look.base : "", look.accent !== "violet" ? "a-" + look.accent : ""].filter(Boolean).join(" ");
  try { localStorage.setItem("dokkit-look", JSON.stringify(look)); } catch (e) {}
}
function setLook(k, v) { look[k] = v; applyLook(); render(); }

function st(s) { return watched[s.id] ? "ok" : s.state; }
function ic(name) { return '<i class="ph ph-' + name + '" aria-hidden="true"></i>'; }
function lvl(state) { return '<span class="lvl ' + (state === "ok" ? "" : state) + '"></span>'; }
function tag(text, cls) { return '<span class="tag ' + (cls || "") + '">' + text + "</span>"; }
function M(id) { return MACHINES.filter(function (m) { return m.id === id; })[0]; }
function mstate(m) { var a = m.services.map(st); return a.indexOf("warn") >= 0 ? "warn" : a.every(function (x) { return x === "none"; }) ? "none" : "ok"; }
function cnt(m, state) { return m.services.filter(function (s) { return st(s) === state; }).length; }
function hash(str) { var h = 7; for (var i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) % 9973; return h; }
// n bars; the last `bad` share of them are failures. Heights are illustrative.
function series(s, n) {
  var h = hash(s.id), bad = Math.round((s.bad || 0) / 24 * n), state = st(s), out = [];
  for (var i = 0; i < n; i++) {
    h = (h * 73 + 19) % 9973;
    if (state === "none") out.push([0.12, ""]);
    else if (i >= n - bad && s.state === "warn") out.push([0.55 + (h % 45) / 100, "w"]);
    else if (s.id === "infer" && i === n - 2) out.push([0.9, "w"]);
    else if (s.frames) out.push([0, ""]);
    else out.push([0.18 + (h % 22) / 100, "o"]);
  }
  return out;
}
function spark(s, w, hgt) {
  var n = 24, bw = 3, gap = (w - n * bw) / (n - 1);
  return '<svg class="spark" width="' + w + '" height="' + hgt + '" viewBox="0 0 ' + w + " " + hgt + '" aria-hidden="true">' + series(s, n).map(function (b, i) {
    var bh = Math.max(2, Math.round(b[0] * hgt)); return '<rect class="' + b[1] + '" x="' + (i * (bw + gap)).toFixed(1) + '" y="' + (hgt - bh) + '" width="' + bw + '" height="' + bh + '" rx="1"></rect>';
  }).join("") + "</svg>";
}
function bigChart(s, mark, label) {
  var n = 48, W = 760, H = 150, bw = 10, gap = (W - 40 - n * bw) / (n - 1), out = "";
  [0.25, 0.5, 0.75].forEach(function (g) { out += '<line x1="40" x2="' + W + '" y1="' + (H * g) + '" y2="' + (H * g) + '"></line>'; });
  series(s, n).forEach(function (b, i) { var bh = Math.max(3, b[0] * (H - 10)); out += '<rect class="' + b[1] + '" x="' + (40 + i * (bw + gap)).toFixed(1) + '" y="' + (H - bh).toFixed(1) + '" width="' + bw + '" height="' + bh.toFixed(1) + '" rx="2"></rect>'; });
  ["Sep 12", "Sep 18", "Sep 24", "Sep 30", "Oct 5"].forEach(function (d, i) { out += '<text x="' + (40 + i * (W - 80) / 4) + '" y="' + (H + 16) + '">' + d + "</text>"; });
  if (mark) { var mx = 40 + (n - Math.round((s.bad || 0) / 24 * n)) * (bw + gap) - gap / 2; out += '<line class="mk" x1="' + mx.toFixed(1) + '" x2="' + mx.toFixed(1) + '" y1="0" y2="' + H + '"></line><text class="mk" text-anchor="end" x="' + (mx - 6).toFixed(1) + '" y="11">' + mark + "</text>"; }
  return '<svg viewBox="0 0 ' + W + " " + (H + 22) + '" role="img" aria-label="' + (label || "Checks") + ' over the last 24 days">' + out + "</svg>";
}
function vitals(m) { return (METERS[m.id] || []).map(function (v) { var hot = v[1] >= v[2] - 5; return '<span class="vit' + (hot ? " hot" : "") + '">' + v[0] + ' <u style="--v:' + v[1] + '%"><i></i></u> ' + v[1] + "%</span>"; }).join("") + (m.id === "press01" ? '<span class="vit">512 GB free</span>' : ""); }
function seg3(m) { var t = m.services.length; return '<span class="seg3"><i class="w" style="width:' + (cnt(m, "warn") / t * 100) + '%"></i><i class="o" style="width:' + (cnt(m, "ok") / t * 100) + '%"></i><i class="n" style="width:' + (cnt(m, "none") / t * 100) + '%"></i></span>'; }
function live() { return NOW.filter(function (n, i) { return !snoozed[i]; }); }
function found() { var out = []; MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (st(s) === "none" && !dismissed[s.id]) out.push([m, s]); }); }); return out; }
function svc(id) { var r; MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (s.id === id) r = [m, s]; }); }); return r; }
function offers() { return TASKS.filter(function (t) { return !t.ok; }); }
function empty(icon, text) { return '<div class="empty">' + ic(icon) + text + "</div>"; }
function sel(list, val, js, label, cls) { return '<select class="inp ' + (cls || "") + '" aria-label="' + label + '" onchange="' + js + '">' + list.map(function (o) { return "<option" + (o === val ? " selected" : "") + ">" + o + "</option>"; }).join("") + "</select>"; }
function tbl(cols, heads, rows) {
  return '<div class="lh" style="grid-template-columns:' + cols + '">' + heads.map(function (h) { return "<span>" + h + "</span>"; }).join("") + "</div>" +
    rows.map(function (r) { return '<div class="li slim" style="grid-template-columns:' + cols + '">' + r.map(function (c, i) { return '<span class="' + (i ? "mono mute" : "") + '">' + c + "</span>"; }).join("") + "</div>"; }).join("");
}
function took(s) { return s < 60 ? s + " s" : Math.floor(s / 60) + " min " + (s % 60) + " s"; }
function result(code) { return code ? tag("Failed", "warn") : tag("Finished", "ok"); }
function runRow(cols, cells, out) { return '<details class="run"><summary class="li slim" style="grid-template-columns:' + cols + ' 16px">' + cells + ic("caret-right") + '</summary><pre class="logbox">' + out + "</pre></details>"; }
function runsOf(s) { var j = JOBS[s.id]; return j.at.map(function (a, i) { return { at: a, code: i === j.fail ? 1 : 0, dur: j.dur + hash(a + s.id) % (1 + (j.dur >> 2)) }; }); }
function lastGood(s) { var r = runsOf(s).filter(function (x) { return !x.code; })[0]; return r ? r.at : "None seen"; }
function rt(id) { return route[id] || (route[id] = { down: "Page", deg: "Push", restart: false }); }

// ---------- shell ----------
function side(active) {
  var groups = [["Watch", [["inbox", "tray", "Inbox", live().length], ["all", "squares-four", "Everything"], ["jobs", "clock-countdown", "Jobs"], ["logs", "scroll", "Logs"], ["errors", "bug", "Errors"]]],
    ["Changes", [["deploys", "rocket-launch", "Deploys"], ["versions", "git-branch", "Versions"]]],
    ["Manage", [["found", "binoculars", "Found", found().length + offers().length], ["tasks", "terminal-window", "Tasks"], ["alerts", "bell", "Alerts"], ["settings", "gear", "Settings"]]]];
  return '<a class="org" href="#/inbox"><span class="mark">' + LOGO + '</span><span><b>Dokkit</b><small>' + ORG + '</small></span>' + ic("caret-up-down") + "</a>" +
    groups.map(function (g) { return "<h3>" + g[0] + "</h3>" + g[1].map(function (x) { return '<a class="nav' + (x[0] === active ? " on" : "") + '" href="#/' + x[0] + '">' + ic(x[1]) + x[2] + (x[3] ? '<span class="n">' + x[3] + "</span>" : "") + "</a>"; }).join(""); }).join("") +
    "<h3>Machines</h3>" + MACHINES.map(function (m) { var w = cnt(m, "warn"), s = mstate(m); return '<a class="nav' + (active === "m:" + m.id ? " on" : "") + '" href="#/m/' + m.id + '"><span class="dot ' + (s === "ok" ? "" : s) + '"></span>' + m.name + (w ? '<span class="q">' + w + "</span>" : "") + "</a>"; }).join("") +
    '<span class="grow"></span><div class="me"><span class="av">' + ME.slice(0, 2).toUpperCase() + "</span><span>" + ME + '</span></div>';
}
function themeBtn() { var dark = look.theme === "dark"; return '<button class="btn ghost" type="button" onclick="setTheme(\'' + (dark ? "light" : "dark") + '\')" aria-label="Switch theme">' + ic(dark ? "sun" : "moon") + "</button>"; }
function head(title, end) { return '<div class="head"><h1>' + title + '</h1><div class="end">' + (end || "") + themeBtn() + "</div></div>"; }
function filters(ph) {
  return '<div class="filters"><button class="btn" type="button">' + ic("hard-drives") + "All machines " + ic("caret-down") + '</button><button class="btn" type="button">' + ic("calendar-blank") + "Last 24 days " + ic("caret-down") + "</button>" +
    '<label class="search">' + ic("magnifying-glass") + '<input type="search" placeholder="' + ph + '" aria-label="Search"><kbd>/</kbd></label></div>';
}

// ---------- views ----------
function viewInbox() {
  var f = found(), tabs = [["now", "Needs you", live().length], ["soon", "Soon", SOON.length], ["found", "Not watched", f.length]], rows = "";
  if (tab === "now") {
    rows = NOW.map(function (n, i) {
      if (snoozed[i]) return "";
      var m = M(n.m), s = m.services.filter(function (x) { return x.id === n.s; })[0], c = COUNT[s.id] || ["", ""];
      return '<div class="li hov cols-inbox"><input class="chk" type="checkbox" aria-label="Select"><div style="min-width:0"><a class="ti" href="#/s/' + m.id + "/" + s.id + '">' + lvl("warn") + "<span>" + n.title + '</span></a><div class="sub">' + (s.lead || s.note) + '</div><div class="meta">' + tag(n.kind, "warn") + '<span class="mono">DOK-' + (i + 1) + "</span><span>" + n.since + "</span></div></div>" +
        spark(s, 118, 28) + '<div class="num">' + c[0] + "<small>" + c[1] + "</small></div>" + tag(m.name) +
        '<div style="display:flex; gap:6px; justify-content:flex-end"><a class="btn" href="#/s/' + m.id + "/" + s.id + '">Open</a><button class="btn ghost" type="button" onclick="snooze(' + i + ')" aria-label="Snooze">' + ic("clock") + "</button></div></div>";
    }).join("") || '<div class="empty">' + ic("check-circle") + "Nothing needs you. You will hear from Dokkit when something does.</div>";
  } else if (tab === "soon") {
    rows = SOON.map(function (x) { return '<a class="li cols-inbox" href="#/m/' + x[2] + '"><span></span><div><div class="ti">' + lvl("warn") + "<span>" + x[0] + '</span></div><div class="meta">' + tag("Threshold") + "</div></div><span></span>" + '<div class="num">' + x[1] + "</div>" + tag(M(x[2]).name) + "<span></span></a>"; }).join("");
  } else {
    rows = f.map(function (p) { return '<div class="li hov cols-inbox"><span></span><div style="min-width:0"><a class="ti" href="#/s/' + p[0].id + "/" + p[1].id + '">' + lvl("none") + '<span class="mono" style="font-size:13.5px">' + p[1].name + '</span></a><div class="sub">' + p[1].note + "</div></div>" + spark(p[1], 118, 28) + "<span></span>" + tag(p[0].name) + '<div style="display:flex; justify-content:flex-end"><button class="btn" type="button" onclick="watch(\'' + p[1].id + "')\">" + ic("plus") + "Add a check</button></div></div>"; }).join("") || '<div class="empty">' + ic("check-circle") + "Everything Dokkit has found is being watched.</div>";
    rows += '<a class="li slim" href="#/found" style="grid-template-columns: minmax(0,1fr) auto"><span class="ti">' + ic("binoculars") + "<span>Review what was found and the tasks waiting for you</span></span>" + ic("caret-right") + "</a>";
  }
  var errs = LOGS.filter(function (l) { return l[1] === "error"; });
  return head("Inbox", '<button class="btn primary" type="button">' + ic("plus") + "New check</button>") + filters("Search issues, services, machines") +
    '<div class="tabs">' + tabs.map(function (t) { return '<button type="button" class="' + (tab === t[0] ? "on" : "") + '" onclick="setTab(\'' + t[0] + "')\">" + t[1] + '<span class="cnt">' + t[2] + "</span></button>"; }).join("") + "</div>" +
    '<div class="body rail"><div class="card"><div class="lh cols-inbox"><span></span><span>Issue</span><span>Last 24 days</span><span>Count</span><span>Machine</span><span></span></div>' + rows + "</div>" +
    '<div style="display:grid; gap:18px"><div class="card"><h2>Estate<span class="end">' + MACHINES.reduce(function (a, m) { return a + m.services.length; }, 0) + " things</span></h2>" +
    MACHINES.map(function (m) { var w = cnt(m, "warn"), n = cnt(m, "none"); return '<a class="est" href="#/m/' + m.id + '"><b>' + lvl(mstate(m)) + m.name + '</b><span class="mono mute">' + (w ? w + " need a look" : n === m.services.length ? "not watched" : "fine") + "</span>" + seg3(m) + "</a>"; }).join("") + "</div>" +
    '<div class="card"><h2>Errors today<span class="end">' + errs.length + "</span></h2>" + errs.map(function (l) { return '<div class="est" style="grid-template-columns: auto minmax(0,1fr)"><span class="mono mute">' + l[0] + '</span><span class="sub" style="color:var(--ink)">' + l[3] + "</span></div>"; }).join("") + "</div></div></div>";
}
function svcLine(m, s) {
  var state = st(s), kind = /^(cron|timer|task|quarterly)$/.test(s.ver) ? s.ver : "service";
  return '<a class="li slim cols-all" href="#/s/' + m.id + "/" + s.id + '"><div style="min-width:0"><div class="ti">' + lvl(state) + "<span>" + s.name + '</span></div></div><span class="mono mute">' + (kind === "service" ? s.ver || "none" : "") + '</span><span class="mono mute">' + (s.where || "") + '</span><span class="mute">' + kind + "</span>" + spark(s, 118, 22) +
    (state === "warn" ? tag(s.note, "warn") : state === "none" ? tag("Not watched") : tag(s.note || "Fine", s.note ? "" : "ok")) + "</a>";
}
function group(m) {
  var w = cnt(m, "warn"), n = cnt(m, "none");
  return '<div class="grp"><a href="#/m/' + m.id + '" style="display:flex; align-items:center; gap:8px">' + lvl(mstate(m)) + m.name + '</a><span class="mute" style="font-weight:400">' + m.kind + '</span><span class="end">' + vitals(m) + (w ? tag(w + " need a look", "warn") : "") + (n ? tag(n + " not watched") : "") + tag(cnt(m, "ok") + " fine", "ok") + "</span></div>" + m.services.map(function (s) { return svcLine(m, s); }).join("");
}
function viewAll(only) {
  var ms = only ? [only] : MACHINES;
  return (only ? '<div class="crumb"><a href="#/all">Everything</a>' + ic("caret-right") + "<span>" + only.name + "</span></div>" : "") + head(only ? only.name : "Everything", '<button class="btn primary" type="button">' + ic("plus") + "New check</button>") + filters("Filter by name, version or port") +
    '<div class="body"><div class="card"><div class="lh cols-all"><span>Service</span><span>Version</span><span>Listens</span><span>Kind</span><span>Last 24 days</span><span>State</span></div>' + ms.map(group).join("") + "</div>" + (only && only.id === "pcs" ? pcCard() : "") + "</div>";
}
function pcCard() {
  var apps = M("pcs").services;
  return '<div class="card"><h2>PCs<span class="end">' + PCN.length + " seen this week, " + (PCN.length - Object.keys(QUIET).length) + ' reporting now</span></h2><div class="lh cols-pc"><span>PC</span><span>Last seen</span><span>Apps on it</span><span>Errors today</span></div>' +
    (PCN.map(function (n) {
      var name = PC + n, errs = LOGS.filter(function (l) { return l[1] === "error" && l[2] === name; }).length;
      return '<div class="li slim hov cols-pc"><div class="ti">' + lvl("ok") + '<span class="mono" style="font-size:13.5px">' + name + '</span></div><span class="mute">' + (QUIET[n] || "Oct 5 17:" + (40 + hash(name) % 7)) + '</span><div class="meta" style="margin:0">' + tag(apps[0].name) +
        apps.map(function (a) { var v = ON[a.id] && ON[a.id][n]; return v ? tag(a.name + " " + v, (HELD[a.id] || {})[n] ? "brand" : v !== a.ver ? "warn" : "") : ""; }).join("") + "</div>" + (errs ? tag(errs + " errors", "warn") : '<span class="mute">None</span>') + "</div>";
    }).join("") || empty("desktop", "No PC has reported this week.")) + "</div>";
}
function viewService(m, s) {
  var state = st(s), issue = NOW.filter(function (n) { return n.s === s.id; })[0], title = issue && state === "warn" ? issue.title : s.name;
  var logs = LOGS.filter(function (l) { return l[2] === m.id; });
  var facts = s.facts || [["State", s.note || (state === "ok" ? "Fine" : "No signal")]], job = JOBS[s.id], r = rt(s.id), deps = DEPLOYS.filter(function (d) { return d[1] === s.id; });
  var runs = job ? runsOf(s) : [], rc = "minmax(0,1fr) 110px 90px 100px";
  return '<div class="crumb"><a href="#/all">Everything</a>' + ic("caret-right") + '<a href="#/m/' + m.id + '">' + m.name + "</a>" + ic("caret-right") + "<span>" + s.name + "</span></div>" +
    head(lvl(state) + " " + title, (state === "warn" && s.act ? '<button class="btn primary" type="button">' + s.act + "</button>" : state === "none" ? '<button class="btn primary" type="button" onclick="watch(\'' + s.id + "')\">" + ic("plus") + "Add a check</button>" : "") + '<button class="btn" type="button">' + ic("clock") + 'Snooze</button><a class="btn" href="#/logs">' + ic("scroll") + "Logs</a>") +
    '<div class="filters" style="padding-top:10px">' + (state === "warn" ? tag(s.note, "warn") : state === "none" ? tag("Not watched") : tag("Fine", "ok")) + tag(m.name) + (s.ver ? tag(s.ver) : "") + (s.where ? tag(s.where) : "") + (issue ? '<span class="mute" style="font-size:12.5px">' + issue.since + "</span>" : "") + "</div>" +
    '<div class="body rail"><div style="display:grid; gap:18px; min-width:0">' +
    (s.id === "relay" ? '<div class="card stats">' + s.facts.slice(0, 4).map(function (f) { return '<div class="stat"><b>' + f[1] + "</b><span>" + f[0] + "</span></div>"; }).join("") + "</div>" : "") +
    (job ? '<div class="card"><h2>Runs<span class="end">newest first, illustrative</span></h2>' + (runs.length ? '<div class="lh" style="grid-template-columns:' + rc + ' 16px"><span>Started</span><span>Took</span><span>Exit code</span><span>Result</span><span></span></div>' +
      runs.map(function (x) { return runRow(rc, "<span>" + x.at + '</span><span class="mono mute">' + took(x.dur) + '</span><span class="mono mute">' + x.code + "</span>" + result(x.code), x.code ? job.tail.split("\n")[0] + "\nstopped with exit code 1" : job.tail); }).join("") : empty("clock-countdown", "No run has been seen yet.")) + "</div>"
      : '<div class="card"><h2>Checks<span class="end">last 24 days, illustrative</span></h2><div class="chart">' + bigChart(s) + "</div></div>") + statCards(s) +
    '<div class="card"><h2>What Dokkit knows</h2>' + (s.lead ? '<p class="lead">' + s.lead + "</p>" : "") + '<dl class="kv">' + facts.map(function (f) { return "<dt>" + f[0] + "</dt><dd>" + (f[2] ? lvl(f[2]) + " " : "") + f[1] + "</dd>"; }).join("") + "</dl></div>" +
    '<div class="card"><h2>Latest from ' + m.name + '</h2><pre class="logbox">' + (logs.length ? logs.map(function (l) { return l[0] + "  " + (l[1] === "error" ? "<b>error</b>" : "<em>info </em>") + "  " + l[3]; }).join("\n") : "No log lines from this machine today.") + "</pre></div></div>" +
    '<div style="display:grid; gap:18px"><div class="card"><h2>Details</h2><dl class="kv"><dt>Machine</dt><dd>' + m.name + "</dd><dt>Version</dt><dd>" + (s.ver || "None reported") + "</dd><dt>Listens on</dt><dd>" + (s.where || "Nothing") + "</dd><dt>Checked</dt><dd>" + (state === "none" ? "Never" : "Every 30 s") + "</dd>" + (job ? "<dt>Schedule</dt><dd>" + job.sch + "</dd><dt>Last good run</dt><dd>" + lastGood(s) + "</dd><dt>Next expected</dt><dd>" + job.next + "</dd>" : "") + "</dl></div>" +
    '<div class="card"><h2>Recent deploys<span class="end">' + (deps.length || "") + "</span></h2>" + (deps.map(function (d) { return '<div class="est"><b class="mono">' + d[2] + " " + ic("arrow-right") + " " + d[3] + "</b>" + (d[7] ? tag("Failed", "warn") : "<span></span>") + '<span class="mute">' + d[5] + " on " + d[4] + '</span><span class="mute">' + (d[6] === "ci" ? "Marked by CI" : "Noticed by Dokkit") + "</span></div>"; }).join("") || empty("rocket-launch", "No deploy has been seen for this.")) + "</div>" +
    '<div class="card"><h2>Who hears about it</h2><dl class="kv"><dt>If it stops</dt><dd>' + sel(CHANNELS, r.down, "rt('" + s.id + "').down=this.value", "If it stops", "sm") + " me</dd><dt>If it degrades</dt><dd>" + sel(CHANNELS, r.deg, "rt('" + s.id + "').deg=this.value", "If it degrades", "sm") + " me</dd><dt>Restart first</dt><dd><input class=\"switch\" type=\"checkbox\"" + (r.restart ? " checked" : "") + " onchange=\"rt('" + s.id + "').restart=this.checked\" aria-label=\"Restart first\"></dd><dt>Anyone else</dt><dd>Nobody</dd></dl></div></div></div>";
}
function viewJobs() {
  var out = [];
  MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (JOBS[s.id]) out.push([m, s]); }); });
  return head("Jobs") + filters("Filter jobs") + '<div class="body"><div class="card"><div class="lh cols-jobs"><span>Job</span><span>Machine</span><span>Schedule</span><span>Last good run</span><span>Last 24 days</span><span>Last run</span></div>' +
    out.map(function (j) { var s = j[1]; return '<a class="li slim cols-jobs" href="#/s/' + j[0].id + "/" + s.id + '"><div class="ti">' + lvl(st(s)) + "<span>" + s.name + '</span></div><span class="mute">' + j[0].name + '</span><span class="mute">' + JOBS[s.id].sch + '</span><span class="mute">' + lastGood(s) + "</span>" + spark(s, 118, 22) + tag(st(s) === "none" ? "No signal yet" : s.note) + "</a>"; }).join("") + "</div></div>";
}
function viewLogs() {
  return head("Logs") + filters("Search log lines") + '<div class="body"><div class="card"><div class="lh" style="grid-template-columns: 60px 70px 120px minmax(0,1fr)"><span>Time</span><span>Level</span><span>Source</span><span>Message</span></div>' +
    LOGS.map(function (l) { return '<div class="li slim" style="grid-template-columns: 60px 70px 120px minmax(0,1fr)"><span class="mono mute">' + l[0] + "</span>" + tag(l[1], l[1] === "error" ? "warn" : "") + '<span class="mono mute">' + l[2] + "</span><span>" + l[3] + "</span></div>"; }).join("") + "</div></div>";
}
function ownTop(e) { var f = e.frames.filter(function (x) { return x[3]; }).pop(); return f[0] + " in " + f[1] + ", line " + f[2]; }
function viewErrors() {
  var off = [svc("relay"), svc("intake-portal")];
  return head("Errors", '<button class="btn" type="button" onclick="flip(\'addr\')">' + ic("link") + (ui.addr ? "Hide the address" : "Show the address to set") + "</button>") + filters("Search error types and services") + '<div class="body">' +
    (ui.addr ? '<div class="card"><h2>The address to set<span class="end">one app key for each service</span></h2><dl class="kv">' + off.map(function (p, i) { return "<dt>" + p[1].name + '</dt><dd class="mono" style="overflow-wrap:anywhere">https://' + ["dka_7c2f9a41b6e0d385c0a2", "dka_e05b3d7714fa29c68b1e"][i] + "@" + HOST + "/" + p[1].id + "</dd>"; }).join("") + '</dl><p class="lead">Give each app its address as SENTRY_DSN and restart it. The key inside can only send. It can read nothing, and it can be revoked in Settings.</p></div>' : "") +
    '<div class="card"><div class="lh cols-inbox"><span></span><span>Error</span><span>Last 24 days</span><span>Count</span><span>Machine</span><span>Last seen</span></div>' +
    (ERRS.map(function (e) { return '<a class="li cols-inbox" href="#/e/' + e.id + '"><span></span><div style="min-width:0"><div class="ti">' + lvl("warn") + '<span class="mono" style="font-size:13.5px">' + e.type + '</span></div><div class="sub mono">' + ownTop(e) + '</div><div class="meta">' + tag(svc(e.s)[1].name) + tag(e.rel) + (e.handled ? "" : tag("Not caught", "warn")) + "</div></div>" + spark(e, 118, 28) + '<div class="num">' + e.n + "<small>reports</small></div>" + tag(e.pcs.length > 1 ? e.pcs.length + " PCs" : e.pcs[0]) + '<span class="mute">' + e.last + "</span></a>"; }).join("") || empty("check-circle", "No errors in the last 24 days.")) + "</div>" +
    '<div class="card"><div class="empty">' + ic("bug") + '<b style="color:var(--ink)">Error reporting is built in and switched off</b><br>' + off[0][1].name + " and " + off[1][1].name +' will send crashes here once they are given Dokkit\'s address.</div></div></div>';
}
function viewError(e) {
  var p = svc(e.s), lib = [], out = "", open = libOpen[e.id];
  function row(f) { return '<div class="li slim fr ' + (f[3] ? "own" : "lib") + '"><span class="mono">' + f[0] + '</span><span class="mono mute">' + f[1] + '</span><span class="mono mute">line ' + f[2] + "</span></div>"; }
  function flush() { if (lib.length) out += '<button type="button" class="li slim more" aria-expanded="' + !!open + '" onclick="toggleLib(\'' + e.id + '\')"><span class="ti">' + ic(open ? "caret-down" : "caret-right") + "<span>" + lib.length + " library frame" + (lib.length > 1 ? "s" : "") + "</span></span></button>" + (open ? lib.map(row).join("") : ""); lib = []; }
  e.frames.slice().reverse().forEach(function (f) { if (f[3]) { flush(); out += row(f); } else lib.push(f); });
  flush();
  return '<div class="crumb"><a href="#/errors">Errors</a>' + ic("caret-right") + "<span>" + e.type + "</span></div>" +
    head(lvl("warn") + " " + e.type, '<button class="btn" type="button">' + ic("clock") + 'Snooze</button><a class="btn" href="#/logs">' + ic("scroll") + "Logs</a>") +
    '<div class="filters" style="padding-top:10px">' + tag(e.n + " reports", "warn") + tag(p[1].name) + tag(e.rel) + (e.handled ? tag("Caught by the app") : tag("Not caught", "warn")) + '<span class="mute" style="font-size:12.5px">since ' + e.first + "</span></div>" +
    '<div class="body rail"><div style="display:grid; gap:18px; min-width:0">' +
    '<div class="card"><h2>Reports<span class="end">last 24 days, illustrative</span></h2><div class="chart">' + bigChart(e, e.dep, "Reports") + "</div></div>" +
    '<div class="card"><h2>Stack<span class="end">the app\'s own code is marked</span></h2>' + out + '<div class="foot">Dokkit does not collect the message text of an error unless a service is set to keep it.</div></div></div>' +
    '<div class="card"><h2>Details</h2><dl class="kv"><dt>Service</dt><dd><a href="#/s/' + p[0].id + "/" + p[1].id + '">' + p[1].name + "</a></dd><dt>Release</dt><dd>" + e.rel + "</dd><dt>First seen</dt><dd>" + e.first + "</dd><dt>Last seen</dt><dd>" + e.last + "</dd><dt>Machines</dt><dd>" + e.pcs.join(", ") + "</dd><dt>Handled</dt><dd>" + (e.handled ? "Yes, the app caught it" : "No, the app did not catch it") + '</dd><dt>Tags</dt><dd style="display:flex; flex-wrap:wrap; gap:6px">' + e.tags.map(function (t) { return tag(t[0] + ": " + t[1]); }).join("") + "</dd></dl></div></div>";
}
function viewFound() {
  var f = found(), dis = f.some(function (p) { return picked[p[1].id]; }) ? "" : " disabled", off = offers();
  var scan = MACHINES.map(function (m) {
    var mine = f.filter(function (p) { return p[0] === m; });
    return mine.length ? '<div class="grp">' + lvl(mstate(m)) + m.name + '<span class="mute" style="font-weight:400">' + m.kind + '</span><span class="end">' + tag(mine.length + " found") + "</span></div>" + mine.map(function (p) {
      var s = p[1];
      return '<label class="li slim hov cols-found"><input class="chk" type="checkbox"' + (picked[s.id] ? " checked" : "") + ' onchange="pick(\'' + s.id + '\')" aria-label="Select ' + s.name + '"><div class="ti">' + lvl("none") + '<span class="mono" style="font-size:13.5px">' + s.name + '</span></div><span class="mute">' + (HOW[s.id] || "Dependency") + '</span><span class="sub">' + s.note + '</span><a class="btn ghost" href="#/s/' + m.id + "/" + s.id + '">Open</a></label>';
    }).join("") : "";
  }).join("");
  return head("Found, waiting for you") + '<div class="body">' +
    '<div class="card"><h2>What a scan found<span class="end"><button class="btn sm primary" type="button"' + dis + ' onclick="sweep(watched)">' + ic("plus") + 'Watch selected</button><button class="btn sm" type="button"' + dis + ' onclick="sweep(dismissed)">Dismiss</button></span></h2>' +
    (scan ? '<div class="lh cols-found"><span></span><span>Found</span><span>How it was found</span><span>What Dokkit saw</span><span></span></div>' + scan : empty("check-circle", "Nothing found is waiting. Everything is either watched or dismissed.")) + "</div>" +
    '<div class="card"><h2>Tasks waiting to be accepted<span class="end">' + off.length + "</span></h2>" +
    (off.map(function (t) { return '<div class="li hov" style="grid-template-columns: minmax(0,1fr) auto"><div style="min-width:0"><div class="ti">' + ic("terminal-window") + "<span>" + t.id + '</span></div><code class="cmd">' + t.cmd + '</code><div class="meta">' + tag(t.m) + '<span>Would run as <span class="mono">' + t.acct + '</span></span></div></div><div style="display:flex; gap:6px"><button class="btn primary" type="button" onclick="acceptTask(\'' + t.id + '\')">Accept</button><button class="btn" type="button" onclick="dismissTask(\'' + t.id + '\')">Dismiss</button></div></div>'; }).join("") || empty("check-circle", "No task is waiting to be accepted.")) +
    '<div class="foot">Nothing here is watched or run until you accept it. A task runs only the command shown, on its own machine.</div></div></div>';
}
function vt(first, cols, rows) {
  return '<div class="scroll"><table class="vt"><thead><tr><th>' + first + "</th>" + cols.map(function (c) { return "<th>" + c[1] + "</th>"; }).join("") + "</tr></thead><tbody>" + rows.map(function (r) {
    return "<tr><th>" + r[0] + "</th>" + cols.map(function (c) { var v = r[2][c[0]]; return "<td>" + (!v ? "" : r[3] && r[3][c[0]] ? tag(ic("push-pin") + v, "brand") : v !== r[1] ? tag(v, "warn") : v) + "</td>"; }).join("") + "</tr>";
  }).join("") + "</tbody></table></div>";
}
function viewVersions() {
  var hosts = MACHINES.filter(function (m) { return m.id !== "pcs" && m.id !== "depends"; }), rows = [["Dokkit", SELFV.newest, SELFV.on]], apps = M("pcs").services.filter(function (s) { return ON[s.id]; });
  hosts.forEach(function (m) { m.services.forEach(function (s) { var on = {}; if (s.ver && !JOBS[s.id]) { on[m.id] = s.ver; rows.push(['<a href="#/s/' + m.id + "/" + s.id + '">' + s.name + "</a>", s.ver, on]); } }); });
  var pcs = PCN.filter(function (n) { return apps.some(function (s) { return ON[s.id][n]; }); }), legend = '<div class="foot">' + tag("Behind the newest", "warn") + tag(ic("push-pin") + "Held on purpose", "brand") + "</div>";
  return head("Versions") + '<div class="body">' +
    '<div class="card"><h2>Services<span class="end">which version is on which machine</span></h2>' + vt("Service", hosts.map(function (m) { return [m.id, m.name]; }), rows) + legend + "</div>" +
    '<div class="card"><h2>Desktop apps<span class="end">' + M("pcs").services[0].name + ' is on every PC and is left out</span></h2>' + (apps.length ? vt("App", pcs.map(function (n) { return [n, PC + n]; }), apps.map(function (s) { return ['<a href="#/s/pcs/' + s.id + '">' + s.name + "</a>", s.ver, ON[s.id], HELD[s.id]]; })) + legend : empty("desktop", "No desktop app has reported a version yet.")) + "</div></div>";
}
function viewDeploys() {
  var c = "minmax(0,1.2fr) minmax(0,1.2fr) 120px 110px 140px";
  return head("Deploys") + filters("Filter by service, version or machine") + '<div class="body"><div class="card"><div class="lh" style="grid-template-columns:' + c + '"><span>Service</span><span>Version</span><span>Machine</span><span>When</span><span>How it was seen</span></div>' +
    (DEPLOYS.map(function (d) { return '<a class="li slim" style="grid-template-columns:' + c + '" href="#/s/' + d[0] + "/" + d[1] + '"><div class="ti">' + ic("rocket-launch") + "<span>" + svc(d[1])[1].name + '</span></div><span class="mono" style="display:flex; flex-wrap:wrap; align-items:center; gap:6px">' + d[2] + ic("arrow-right") + d[3] + (d[7] ? tag("Failed", "warn") : "") + "</span>" + tag(d[4]) + '<span class="mute">' + d[5] + "</span>" + (d[6] === "ci" ? tag("Marked by CI", "brand") : tag("Noticed by Dokkit")) + "</a>"; }).join("") || empty("rocket-launch", "No deploy has been seen yet.")) + "</div></div>";
}
function task(id) { return TASKS.filter(function (t) { return t.id === id; })[0]; }
function viewTasks() {
  var mine = TASKS.filter(function (t) { return t.ok; }), n = offers().length, c = "minmax(0,1fr) 110px 120px 90px 84px", rc = "minmax(0,1fr) 110px 120px 90px 80px 90px";
  return head("Tasks", n ? '<a class="btn" href="#/found">' + ic("binoculars") + n + " waiting to be accepted</a>" : "") + '<div class="body">' +
    '<div class="card"><div class="lh" style="grid-template-columns:' + c + '"><span>Task</span><span>Machine</span><span>Last run</span><span>Result</span><span></span></div>' +
    (mine.map(function (t) {
      var last = RUNS.filter(function (r) { return r.t === t.id; })[0];
      return '<div class="li hov" style="grid-template-columns:' + c + '"><div style="min-width:0"><div class="ti">' + ic("terminal-window") + "<span>" + t.id + '</span></div><code class="cmd">' + t.cmd + "</code></div>" + tag(t.m) + '<span class="mute">' + (last ? last.at : "Never run") + "</span>" + (last ? result(last.code) : "<span></span>") + '<button class="btn" type="button" onclick="runTask(\'' + t.id + '\')">' + ic("play") + "Run</button></div>";
    }).join("") || empty("terminal-window", "No task has been accepted yet. Tasks that are waiting are under Found.")) + "</div>" +
    '<div class="card"><h2>Recent runs<span class="end">' + RUNS.length + "</span></h2>" + (RUNS.length ? '<div class="lh" style="grid-template-columns:' + rc + ' 16px"><span>Task</span><span>Machine</span><span>Started</span><span>Took</span><span>Exit code</span><span>Result</span><span></span></div>' +
      RUNS.map(function (r) { var t = task(r.t); return runRow(rc, '<div class="ti"><span>' + t.id + "</span></div>" + tag(t.m) + '<span class="mute">' + r.at + '</span><span class="mono mute">' + took(r.dur) + '</span><span class="mono mute">' + r.code + "</span>" + result(r.code), t.out); }).join("") : empty("clock-countdown", "No task has run yet.")) + "</div></div>";
}
function chTag(ch) { return ch === "Page" ? tag("Page, PagerDuty", "brand") : ch === "Digest" ? tag("Morning digest") : ch === "Push" ? tag("Push, " + chan.push) : tag(ch); }
function viewAlerts() {
  var c = "minmax(0,1fr) 190px 140px 90px 50px", names = MACHINES.map(function (m) { return m.name; });
  MACHINES.forEach(function (m) { m.services.forEach(function (s) { names.push(s.name); }); });
  return head("Alerts", '<button class="btn primary" type="button" onclick="flip(\'edit\')">' + ic("plus") + "New rule</button>") + '<div class="body">' +
    (ui.edit ? '<div class="card"><h2>New rule</h2><div class="form"><label>What it watches' + sel(names, draft.what, "draft.what=this.value", "What it watches") + "</label><label>When it" + sel(WHEN, draft.when, "draft.when=this.value", "When") + '</label><label>How long before it counts<input class="inp" value="' + draft.after + '" onchange="draft.after=this.value"></label><label>Channel' + sel(CHANNELS, draft.ch, "draft.ch=this.value", "Channel") + "</label><label>Who" + sel(["me", "All owners"], draft.who, "draft.who=this.value", "Who") + '</label></div><div class="foot"><button class="btn primary" type="button" onclick="saveRule()">Save rule</button><button class="btn" type="button" onclick="flip(\'edit\')">Cancel</button></div></div>' : "") +
    '<div class="card"><div class="lh" style="grid-template-columns:' + c + '"><span>Rule</span><span>Reaches you by</span><span>Counts after</span><span>Who</span><span>On</span></div>' +
    (RULES.map(function (w, i) { return '<div class="li slim" style="grid-template-columns:' + c + '"><div class="ti">' + ic("bell") + "<span>" + w.name + "</span></div>" + chTag(w.ch) + '<span class="mute">' + w.after + '</span><span class="mute">' + w.who + '</span><input class="switch" type="checkbox"' + (w.on ? " checked" : "") + ' onchange="RULES[' + i + '].on=this.checked" aria-label="Rule on"></div>'; }).join("") || empty("bell", "No rules yet. Dokkit will stay quiet until you make one.")) + "</div>" +
    '<div class="card"><h2>Suggestions<span class="end">' + (SUGG.length || "") + "</span></h2>" +
    (SUGG.map(function (x, i) { return '<div class="li hov" style="grid-template-columns: minmax(0,1fr) auto"><div style="display:flex; gap:10px; min-width:0">' + ic("lightbulb") + "<span>" + x.text + '</span></div><div style="display:flex; gap:6px"><button class="btn primary" type="button" onclick="settle(' + i + ', 1)">Accept</button><button class="btn" type="button" onclick="settle(' + i + ')">Dismiss</button></div></div>'; }).join("") || empty("check-circle", "No suggestions right now.")) +
    '<div class="foot">Dokkit only suggests. It never changes a rule by itself.</div></div>' +
    '<div class="card"><h2>Channels</h2><dl class="kv"><dt>Page</dt><dd>Through PagerDuty</dd><dt>Push</dt><dd>' + sel(["PagerDuty low urgency", "ntfy", "Pushover"], chan.push, "chan.push=this.value;render()", "Push goes through", "sm") + '</dd><dt>Digest</dt><dd><input class="inp sm" type="time" value="' + chan.digest + '" onchange="chan.digest=this.value" aria-label="Digest time"> every morning</dd><dt>Webhook</dt><dd><input class="inp sm" type="url" style="width:100%" placeholder="https://" value="' + chan.hook + '" onchange="chan.hook=this.value" aria-label="Webhook address"></dd></dl></div></div>';
}
function statCards(s) {
  var d = STATS[s.id];
  if (!d) return "";
  if (d.upstream) return '<div class="card"><h2>Upstream<span class="end">last 5 minutes, illustrative</span></h2>' + tbl("minmax(0,1fr) repeat(6, 62px)", ["Upstream", "Calls", "Errors", "p50", "p95", "Timeouts", "Abandoned"], d.upstream) + "</div>" +
    '<div class="card"><h2>Devices failing<span class="end">last 5 minutes, illustrative</span></h2>' + (d.failing.length ? tbl("minmax(0,1fr) 62px 68px 54px 62px 84px 68px", ["Device", "Employee", "Requests", "Errors", "Refused", "Rate limited", "Last seen"], d.failing.map(function (f) { return [f[0] + ' <span class="mono mute">' + f[1] + "</span>"].concat(f.slice(2)); })) : empty("check-circle", "No device is failing.")) + "</div>";
  return '<div class="card"><h2>Uploads and scans<span class="end">right now, illustrative</span></h2><div class="stats">' + d.top.map(function (f) { return '<div class="stat"><b>' + f[1] + "</b><span>" + f[0] + "</span></div>"; }).join("") + "</div></div>" +
    '<div class="card"><h2>Work queue<span class="end">ready by kind, illustrative</span></h2>' + tbl("minmax(0,1fr) 84px", ["Kind", "Ready"], d.queue) + "</div>" +
    '<div class="card"><h2>Failures in the last 24 hours, and disk<span class="end">illustrative</span></h2><dl class="kv">' + d.kv.map(function (f) { return "<dt>" + f[0] + "</dt><dd>" + f[1] + "</dd>"; }).join("") + "</dl></div>";
}
function settingsMore() {
  var c = "130px 110px minmax(0,1fr) 120px 84px";
  return '<div class="card"><h2>Keys<span class="end">' + sel(KINDS.map(function (k) { return k[0]; }), keyKind, "keyKind=this.value", "Kind of key", "sm") + '<button class="btn sm primary" type="button" onclick="makeKey()">' + ic("plus") + "New key</button></span></h2>" +
    (newKey ? '<div class="once">' + newKey + '</div><p class="lead" style="padding-top:0">Shown once. Copy it now. Dokkit keeps only a hash of it.</p>' : "") +
    (KEYS.length ? '<div class="lh" style="grid-template-columns:' + c + '"><span>Kind</span><span>Starts with</span><span>What it is for</span><span>Last used</span><span></span></div>' +
      KEYS.map(function (k, i) { return '<div class="li slim hov" style="grid-template-columns:' + c + '"><b style="font-weight:600">' + k.kind + '</b><span class="mono">' + k.key + '...</span><span class="mute">' + k.use + '</span><span class="mute">' + k.last + '</span><button class="btn sm" type="button" onclick="revokeKey(' + i + ')">Revoke</button></div>'; }).join("") : empty("key", "No keys. Make an enrolment token to put Dokkit on a machine.")) + "</div>" +
    '<div class="card"><h2>People<span class="end">1</span></h2><div class="est" style="grid-template-columns: auto minmax(0,1fr) auto; align-items:center"><span class="av">' + ME.slice(0, 2).toUpperCase() + "</span><b>" + ME + "</b>" + tag("Owner", "brand") + '</div><dl class="kv"><dt>Owner</dt><dd>Everything, including keys and people.</dd><dt>Member</dt><dd>Sees everything and can act: watch, snooze, accept, run tasks. Cannot make keys or add people.</dd><dt>Viewer</dt><dd>Sees everything except secrets and keys. Cannot change anything.</dd></dl></div>' +
    '<div class="card"><h2>Dokkit itself</h2><dl class="kv" style="grid-template-columns: 170px minmax(0,1fr)">' + SELF.map(function (f) { return "<dt>" + f[0] + "</dt><dd>" + (f[2] ? lvl(f[2]) + " " : "") + f[1] + "</dd>"; }).join("") + "</dl></div>" +
    '<div class="card"><h2>Access for AI tools<span class="end">what a token for them may do</span></h2><dl class="kv"><dt>Address</dt><dd class="mono">https://' + HOST + "/mcp</dd>" +
    [["read", "Read", "See states, issues, jobs, deploys and errors."], ["read-logs", "Read logs", "See what is written in the logs."], ["act", "Act", "Snooze, mark as seen and run accepted tasks."]].map(function (x) { return "<dt>" + x[1] + '</dt><dd style="display:flex; align-items:center; gap:10px"><input class="switch" type="checkbox"' + (mcp[x[0]] ? " checked" : "") + ' onchange="mcp[\'' + x[0] + '\']=this.checked" aria-label="' + x[1] + '"><span class="mute">' + x[2] + "</span></dd>"; }).join("") +
    '</dl><div class="foot">Making keys, managing people and accepting what was found are never offered to AI tools.</div></div>';
}

function viewSettings() {
  function opts(key, list) {
    return '<div class="opts">' + list.map(function (o) {
      return '<button type="button" class="opt' + (look[key] === o[0] ? " on" : "") + '" onclick="setLook(&quot;' + key + "&quot;, &quot;" + o[0] + '&quot;)"><span class="sw" style="background:' + o[2] + '"></span>' + o[1] + "</button>";
    }).join("") + "</div>";
  }
  return head("Settings") + '<div class="body">' +
    '<div class="card"><h2>Theme</h2>' + opts("theme", [["light", "Light", "#fafafa"], ["dark", "Dark", "#0f0f11"]]) + "</div>" +
    '<div class="card"><h2>Dark base<span class="end">applies in dark</span></h2>' + opts("base", [["neutral", "Neutral", "#0f0f11"], ["plum", "Plum", "#1f1a2a"], ["slate", "Slate", "#252b39"]]) + "</div>" +
    '<div class="card"><h2>Accent</h2>' + opts("accent", [["violet", "Violet", "#6d4aff"], ["orange", "Orange", "#ea580c"], ["blue", "Blue", "#2563eb"], ["teal", "Teal", "#0d9488"]]) + "</div>" +
    '<div class="card"><h2>Logo<span class="end">generated, then traced</span></h2><div class="logos">' +
    '<figure><div class="vec">' + LOGO + "</div><figcaption>In use: traced as a vector, takes the accent</figcaption></figure>" +
    '<figure><img src="logos/d2.png" alt="Generated logo, a D with a dot"><figcaption>The generated original it was traced from</figcaption></figure>' +
    '<figure><img src="logos/d1.png" alt="Generated logo, a D made of bars"><figcaption>The other option. It has a smudge on the left</figcaption></figure></div></div>' + settingsMore() + "</div>";
}

// ---------- actions and router ----------
function snooze(i) { snoozed[i] = true; render(); }
function watch(id) { watched[id] = true; render(); }
function setTab(t) { tab = t; render(); }
function setTheme(t) { setLook("theme", t); }
function flip(k) { ui[k] = !ui[k]; render(); }
function toggleLib(id) { libOpen[id] = !libOpen[id]; render(); }
function pick(id) { picked[id] = !picked[id]; render(); }
function sweep(into) { found().forEach(function (p) { if (picked[p[1].id]) into[p[1].id] = true; }); picked = {}; render(); }
function acceptTask(id) { task(id).ok = true; render(); }
function dismissTask(id) { TASKS = TASKS.filter(function (t) { return t.id !== id; }); render(); }
function runTask(id) { RUNS.unshift({ t: id, at: "Just now", code: 0, dur: task(id).dur }); render(); }
function saveRule() { RULES.push({ name: draft.what + " " + draft.when, ch: draft.ch, who: draft.who, after: draft.after, on: true }); draft = blank(); ui.edit = false; render(); }
function settle(i, yes) { if (yes) SUGG[i].go(); SUGG.splice(i, 1); render(); }
function makeKey() {
  var p = KINDS.filter(function (k) { return k[0] === keyKind; })[0][1], h = hash(p + KEYS.length), k = p;
  while (k.length < 36) { h = (h * 73 + 19) % 9973; k += "abcdefghjkmnpqrstuvwxyz23456789"[h % 31]; }
  KEYS.unshift({ kind: keyKind, key: k.slice(0, 8), use: "New, not used yet", last: "Never used" }); newKey = k; render();
}
function revokeKey(i) { KEYS.splice(i, 1); render(); }
function render() {
  var p = location.hash.replace(/^#\//, "").split("/"), r = p[0] || "inbox", html, active = r;
  var e = r === "e" ? ERRS.filter(function (x) { return x.id === p[1]; })[0] : null;
  if (r !== "settings") newKey = "";
  var m = (r === "m" || r === "s") ? M(p[1]) : null, s = m && r === "s" ? m.services.filter(function (x) { return x.id === p[2]; })[0] : null;
  if (r === "s" && s) { html = viewService(m, s); active = "m:" + m.id; }
  else if (r === "m" && m) { html = viewAll(m); active = "m:" + m.id; }
  else if (r === "all") html = viewAll();
  else if (r === "jobs") html = viewJobs();
  else if (r === "logs") html = viewLogs();
  else if (r === "errors") html = viewErrors();
  else if (r === "e" && e) { html = viewError(e); active = "errors"; }
  else if (r === "found") html = viewFound();
  else if (r === "versions") html = viewVersions();
  else if (r === "deploys") html = viewDeploys();
  else if (r === "tasks") html = viewTasks();
  else if (r === "alerts") html = viewAlerts();
  else if (r === "settings") html = viewSettings();
  else { html = viewInbox(); active = "inbox"; }
  document.getElementById("side").innerHTML = side(active);
  document.getElementById("page").innerHTML = html;
}
window.addEventListener("hashchange", function () {
  if (document.startViewTransition) document.startViewTransition(function () { render(); window.scrollTo(0, 0); }); else { render(); window.scrollTo(0, 0); }
});
applyLook();
render();
