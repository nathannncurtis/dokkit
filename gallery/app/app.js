// Docket, product-shaped. Data is ../demo/data.js (the Oct 5 scan). Chart shapes are illustrative; states and facts are real.
var METERS = { "nas-01": [["Mem", 87, 90], ["Data", 74, 85]], "web-02": [["Disk", 76, 85]], "gpu-01": [["GPU", 61, 90], ["Disk", 54, 85]], "rweb": [["Disk", 29, 85], ["Mem", 28, 90]], "upload": [["Data", 15, 85]] };
var COUNT = { ticketing: ["2", "failed runs"], seq: ["133,671", "failed checks"], "upload-dns": ["1", "failed lookup"] };
var tab = "now", snoozed = {}, watched = {};
// The mark: a D with one dot, traced from the generated logo so it stays sharp at 30 px and takes the accent colour.
var LOGO = '<svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><circle cx="27.5" cy="30.5" r="5.4"></circle><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"></path></svg>';
// look = theme + dark base + accent. Saved choice wins; with none saved, keep whatever the page painted (system theme).
var look = { theme: /\bt-dark\b/.test(document.documentElement.className) ? "dark" : "light", base: "slate", accent: "teal" };
try { look = Object.assign(look, JSON.parse(localStorage.getItem("docket-look") || "{}")); } catch (e) {}
function applyLook() {
  document.documentElement.className = [look.theme === "dark" ? "t-dark" : "", look.base !== "neutral" ? "d-" + look.base : "", look.accent !== "violet" ? "a-" + look.accent : ""].filter(Boolean).join(" ");
  try { localStorage.setItem("docket-look", JSON.stringify(look)); } catch (e) {}
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
    else if (s.id === "vllm" && i === n - 2) out.push([0.9, "w"]);
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
function bigChart(s) {
  var n = 48, W = 760, H = 150, bw = 10, gap = (W - 40 - n * bw) / (n - 1), out = "";
  [0.25, 0.5, 0.75].forEach(function (g) { out += '<line x1="40" x2="' + W + '" y1="' + (H * g) + '" y2="' + (H * g) + '"></line>'; });
  series(s, n).forEach(function (b, i) { var bh = Math.max(3, b[0] * (H - 10)); out += '<rect class="' + b[1] + '" x="' + (40 + i * (bw + gap)).toFixed(1) + '" y="' + (H - bh).toFixed(1) + '" width="' + bw + '" height="' + bh.toFixed(1) + '" rx="2"></rect>'; });
  ["Sep 12", "Sep 18", "Sep 24", "Sep 30", "Oct 5"].forEach(function (d, i) { out += '<text x="' + (40 + i * (W - 80) / 4) + '" y="' + (H + 16) + '">' + d + "</text>"; });
  return '<svg viewBox="0 0 ' + W + " " + (H + 22) + '" role="img" aria-label="Checks over the last 24 days">' + out + "</svg>";
}
function vitals(m) { return (METERS[m.id] || []).map(function (v) { var hot = v[1] >= v[2] - 5; return '<span class="vit' + (hot ? " hot" : "") + '">' + v[0] + ' <u style="--v:' + v[1] + '%"><i></i></u> ' + v[1] + "%</span>"; }).join("") + (m.id === "web-01" ? '<span class="vit">447 GB free</span>' : ""); }
function seg3(m) { var t = m.services.length; return '<span class="seg3"><i class="w" style="width:' + (cnt(m, "warn") / t * 100) + '%"></i><i class="o" style="width:' + (cnt(m, "ok") / t * 100) + '%"></i><i class="n" style="width:' + (cnt(m, "none") / t * 100) + '%"></i></span>'; }
function live() { return NOW.filter(function (n, i) { return !snoozed[i]; }); }
function found() { var out = []; MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (st(s) === "none") out.push([m, s]); }); }); return out; }

// ---------- shell ----------
function side(active) {
  var items = [["inbox", "tray", "Inbox", live().length], ["all", "squares-four", "Everything"], ["jobs", "clock-countdown", "Jobs"], ["logs", "scroll", "Logs"], ["errors", "bug", "Errors"], ["alerts", "bell", "Alerts"]];
  return '<a class="org" href="#/inbox"><span class="mark">' + LOGO + '</span><span><b>Docket</b><small>example</small></span>' + ic("caret-up-down") + "</a>" +
    items.map(function (x) { return '<a class="nav' + (x[0] === active ? " on" : "") + '" href="#/' + x[0] + '">' + ic(x[1]) + x[2] + (x[3] ? '<span class="n">' + x[3] + "</span>" : "") + "</a>"; }).join("") +
    "<h3>Machines</h3>" + MACHINES.map(function (m) { var w = cnt(m, "warn"), s = mstate(m); return '<a class="nav' + (active === "m:" + m.id ? " on" : "") + '" href="#/m/' + m.id + '"><span class="dot ' + (s === "ok" ? "" : s) + '"></span>' + m.name + (w ? '<span class="q">' + w + "</span>" : "") + "</a>"; }).join("") +
    '<span class="grow"></span><a class="nav' + (active === "settings" ? " on" : "") + '" href="#/settings">' + ic("gear") + 'Settings</a><div class="me"><span class="av">NC</span><span>ncurtis</span></div>';
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
      return '<div class="li hov cols-inbox"><input class="chk" type="checkbox" aria-label="Select"><div style="min-width:0"><a class="ti" href="#/s/' + m.id + "/" + s.id + '">' + lvl("warn") + "<span>" + n.title + '</span></a><div class="sub">' + (s.lead || s.note) + '</div><div class="meta">' + tag(n.kind, "warn") + '<span class="mono">DOC-' + (i + 1) + "</span><span>" + n.since + "</span></div></div>" +
        spark(s, 118, 28) + '<div class="num">' + c[0] + "<small>" + c[1] + "</small></div>" + tag(m.name) +
        '<div style="display:flex; gap:6px; justify-content:flex-end"><a class="btn" href="#/s/' + m.id + "/" + s.id + '">Open</a><button class="btn ghost" type="button" onclick="snooze(' + i + ')" aria-label="Snooze">' + ic("clock") + "</button></div></div>";
    }).join("") || '<div class="empty">' + ic("check-circle") + "Nothing needs you. You will hear from Docket when something does.</div>";
  } else if (tab === "soon") {
    rows = SOON.map(function (x) { return '<a class="li cols-inbox" href="#/m/' + x[2] + '"><span></span><div><div class="ti">' + lvl("warn") + "<span>" + x[0] + '</span></div><div class="meta">' + tag("Threshold") + "</div></div><span></span>" + '<div class="num">' + x[1] + "</div>" + tag(M(x[2]).name) + "<span></span></a>"; }).join("");
  } else {
    rows = f.map(function (p) { return '<div class="li hov cols-inbox"><span></span><div style="min-width:0"><a class="ti" href="#/s/' + p[0].id + "/" + p[1].id + '">' + lvl("none") + '<span class="mono" style="font-size:13.5px">' + p[1].name + '</span></a><div class="sub">' + p[1].note + "</div></div>" + spark(p[1], 118, 28) + "<span></span>" + tag(p[0].name) + '<div style="display:flex; justify-content:flex-end"><button class="btn" type="button" onclick="watch(\'' + p[1].id + "')\">" + ic("plus") + "Add a check</button></div></div>"; }).join("") || '<div class="empty">' + ic("check-circle") + "Everything Docket has found is being watched.</div>";
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
    '<div class="body"><div class="card"><div class="lh cols-all"><span>Service</span><span>Version</span><span>Listens</span><span>Kind</span><span>Last 24 days</span><span>State</span></div>' + ms.map(group).join("") + "</div></div>";
}
function viewService(m, s) {
  var state = st(s), issue = NOW.filter(function (n) { return n.s === s.id; })[0], title = issue && state === "warn" ? issue.title : s.name;
  var logs = LOGS.filter(function (l) { return l[2] === m.id; });
  var facts = s.facts || [["State", s.note || (state === "ok" ? "Fine" : "No signal")]];
  return '<div class="crumb"><a href="#/all">Everything</a>' + ic("caret-right") + '<a href="#/m/' + m.id + '">' + m.name + "</a>" + ic("caret-right") + "<span>" + s.name + "</span></div>" +
    head(lvl(state) + " " + title, (state === "warn" && s.act ? '<button class="btn primary" type="button">' + s.act + "</button>" : state === "none" ? '<button class="btn primary" type="button" onclick="watch(\'' + s.id + "')\">" + ic("plus") + "Add a check</button>" : "") + '<button class="btn" type="button">' + ic("clock") + 'Snooze</button><a class="btn" href="#/logs">' + ic("scroll") + "Logs</a>") +
    '<div class="filters" style="padding-top:10px">' + (state === "warn" ? tag(s.note, "warn") : state === "none" ? tag("Not watched") : tag("Fine", "ok")) + tag(m.name) + (s.ver ? tag(s.ver) : "") + (s.where ? tag(s.where) : "") + (issue ? '<span class="mute" style="font-size:12.5px">' + issue.since + "</span>" : "") + "</div>" +
    '<div class="body rail"><div style="display:grid; gap:18px; min-width:0">' +
    (s.id === "proxy" ? '<div class="card stats">' + s.facts.slice(0, 4).map(function (f) { return '<div class="stat"><b>' + f[1] + "</b><span>" + f[0] + "</span></div>"; }).join("") + "</div>" : "") +
    '<div class="card"><h2>Checks<span class="end">last 24 days, illustrative</span></h2><div class="chart">' + bigChart(s) + "</div></div>" +
    '<div class="card"><h2>What Docket knows</h2>' + (s.lead ? '<p class="lead">' + s.lead + "</p>" : "") + '<dl class="kv">' + facts.map(function (f) { return "<dt>" + f[0] + "</dt><dd>" + (f[2] ? lvl(f[2]) + " " : "") + f[1] + "</dd>"; }).join("") + "</dl></div>" +
    '<div class="card"><h2>Latest from ' + m.name + '</h2><pre class="logbox">' + (logs.length ? logs.map(function (l) { return l[0] + "  " + (l[1] === "error" ? "<b>error</b>" : "<em>info </em>") + "  " + l[3]; }).join("\n") : "No log lines from this machine today.") + "</pre></div></div>" +
    '<div style="display:grid; gap:18px"><div class="card"><h2>Details</h2><dl class="kv"><dt>Machine</dt><dd>' + m.name + "</dd><dt>Version</dt><dd>" + (s.ver || "None reported") + "</dd><dt>Listens on</dt><dd>" + (s.where || "Nothing") + "</dd><dt>Checked</dt><dd>" + (state === "none" ? "Never" : "Every 30 s") + "</dd></dl></div>" +
    '<div class="card"><h2>Who hears about it</h2><dl class="kv"><dt>If it stops</dt><dd>' + tag("Page", "brand") + " me</dd><dt>If it degrades</dt><dd>" + tag("Push") + " me</dd><dt>Restart first</dt><dd><input class=\"switch\" type=\"checkbox\" aria-label=\"Restart first\"></dd><dt>Anyone else</dt><dd>Nobody</dd></dl></div></div></div>";
}
function viewJobs() {
  var out = [];
  MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (/^(cron|timer|task|quarterly)$/.test(s.ver) || /^Ran |^Last ran|^Rebuilt/.test(s.note)) out.push([m, s]); }); });
  return head("Jobs") + filters("Filter jobs") + '<div class="body"><div class="card"><div class="lh cols-all"><span>Job</span><span>Machine</span><span>Kind</span><span></span><span>Last 24 days</span><span>Last run</span></div>' +
    out.map(function (j) { var s = j[1]; return '<a class="li slim cols-all" href="#/s/' + j[0].id + "/" + s.id + '"><div class="ti">' + lvl(st(s)) + "<span>" + s.name + '</span></div><span class="mute">' + j[0].name + '</span><span class="mute">' + (/^(cron|timer|task|quarterly)$/.test(s.ver) ? s.ver : "service") + "</span><span></span>" + spark(s, 118, 22) + tag(st(s) === "none" ? "No signal yet" : s.note) + "</a>"; }).join("") + "</div></div>";
}
function viewLogs() {
  return head("Logs") + filters("Search log lines") + '<div class="body"><div class="card"><div class="lh" style="grid-template-columns: 60px 70px 120px minmax(0,1fr)"><span>Time</span><span>Level</span><span>Source</span><span>Message</span></div>' +
    LOGS.map(function (l) { return '<div class="li slim" style="grid-template-columns: 60px 70px 120px minmax(0,1fr)"><span class="mono mute">' + l[0] + "</span>" + tag(l[1], l[1] === "error" ? "warn" : "") + '<span class="mono mute">' + l[2] + "</span><span>" + l[3] + "</span></div>"; }).join("") + "</div></div>";
}
function viewErrors() {
  return head("Errors") + '<div class="body"><div class="card"><div class="empty">' + ic("bug") + "<b style=\"color:var(--ink)\">Error reporting is built in and switched off</b><br>The field app proxy and the upload portal will send crashes here once they are given Docket's address.<br><br><button class=\"btn primary\" type=\"button\">Show the address to set</button></div></div></div>";
}
function viewAlerts() {
  return head("Alerts", '<button class="btn primary" type="button">' + ic("plus") + "New rule</button>") + '<div class="body"><div class="card"><div class="lh" style="grid-template-columns: minmax(0,1fr) 150px 120px 50px"><span>Rule</span><span>Reaches you by</span><span>Who</span><span>On</span></div>' +
    WAKE.map(function (w) { return '<div class="li slim" style="grid-template-columns: minmax(0,1fr) 150px 120px 50px"><div class="ti">' + ic("bell") + "<span>" + w[0] + "</span></div>" + (w[1] ? tag("Page, PagerDuty", "brand") : tag("Morning digest")) + '<span class="mute">me</span><input class="switch" type="checkbox" checked aria-label="Rule on"></div>'; }).join("") + "</div></div>";
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
    '<figure><img src="logos/d1.png" alt="Generated logo, a D made of bars"><figcaption>The other option. It has a smudge on the left</figcaption></figure></div></div></div>';
}

// ---------- actions and router ----------
function snooze(i) { snoozed[i] = true; render(); }
function watch(id) { watched[id] = true; render(); }
function setTab(t) { tab = t; render(); }
function setTheme(t) { setLook("theme", t); }
function render() {
  var p = location.hash.replace(/^#\//, "").split("/"), r = p[0] || "inbox", html, active = r;
  var m = (r === "m" || r === "s") ? M(p[1]) : null, s = m && r === "s" ? m.services.filter(function (x) { return x.id === p[2]; })[0] : null;
  if (r === "s" && s) { html = viewService(m, s); active = "m:" + m.id; }
  else if (r === "m" && m) { html = viewAll(m); active = "m:" + m.id; }
  else if (r === "all") html = viewAll();
  else if (r === "jobs") html = viewJobs();
  else if (r === "logs") html = viewLogs();
  else if (r === "errors") html = viewErrors();
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
