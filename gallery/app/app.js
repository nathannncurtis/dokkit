// Dokkit, product-shaped. Data is data.js and more.js, an invented estate. Chart shapes are illustrative.
var METERS = { vault: [["Mem", 88, 90], ["Data", 71, 85]], press01: [["Disk", 62, 85]], press02: [["Disk", 78, 85]], gpu01: [["GPU", 58, 90], ["Disk", 49, 85]], web01: [["Mem", 26, 90], ["Disk", 31, 85]], intake: [["Disk", 17, 85]] };
var COUNT = { helpdesk: ["2", "failed deploys"], loghouse: ["167,040","failed checks"], "intake-dns": ["1", "failed lookup"], finishing: ["2", "future rows"], "carrier-feeds": ["1", "future row"], proofs: ["1", "failed run"] };
var tab = "now", snoozed = {}, tick = {}, watched = {}, dismissed = {}, picked = {}, libOpen = {}, route = {}, ui = {}, newKey = "", keyKind = "App key";
var chan = { push: "ntfy", email: "ops@brightwater.example", text: "555-0142", digest: "07:00", hook: "" }, mcp = { read: true, "read-logs": false, act: false };
var AFTER = ["First failure", "3 failed checks", "5 minutes", "15 minutes"], TIMES = ["05:00", "05:30", "06:00", "06:30", "07:00", "07:30", "08:00", "08:30", "09:00", "09:30", "10:00"];
function blank() { return { what: "Client intake", when: "Stops", after: "3 failed checks", ch: "Page", who: "Me" }; }
var draft = blank();
// The mark: a D with one dot, traced from the generated logo so it stays sharp at 30 px and takes the accent colour.
var LOGO = '<svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><circle cx="27.5" cy="30.5" r="5.4"></circle><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"></path></svg>';
// look = theme + dark base + accent. Saved choice wins; with none saved, keep whatever the page painted (system theme).
var look = { theme: /\bt-dark\b/.test(document.documentElement.className) ? "dark" : "light", base: "slate", accent: "teal" };
try { look = Object.assign(look, JSON.parse(localStorage.getItem("dokkit-look") || "{}")); } catch (e) {}
// Address overrides, for looking at one state directly: ?theme=dark&tab=soon&ui=edit&y=800
(location.search || "").replace(/[?&](theme|base|accent|tab|ui|y)=([a-z0-9,]+)/g, function (_, k, v) {
  if (k === "tab") tab = v; else if (k === "ui") v.split(",").forEach(function (x) { ui[x] = true; }); else if (k === "y") ui.y = +v; else look[k] = v;
});
// ui=q: what the filter field holds on Everything, a machine and Logs
var Q = ui.q ? "relay" : "";
function hit() { return !Q || [].join.call(arguments, " ").toLowerCase().indexOf(Q) >= 0; }
function applyLook() {
  document.documentElement.className = [look.theme === "dark" ? "t-dark" : "", look.base !== "neutral" ? "d-" + look.base : "", look.accent !== "violet" ? "a-" + look.accent : ""].filter(Boolean).join(" ");
  try { localStorage.setItem("dokkit-look", JSON.stringify(look)); } catch (e) {}
}
function setLook(k, v) { look[k] = v; applyLook(); render(); }

function st(s) { return watched[s.id] ? "ok" : s.state; }
function ic(name) { return '<i class="ph ph-' + name + '" aria-hidden="true"></i>'; }
var SAY = { ok: "Fine", warn: "Needs a look", none: "Not watched", bad: "Down" };
function lvl(state, say) { return '<span class="lvl ' + (state === "ok" ? "" : state) + '" role="img" aria-label="' + (say || SAY[state]) + '"></span>'; }
function mono(x) { return '<span class="mono">' + x + "</span>"; }
function tag(text, cls) { return '<span class="tag ' + (cls || "") + '">' + text + "</span>"; }
function M(id) { return MACHINES.filter(function (m) { return m.id === id; })[0]; }
function zz(s) { return NOW.some(function (n, i) { return n.s === s.id && snoozed[i]; }); }
// a snoozed issue stops counting
function cst(s) { var x = st(s); return x === "warn" && zz(s) ? "ok" : x; }
function need(n) { return n + (n === 1 ? " needs a look" : " need a look"); }
function mstate(m) { var a = m.services.map(cst); return a.indexOf("warn") >= 0 ? "warn" : a.every(function (x) { return x === "none"; }) ? "none" : "ok"; }
function cnt(m, state) { return m.services.filter(function (s) { return cst(s) === state; }).length; }
function hash(str) { var h = 7; for (var i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) % 9973; return h; }
var SCHED = /^(cron|timer|task|quarterly)$/;
function real(m) { return !/^(outside|depends|pcs)$/.test(m.id); }
function kindOf(m, s) { return s.kind || (JOBS[s.id] || SCHED.test(s.ver) ? "Job" : m.id === "depends" ? "Dependency" : m.id === "pcs" ? "Desktop app" : "Service"); }
function vshow(v) { return /^[A-Z][a-z]{2} \d/.test(v) ? "build " + v : v; }
function ver(s) { return SCHED.test(s.ver) ? "" : vshow(s.ver); }
// reports a day for an error: one on each bad day, the rest spread by hash
function counts(e) { var c = [], h = hash(e.id), i; for (i = 0; i < e.bad; i++) c.push(1); for (i = e.n - e.bad; i > 0; i--) { h = (h * 73 + 19) % 9973; c[h % e.bad]++; } return c; }
// days between an error's last report and today
function lag(s) { return s.last ? 23 - dayIx(s.last) : 0; }
// n bars; the last `bad` share of them are failures. Heights are illustrative.
function series(s, n) {
  var h = hash(s.id), bad = Math.round((s.bad || 0) / 24 * n), state = st(s), out = [], c = s.frames && counts(s), top = c && Math.max.apply(0, c), k;
  for (var i = 0; i < n; i++) {
    k = i - n + bad + lag(s);
    h = (h * 73 + 19) % 9973;
    if (state === "none") out.push([0.12, ""]);
    else if (c) out.push(c[k] ? [c[k] / top, "w", c[k]] : [0, "z"]);
    else if (i >= n - bad && s.state === "warn") out.push([0.55 + (h % 45) / 100, "w"]);
    else if (s.id === "infer" && i === n - 2) out.push([0.9, "w"]);
    else out.push([0.18 + (h % 22) / 100, "o"]);
  }
  return out;
}
function bars(list, w, hgt) {
  var n = list.length, bw = 3, gap = (w - n * bw) / (n - 1);
  return '<svg class="spark" width="' + w + '" height="' + hgt + '" viewBox="0 0 ' + w + " " + hgt + '" aria-hidden="true">' + list.map(function (b, i) {
    if (!b) return "";
    var bh = Math.max(2, Math.round(b[0] * hgt)); return '<rect class="' + b[1] + '" x="' + (i * (bw + gap)).toFixed(1) + '" y="' + (hgt - bh) + '" width="' + bw + '" height="' + bh + '" rx="1"></rect>';
  }).join("") + "</svg>";
}
// which of the 24 bars a date such as "Oct 1 19:30" falls on; Sep 12 is the first
function dayIx(at) { var p = at.split(" "); return p[0] === "Oct" ? 18 + +p[1] : p[0] === "Sep" ? p[1] - 12 : -1; }
function spark(s, w, hgt) {
  var b = series(s, 24), j = JOBS[s.id] || {}, days = j.days, f = j.fail == null ? -1 : dayIx(j.at[j.fail]), last = j.at && j.at[0] ? dayIx(j.at[0]) : 23;
  if (f >= 0) b[f] = [0.8, "b"];
  return bars(b.map(function (x, i) { return i > last || days && days.indexOf(i) < 0 ? null : x; }), w, hgt);
}
// a check's response time in ms, read off its bar
function ms(s, b) { return Math.round((s.ms || 22) + 100 * b[0]); }
// PCs reporting each day: two thirds of them at the least, all of them today
function seen(s, k) { var h = series(s, 24).map(function (b) { return b[0]; }), lo = Math.min.apply(0, h), d = Math.max.apply(0, h) - lo || 1; return h.map(function (x, i) { return i === 23 ? k : Math.round(k * (2 + (x - lo) / d) / 3); }); }
function span(a, unit) { var lo = Math.min.apply(0, a), hi = Math.max.apply(0, a); return (lo === hi ? hi : lo + " to " + hi) + unit; }
// One bar is half a day at n = 48 and a day at n = 24; labels sit under the bars for their dates.
// under 760 px a chart is drawn at its card's width, so its labels are not scaled down
var CW = 760;
function chartW() { var p = document.getElementById("page"); return window.innerWidth <= 760 && p.clientWidth ? p.clientWidth - 66 : 760; }
function bigChart(s, mark, label, n, vals) {
  n = n || 48;
  var W = CW = chartW(), H = 150, bw = Math.round(W / n * 0.63), gap = (W - n * bw) / (n - 1), out = "", list = series(s, n);
  // tallest bar nearly fills the height; counts and the deploy note get room above
  // vals as one number: every bar is that share of the height
  var flat = typeof vals === "number", val = flat ? [1] : vals || list.map(function (b) { return label ? b[0] : ms(s, b); }), top = Math.max.apply(0, val) || 1, room = mark ? 36 : label ? 20 : 6;
  list.forEach(function (b, i) {
    var x = i * (bw + gap), bh = flat ? vals * H : Math.max(3, val[i] / top * (H - room));
    out += '<rect class="' + b[1] + '" x="' + x.toFixed(1) + '" y="' + (H - bh).toFixed(1) + '" width="' + bw + '" height="' + bh.toFixed(1) + '" rx="2"></rect>' + (b[2] ? '<text text-anchor="middle" x="' + (x + bw / 2).toFixed(1) + '" y="' + (H - bh - 5).toFixed(1) + '">' + b[2] + "</text>" : "");
  });
  [["Sep 12", 0], ["Sep 18", 6], ["Sep 24", 12], ["Sep 30", 18], ["Oct 5", 23]].forEach(function (d, i) { out += '<text text-anchor="' + (i ? i < 4 ? "middle" : "end" : "start") + '" x="' + (i ? i < 4 ? ((d[1] + 0.5) * W / 24).toFixed(1) : W : 0) + '" y="' + (H + 16) + '">' + d[0] + "</text>"; });
  if (mark) { var mx = (n - Math.round((s.bad || 0) / 24 * n) - lag(s)) * (bw + gap) - gap / 2; out += '<line class="mk" x1="' + mx.toFixed(1) + '" x2="' + mx.toFixed(1) + '" y1="0" y2="' + H + '"></line><text class="mk" text-anchor="end" x="' + (mx - 6).toFixed(1) + '" y="11">' + mark + "</text>"; }
  return '<svg viewBox="0 0 ' + W + " " + (H + 22) + '" role="img" aria-label="' + (label || "Checks") + ' over the last 24 days">' + out + "</svg>";
}
function vitals(m) { return (METERS[m.id] || []).map(function (v) { var hot = v[1] >= v[2] - 5; return '<span class="vit' + (hot ? " hot" : "") + '">' + v[0] + ' <u style="--v:' + v[1] + '%"><i></i></u> ' + v[1] + "%</span>"; }).join(""); }
function seg3(m) { var t = m.services.length; return '<span class="seg3"><i class="w" style="width:' + (cnt(m, "warn") / t * 100) + '%"></i><i class="o" style="width:' + (cnt(m, "ok") / t * 100) + '%"></i><i class="n" style="width:' + (cnt(m, "none") / t * 100) + '%"></i></span>'; }
function live() { return NOW.filter(function (n, i) { return !snoozed[i]; }); }
function found() { var out = []; MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (st(s) === "none" && !dismissed[s.id]) out.push([m, s]); }); }); return out; }
function svc(id) { var r; MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (s.id === id) r = [m, s]; }); }); return r; }
function offers() { return TASKS.filter(function (t) { return !t.ok; }); }
function empty(icon, text) { return '<div class="empty">' + ic(icon) + text + "</div>"; }
function sel(list, val, js, label, cls) { return '<span class="dd ' + (cls || "") + '"><select class="inp ' + (cls || "") + '" aria-label="' + label + '" onchange="' + js + '">' + list.map(function (o) { return "<option" + (o === val ? " selected" : "") + ">" + o + "</option>"; }).join("") + "</select>" + ic("caret-down") + "</span>"; }
function kv(list, cols) { var any = list.some(function (f) { return f[2]; }); return '<dl class="kv"' + (cols ? ' style="--cols: ' + cols + '"' : "") + ">" + list.map(function (f) { return "<dt>" + f[0] + "</dt><dd>" + (f[2] ? lvl(f[2]) + " " : any ? '<span class="lvl no"></span> ' : "") + f[1] + "</dd>"; }).join("") + "</dl>"; }
// A column of numbers is right-aligned; a cell that does not apply reads n/a.
function tbl(cols, heads, rows) {
  var num = heads.map(function (h, i) { return i && rows.every(function (r) { return /^(|[\d,.:]+( m?s)?)$/.test(r[i]); }); });
  return '<div class="lh" style="--cols:' + cols + '">' + heads.map(function (h, i) { return '<span class="' + (num[i] ? "r" : "") + '">' + h + "</span>"; }).join("") + "</div>" +
    rows.map(function (r) { return '<div class="li slim tb" style="--cols:' + cols + '">' + r.map(function (c, i) { return '<span class="' + (i ? "mono" : "") + (num[i] ? " r" : "") + '">' + (c === "" ? '<span class="mute">n/a</span>' : c) + "</span>"; }).join("") + "</div>"; }).join("");
}
// a table's columns: at full width, under 1100 px, and the narrowest its rows may get
function nc(c, n, w) { return c + ";--ncols:" + n + ";--minw:" + w + "px"; }
function took(s) { return s < 60 ? s + " s" : Math.floor(s / 60) + " min " + (s % 60) + " s"; }
function result(code) { return code ? failed() : tag("Finished"); }
function failed() { return tag(ic("warning") + "Failed", "bad"); }
function no(x) { return '<span class="mute">' + x + "</span>"; }
function never(x) { return x === "Never" ? no(x) : mono(x); }
function chip(n) { return n ? '<span class="cnt">' + n + "</span>" : ""; }
function runRow(cols, cells, out, open) { var st = ' style="--cols:' + cols + '"'; return '<details class="run"' + (open ? " open" : "") + st + '><summary class="li slim"' + st + ">" + cells + ic("caret-down") + '</summary><pre class="logbox">' + out + "</pre></details>"; }
function runsOf(s) { var j = JOBS[s.id]; return j.at.map(function (a, i) { return { at: a, code: i === j.fail ? 1 : 0, dur: j.dur + hash(a + s.id) % (1 + (j.dur >> 2)) }; }); }
function lastGood(s) { var r = runsOf(s).filter(function (x) { return !x.code; })[0]; return r ? r.at : ""; }
// a job's runs as log rows, in the shape of LOGS
function runLines(m, s) { var notes = JOBS[s.id].notes || []; return runsOf(s).map(function (x, i) { var d = x.at.slice(0, -6); return [x.at.slice(-5), x.code ? "error" : "info", m.name, x.code ? "Run stopped with exit code " + x.code : notes[i] || "Finished in " + took(x.dur), s.id, d === DAYS[0] ? "" : d]; }); }
// sid: all of that service's lines; without it, today's lines from everything, newest first, a job giving its latest finished run and every failed one
function lines(sid) {
  var out = LOGS;
  MACHINES.forEach(function (m) { m.services.forEach(function (s) { var got = 0; if (JOBS[s.id]) out = out.concat(runLines(m, s).filter(function (l) { return sid || !l[5] && (l[1] === "error" || !got++); })); }); });
  return sid ? out.filter(function (l) { return l[4] === sid; }) : out.filter(function (l) { return !l[5]; }).sort(function (a, b) { return b[0].localeCompare(a[0]); });
}
function rt(id) { return route[id] || (route[id] = { down: "Page", deg: "Push", restart: false }); }
// --hang: where the message starts, for a wrapped line under 1100 px
function logLine(at, bad, msg) { return '<span style="--hang:' + (at.length + 9) + 'ch">' + at + "  " + (bad ? "<b>error</b>" : "<em>info </em>") + "  " + msg + "</span>"; }
function caught(e) { return e.handled ? tag("Caught by the app") : tag("Not caught", "warn"); }

// ---------- shell ----------
function side(active) {
  var groups = [["Watch", [["inbox", "tray", "Inbox", live().length], ["all", "squares-four", "Everything"], ["jobs", "clock-countdown", "Jobs"], ["logs", "scroll", "Logs"], ["errors", "bug", "Errors"]]],
    ["Changes", [["deploys", "rocket-launch", "Deploys"], ["versions", "git-branch", "Versions"]]],
    ["Manage", [["found", "binoculars", "Found", found().length], ["tasks", "terminal-window", "Tasks"], ["alerts", "bell", "Alerts"], ["settings", "gear", "Settings"]]]];
  return '<a class="org" href="#/inbox"><span class="mark">' + LOGO + '</span><span><b>Dokkit</b><small>' + ORG + '</small></span>' + ic("caret-up-down") + "</a>" +
    groups.map(function (g) { return "<h3>" + g[0] + "</h3>" + g[1].map(function (x) { return '<a class="nav' + (x[0] === active ? " on" : x[0] === "all" && /^m:/.test(active) ? " up" : "") + '" href="#/' + x[0] + '" aria-label="' + x[2] + (x[3] ? ", " + x[3] : "") + '">' + ic(x[1]) + x[2] + (x[3] ? '<span class="n">' + x[3] + "</span>" : "") + "</a>"; }).join(""); }).join("") +
    "<h3>Machines</h3>" + MACHINES.map(function (m) { var w = cnt(m, "warn"), s = mstate(m); return '<a class="nav' + (active === "m:" + m.id ? " on" : "") + '" href="#/m/' + m.id + '"><span class="dot ' + (s === "ok" ? "" : s) + '"></span>' + m.name + (w ? '<span class="q">' + w + "</span>" : "") + "</a>"; }).join("") +
    '<span class="grow"></span><div class="me"><span class="av">' + ME.slice(0, 2).toUpperCase() + "</span><span>" + ME + '</span></div>';
}
function themeBtn() { var dark = look.theme === "dark"; return '<button class="btn ghost" type="button" onclick="setTheme(\'' + (dark ? "light" : "dark") + '\')" aria-label="Switch theme">' + ic(dark ? "sun" : "moon") + "</button>"; }
function head(title, end) { return '<div class="head"><h1 tabindex="-1">' + title + '</h1><div class="end">' + (end || "") + themeBtn() + "</div></div>"; }
var NARROW = "(max-width: 1100px)";
function narrow() { return typeof matchMedia === "function" && matchMedia(NARROW).matches; }
function filters(ph, name, time, val, more) {
  return '<div class="filters"><button class="btn" type="button">' + ic("hard-drives") + (name || "All machines") + " " + ic("caret-down") + '</button><button class="btn" type="button">' + ic("calendar-blank") + (time || "Last 24 days") + " " + ic("caret-down") + "</button>" +
    '<label class="search">' + ic("magnifying-glass") + '<input type="search" placeholder="' + ph + '" aria-label="Filter"' + (val ? ' value="' + val + '"' : "") + "><kbd>/</kbd></label>" + (more || "") + "</div>";
}

// ---------- views ----------
var HEADS = { now: ["Issue", "Last 24 days", "Count", "Machine"], soon: ["Measure", "Trend", "Now and limit", "Machine"], found: ["Found", "How it was found", "Machine"] };
function names(ids) { return ids.map(function (id) { return svc(id)[1].name; }); }
// how a found thing was found, and the line under its name
function how(s) { return HOW[s.id] ? HOW[s.id] + (s.kind === "Port" ? " " + mono(s.where) : "") : "Named in " + names(s.by)[0] + "'s config"; }
function saw(s) { return (s.by ? "Used by " + (s.by.length > 1 ? s.by.length + " services" : names(s.by)[0]) : s.note) + "."; }
// an address that wraps after a dot or before its port, never inside a word
function brk(a) { return a.replace(/\./g, ".<wbr>").replace(/:(\d+)$/, "<wbr>:$1"); }
function addrRow(a) { return '<dd><span class="mono" style="min-width:0">' + brk(a) + '</span><button class="btn sm" type="button" style="margin-left:auto" onclick="copy(\'' + a + "')\">" + ic("copy") + "Copy</button></dd>"; }
function link(id) { var p = svc(id); return '<a href="#/s/' + p[0].id + "/" + id + '">' + p[1].name + "</a>"; }
function viewInbox() {
  var f = found(), all = MACHINES.reduce(function (a, m) { return a + m.services.length; }, 0), not = MACHINES.reduce(function (a, m) { return a + m.services.filter(function (s) { return st(s) === "none"; }).length; }, 0), tabs = [["now", "Needs you", live().length], ["soon", "Soon", SOON.length], ["found", "Not watched", f.length]], rows = "", cls = tab === "now" ? "" : tab === "soon" ? " soon" : " nw";
  var some = tab === "now" && NOW.some(function (n, i) { return tick[i] && !snoozed[i]; }), every = live().length && NOW.every(function (n, i) { return tick[i] || snoozed[i]; });
  if (tab === "now") {
    rows = NOW.map(function (n, i) {
      if (snoozed[i]) return "";
      var m = M(n.m), s = m.services.filter(function (x) { return x.id === n.s; })[0], c = COUNT[s.id] || ["", ""];
      return '<div class="li hov cols-inbox"><input class="chk" type="checkbox"' + (tick[i] ? " checked" : "") + ' onchange="tickOne(' + i + ')" aria-label="Select"><div><a class="ti" href="#/s/' + m.id + "/" + s.id + '">' + lvl("warn") + "<span>" + n.title + '</span></a><div class="sub">' + n.sub + '</div><div class="meta">' + tag(n.kind) + '<span class="mono">DOK-' + (i + 1) + "</span><span>" + n.since + "</span></div></div>" +
        spark(s, 96, 28) + '<div class="num">' + c[0] + "<small>" + c[1] + "</small></div>" + tag(m.name) +
        '<div style="display:flex; gap:6px; justify-content:flex-end"><a class="btn" href="#/s/' + m.id + "/" + s.id + '">Open</a><button class="btn ghost" type="button" onclick="snooze(' + i + ')" aria-label="Snooze">' + ic("clock") + "</button></div></div>";
    }).join("") || empty("check-circle", "Nothing needs you, and Dokkit will tell you when something does.");
  } else if (tab === "soon") {
    rows = SOON.map(function (x) {
      // ends at its share of the limit; climbs at the rate the sentence states
      var up = [], lim = parseInt(x.limit), end = parseInt(x.now) / lim, k = 23 * (lim - parseInt(x.now)) / x.days / lim, lo = end - 2.5 * k, name = M(x.m).name, v;
      for (var i = 0; i < 24; i++) { v = end - k * (1 - i / 23) - (i < 23 ? hash(x.what + i) % 3 / 300 : 0); up.push([0.15 + 0.85 * (v - lo) / (1 - lo), ""]); }
      return '<div class="li hov cols-inbox soon"><div><a class="ti" href="#/m/' + x.m + '">' + ic("trend-up") + "<span>" + x.what + '</span></a><div class="sub">' + x.say + "</div></div>" + bars(up, 96, 28) + '<div class="num">' + x.now + "<small>of " + x.limit + " limit</small></div>" + tag(name) + '<a class="btn" href="#/m/' + x.m + '">Open ' + name + "</a></div>";
    }).join("");
  } else {
    rows = f.map(function (p) { var s = p[1]; return '<div class="li hov cols-inbox nw"><div><a class="ti" href="#/s/' + p[0].id + "/" + s.id + '">' + lvl("none") + "<span>" + s.name + '</span></a><div class="sub">' + saw(s) + '</div></div><span class="how">' + how(s) + "</span>" + tag(p[0].name) + '<button class="btn" type="button" onclick="watch(\'' + s.id + "')\">" + ic("plus") + "Add a check</button></div>"; }).join("") || empty("check-circle", "Everything Dokkit has found is being watched.");
    if (f.length || offers().length) rows += '<a class="li slim nwf" href="#/found" style="--cols: minmax(0,1fr) auto"><span class="ti">' + ic("binoculars") + "<span>Review what was found and the tasks waiting for you</span></span>" + ic("caret-right") + "</a>";
  }
  // today's error lines, one row for each service and message
  var seen = {}, key = function (l) { return l[4] + l[3]; }, uniq = lines().filter(function (l) { return l[1] === "error" && (seen[key(l)] = (seen[key(l)] || 0) + 1) === 1; });
  return head("Inbox", '<a class="btn primary" href="#/found">' + ic("plus") + "New check</a>") + filters(narrow() && tab === "now" && live().length ? "Filter issues" : "Filter issues, services and machines", "", "", "", tab === "now" && live().length ? '<button class="btn" type="button"' + (some ? "" : " disabled") + ' onclick="snooze()">' + ic("clock") + "Snooze selected</button>" : "") +
    '<div class="tabs" role="tablist">' + tabs.map(function (t) { return '<button type="button" role="tab" aria-selected="' + (tab === t[0]) + '" class="' + (tab === t[0] ? "on" : "") + '" onclick="setTab(\'' + t[0] + "')\">" + t[1] + chip(t[2]) + "</button>"; }).join("") + "</div>" +
    '<div class="body rail"><div class="card">' + (tab === "now" && !live().length || tab === "found" && !f.length ? "" : '<div class="lh cols-inbox' + cls + '">' + (cls ? "" : '<input class="chk" type="checkbox"' + (every ? " checked" : some ? " data-some" : "") + ' onchange="tickAll(this.checked)" aria-label="Select all">') + (HEADS[tab] || HEADS.found).map(function (h) { return '<span class="' + (/^(Count|Now)/.test(h) ? "r" : "") + '">' + h + "</span>"; }).join("") + "<span></span></div>") + rows + "</div>" +
    '<div style="display:grid; gap:18px"><div class="card"><h2>Estate<span class="end">' + (all - not) + " watched, " + not + " not</span></h2>" +
    MACHINES.map(function (m) { var w = cnt(m, "warn"), n = cnt(m, "none"); return '<a class="est" href="#/m/' + m.id + '"><b>' + lvl(mstate(m)) + m.name + '</b><span class="st' + (w ? " warn" : "") + '">' + (w ? need(w) : n === m.services.length ? "not watched" : "fine") + "</span>" + seg3(m) + "</a>"; }).join("") + "</div>" +
    '<div class="card"><h2><a href="#/logs">Errors today</a>' + chip(uniq.length) + "</h2>" + uniq.map(function (l) { var k = seen[key(l)]; return '<a class="est" href="#/logs" style="--cols: minmax(0,1fr)"><span class="msg">' + svc(l[4])[1].name + ": " + l[3].charAt(0).toLowerCase() + l[3].slice(1) + '</span><span class="meta"><span>' + l[2] + "</span>" + (k > 1 ? "<span>" + k + " times</span>" : "") + "</span></a>"; }).join("") + "</div></div></div>";
}
/// mode: "dp" on the Dependencies page (full address, its own button, no version); "pc" on Staff PCs (no address)
function svcLine(m, s, mode) {
  var state = st(s), href = "#/s/" + m.id + "/" + s.id, dp = mode === "dp", add = dp && state === "none", j = JOBS[s.id];
  return (add ? '<div class="li slim hov cols-all dp">' : '<a class="li slim cols-all ' + (mode || "") + '" href="' + href + '">') + '<div class="ti">' + lvl(state) + (add ? '<a href="' + href + '">' + s.name + "</a>" : "<span>" + s.name + "</span>") + "</div>" +
    (dp ? "" : '<span class="mono mute">' + ver(s) + "</span>") + (mode === "pc" ? "" : '<span class="mono mute">' + (dp && s.addr || s.where || "") + "</span>") + (dp ? '<span class="mute">' + names(s.by).join(", ") + "</span>" : mode ? "" : '<span class="mute">' + kindOf(m, s) + "</span>") + spark(s, 118, 22) +
    (state === "warn" ? zz(s) ? tag("Snoozed") : tag(s.note, j && j.fail === 0 ? "bad" : "warn") : state === "none" ? tag("Not watched") : tag(s.note || "Fine")) +
    (add ? '<button class="btn sm" type="button" onclick="watch(\'' + s.id + "')\">" + ic("plus") + "Add a check</button></div>" : ic("caret-right") + "</a>");
}
function modeOf(m) { return m.id === "depends" ? "dp" : m.id === "pcs" ? "pc" : ""; }
// bare: the page title already names it, so the band is only the counts and the meters
function group(m, bare) {
  var list = m.services.filter(function (s) { return hit(s.name, ver(s), s.addr, s.where); }), k = function (x) { return list.filter(function (s) { return cst(s) === x; }).length; };
  if (!list.length && !bare) return "";
  var w = k("warn"), n = k("none"), ok = k("ok"), v = vitals(m), chips = (w ? tag(need(w), "warn") : "") + (n ? tag(n + " not watched") : "") + (ok ? tag(ok + " fine") : "");
  // the meters are the machine's, so they stay when the filter leaves no rows
  var band = bare ? (chips || v ? '<div class="grp bare"><span class="end">' + chips + "</span>" + (v ? '<span class="vits">' + v + "</span>" : "") + "</div>" : "")
    : '<div class="grp"><a href="#/m/' + m.id + '" style="display:flex; align-items:center; gap:8px">' + lvl(Q ? w ? "warn" : ok ? "ok" : "none" : mstate(m)) + m.name + '</a><span class="mute" style="font-weight:400">' + m.kind + '</span><span class="end">' + chips + '<span class="vits">' + v + "</span></span></div>";
  return band + (list.map(function (s) { return svcLine(m, s, bare ? modeOf(m) : ""); }).join("") || empty("magnifying-glass", "Nothing here matches."));
}
function viewAll(only) {
  var ms = only ? [only] : MACHINES, mode = only ? modeOf(only) : "", dv = only && SELFV.on[only.id];
  return (only ? '<div class="crumb"><a href="#/all">Everything</a>' + ic("caret-right") + "<span>" + only.name + "</span></div>" : "") + head(only ? lvl(mstate(only)) + " " + only.name : "Everything", '<a class="btn primary" href="#/found">' + ic("plus") + "New check</a>") +
    (mode === "dp" ? '<p class="lead">Things your services call that Dokkit does not run.</p>' : "") + filters(mode === "dp" ? "Filter by name or address" : mode === "pc" ? "Filter by name or version" : "Filter by name, version or port", only && only.name, "", Q) + '<div class="body">' +
    (only && real(only) ? '<div class="card"><h2>Details</h2><dl class="strip">' + [["Address", mono(only.addr)], ["OS", only.kind], ["Dokkit version", mono(dv) + (dv !== SELFV.newest ? ' <span class="mute">behind ' + SELFV.newest + "</span>" : "")], ["Last seen", mono("Oct 5 17:46")], ["Enrolled", mono(only.since)]].map(function (f) { return "<div><dt>" + f[0] + "</dt><dd>" + f[1] + "</dd></div>"; }).join("") + "</dl></div>" : "") +
    '<div class="card"><div class="lh cols-all ' + mode + '"><span>' + (mode ? "Name" : "Service") + "</span>" + (mode === "dp" ? "" : "<span>Version</span>") + (mode === "pc" ? "" : "<span>" + (mode === "dp" ? "Address" : "Listens") + "</span>") + (mode === "dp" ? "<span>Used by</span>" : mode ? "" : "<span>Kind</span>") + "<span>Last 24 days</span><span>State</span><span></span></div>" + ms.map(function (m) { return group(m, only); }).join("") + "</div>" +
    (mode === "pc" ? pcCard(PCN, PCN.length + " seen this week, " + (PCN.length - Object.keys(QUIET).length) + " reporting now") : "") + "</div>";
}
// app: only the PCs that app is on, with its version on each
function pcCard(ns, end, app) {
  var apps = M("pcs").services, on = function (a, n) { return a === apps[0] ? a.ver : ON[a.id] && ON[a.id][n]; };
  function appTag(a, n, text) { return (HELD[a.id] || {})[n] ? tag(ic("push-pin") + text + "held") : on(a, n) !== a.ver ? tag(ic("clock-countdown") + text + "behind", "warn") : text ? tag(text.trim()) : ""; }
  function rep(name) { return today.filter(function (l) { return l[1] === "error" && l[2] === name && (!app || l[4] === app.id); }).length; }
  var today = lines(), any = !app || ns.some(function (n) { return rep(PC + n); }), pk = "cols-pcs" + (app ? " app" : ""),
    c = app ? any ? nc("130px 120px 150px minmax(0,1fr) 100px", "88px 92px 116px minmax(140px,1fr) 84px", 608) : nc("130px 120px 150px minmax(0,1fr)", "88px 92px 116px minmax(140px,1fr)", 510) : nc("130px 120px 100px minmax(0,1fr)", "76px 86px 82px minmax(140px,1fr)", 458);
  return '<div class="card' + (app ? " wide" : "") + '"><h2>PCs<span class="end">' + end + '</span></h2><div class="lh ' + pk + '" style="--cols:' + c + '"><span>PC</span><span>Last seen</span>' + (app ? "<span>Version</span><span>Other apps</span>" + (any ? "<span>Reports today</span>" : "") : "<span>Reports today</span><span>Apps on it</span>") + "</div>" +
    (ns.map(function (n) {
      var name = PC + n, h = hash(name), q = QUIET[n], k = rep(name), reps = k ? tag(k + (k === 1 ? " report" : " reports")) : "<span></span>";
      var tags = apps.map(function (a) { var v = on(a, n); return !v || a === app ? "" : appTag(a, n, a.name + ' <span class="mono">' + v + "</span> "); }).join("");
      return '<div class="li slim hov ' + pk + '" style="--cols:' + c + '"><div class="ti">' + lvl(q ? "away" : "ok", q && "Not seen today") + "<span>" + name + '</span></div><span class="mono">' + (q ? q + " 1" + h % 8 + ":" + (10 + h % 50) : "Oct 5 17:" + (40 + h % 7)) + "</span>" +
        (app ? "<span>" + mono(on(app, n)) + " " + appTag(app, n, "") + "</span>" : reps) + '<div class="meta">' + (q ? '<span class="mute">Not seen today</span>' : tags || '<span class="mute">None</span>') + "</div>" + (app && any ? reps : "") + "</div>";
    }).join("") || empty("desktop", "No PC has reported this week.")) + "</div>";
}
function viewService(m, s) {
  var state = st(s), issue = NOW.filter(function (n) { return n.s === s.id; })[0], ix = NOW.indexOf(issue), title = issue && state === "warn" ? issue.title : s.name;
  var own = real(m), kind = kindOf(m, s), v = ver(s), top = (STATS[s.id] || {}).top, app = kind === "Desktop app", dep = kind === "Dependency";
  var job = JOBS[s.id], r = rt(s.id), deps = DEPLOYS.filter(function (d) { return d[1] === s.id; }), runs = job ? runsOf(s) : [], rc = nc("150px 110px 90px 90px minmax(0,1fr) 16px", "96px 72px 84px 56px minmax(0,1fr) 16px", 426);
  var logs = lines(s.id).map(function (l) { return logLine((l[5] || DAYS[0]) + " " + l[0], l[1] === "error", l[3]); });
  var say = job ? ["If a run fails", "If it runs late"] : app ? ["If it goes quiet", "If it errors"] : ["If it stops", "If it degrades"];
  var knows = s.lead || s.facts ? '<div class="card"><h2>What Dokkit knows</h2>' + (s.lead ? '<p class="lead">' + s.lead + "</p>" : "") + (s.facts ? kv(s.facts) : "") + "</div>" : "";
  var t = series(s, 48).filter(function (b) { return b[1] === "o"; }).map(function (b) { return ms(s, b); }), pcs = app ? ON[s.id] ? Object.keys(ON[s.id]).map(Number) : PCN.filter(function (n) { return !QUIET[n]; }) : [], rep = app && seen(s, pcs.length);
  var checks = job ? "<div class=\"card\"><h2>Runs" + (runs.length ? '<span class="end">Newest first</span></h2><div class="lh" style="--cols:' + rc + '"><span>Started</span><span>Result</span><span class="r">Took</span><span class="r">Exit code</span><span></span><span></span></div>' +
      runs.map(function (x, i) { return runRow(rc, mono(x.at) + result(x.code) + '<span class="mono r">' + took(x.dur) + '</span><span class="mono r">' + x.code + "</span><span></span>", x.code ? job.tail.split("\n")[0] + "\nstopped with exit code 1" : job.tail, !i && x.code); }).join("") : '</h2><p class="lead">No run seen yet.</p>') + "</div>"
    : '<div class="card"><h2>Checks' + (state === "none" ? '</h2><p class="lead">No checks yet. Add one to start a history.</p>' : '<span class="end">' + (app ? "PCs reporting, last 24 days, " + span(rep, "") : t.length ? "Response time, last 24 days, " + span(t, " ms") : "Every check failed, last 24 days") + '</span></h2><div class="chart">' + (app ? bigChart(s, "", "PCs reporting", 24, rep) : bigChart(s, "", "", 48, t.length ? null : 0.4)) + "</div>") + "</div>";
  var det = [[dep ? "Used by" : own ? "Machine" : "Where", dep ? "<span>" + s.by.map(link).join(", ") + "</span>" : m.name]];
  if (!job) det.push(["Version", v ? mono(v) : no("Not reported")]);
  if (dep) det.push(["Host", mono(s.addr.split(":")[0])], ["Port", mono(s.addr.split(":")[1])]);
  else if (!job && !app) det.push(["Listens on", s.addr || s.where ? mono(brk(s.addr || s.where)) : no("Not reported")]);
  det.push(["Checked", state === "none" ? no("Never") : job ? "At each run" : app ? "When a PC reports" : "Every 30 s"]);
  if (job) det.push(["Schedule", job.sch || no("Not reported")], ["Last good run", lastGood(s) ? mono(lastGood(s)) : no("None yet")], ["Next expected", job.next ? mono(job.next) : no("Not reported")]);
  return '<div class="crumb"><a href="#/all">Everything</a>' + ic("caret-right") + '<a href="#/m/' + m.id + '">' + m.name + "</a>" + ic("caret-right") + "<span>" + s.name + "</span></div>" +
    head(lvl(cst(s)) + " " + title, (state === "warn" && s.act ? '<button class="btn primary" type="button">' + s.act + "</button>" : state === "none" ? '<button class="btn primary" type="button" onclick="watch(\'' + s.id + "')\">" + ic("plus") + "Add a check</button>" : "") + (issue ? '<button class="btn" type="button"' + (snoozed[ix] ? " disabled" : ' onclick="snooze(' + ix + ')"') + ">" + ic("clock") + (snoozed[ix] ? "Snoozed" : "Snooze") + "</button>" : "") + (dep ? "" : '<a class="btn" href="#/logs?s=' + s.id + '">' + ic("scroll") + "Logs</a>")) +
    '<div class="filters" style="padding-top:10px">' + (state === "warn" ? zz(s) ? tag("Snoozed") : tag("Needs a look", "warn") : state === "none" ? tag("Not watched") : tag("Fine", "ok")) + (dep ? tag("Dependency") : "") + (s.note ? '<span class="st">' + (app ? '<a href="#/m/pcs">' + s.note + "</a>" : s.note + (issue && !job && s.note.indexOf(issue.since) < 0 ? " " + issue.since : "")) + "</span>" : "") + "</div>" +
    '<div class="body rail' + (app ? " even" : "") + '"><div class="col">' + (state === "ok" ? "" : knows) +
    (top ? '<div class="card"><h2>Right now</h2><div class="stats">' + top.map(function (f) { return '<div class="stat"><b>' + f[1] + "</b><span>" + f[0] + "</span></div>"; }).join("") + "</div></div>" + (state === "ok" ? knows : "") : "") +
    checks + statCards(s) + (state === "ok" && !top ? knows : "") +
    (dep ? "" : '<div class="card"><h2>Latest logs</h2>' + (logs.length ? '<pre class="logbox">' + logs.join("\n") + "</pre>" : '<p class="lead">No log lines from this ' + (job ? "job" : app ? "app" : "service") + ' yet.</p>') + "</div>") + "</div>" +
    '<div class="col"><div class="card"><h2>Details</h2>' + kv(det) + "</div>" +
    (dep || job || app ? "" : '<div class="card"><h2>Recent deploys' + chip(deps.length) + "</h2>" + (deps.map(function (d) { return '<div class="est"><span class="dep mono">' + vshow(d[2]) + " " + ic("arrow-right") + " " + vshow(d[3]) + "</span>" + (d[7] ? failed() : tag("Went out")) + '<span class="mute"><span class="mono ink">' + d[5] + "</span>" + (d[4] !== m.name ? " on " + d[4] : "") + "</span>" + tag(d[6] === "ci" ? "Reported by CI" : "Noticed by Dokkit") + "</div>"; }).join("") || '<p class="lead">No deploy seen yet.</p>') + "</div>") +
    '<div class="card"><h2>Who hears about it</h2>' + (state === "none" ? '<p class="lead">Add a check to choose who hears about it.</p>' : '<dl class="kv"><dt>' + say[0] + "</dt><dd>" + sel(CHANNELS, r.down, "rt('" + s.id + "').down=this.value", say[0], "sm") + " me</dd><dt>" + say[1] + "</dt><dd>" + sel(CHANNELS, r.deg, "rt('" + s.id + "').deg=this.value", say[1], "sm") + " me</dd>" + (kind === "Service" && own ? "<dt>Restart first</dt><dd><input class=\"switch\" type=\"checkbox\"" + (r.restart ? " checked" : "") + " onchange=\"rt('" + s.id + "').restart=this.checked\" aria-label=\"Restart first\"></dd>" : "") + "<dt>Anyone else</dt><dd>" + no("Nobody") + "</dd></dl>") + "</div></div>" +
    (app ? pcCard(pcs, pcs.length + (pcs.length === 1 ? " PC" : " PCs"), s) : "") + "</div>";
}
function viewJobs() {
  var out = [];
  MACHINES.forEach(function (m) { m.services.forEach(function (s) { if (JOBS[s.id]) out.push([m, s]); }); });
  return head("Jobs") + filters("Filter jobs") + '<div class="body"><div class="card"><div class="lh cols-jobs"><span>Job</span><span>Machine</span><span>Schedule</span><span>Last good run</span><span>Last 24 days</span><span>Last run</span><span></span></div>' +
    out.map(function (j) { var s = j[1], r = runsOf(s)[0], g = lastGood(s); return '<a class="li slim cols-jobs" href="#/s/' + j[0].id + "/" + s.id + '"><div class="ti">' + lvl(st(s)) + "<span>" + s.name + "</span></div>" + tag(j[0].name) + '<span class="mute">' + JOBS[s.id].sch + "</span>" + mono(r && g !== r.at ? g : "") + spark(s, 118, 14) + (st(s) === "none" ? tag("Not watched") : '<div class="meta"><span class="mono ink">' + (r ? r.at : "") + "</span>" + (r ? result(r.code) : "") + "</div>") + ic("caret-right") + "</a>"; }).join("") + "</div></div>";
}
// sid: only that service's lines, of any day
function viewLogs(sid) {
  var c = nc("100px 64px 110px 150px minmax(0,1fr)", "92px 52px 72px 124px minmax(140px,1fr)", 568), p = sid && svc(sid), rows = lines(p && sid).filter(function (l) { return p || hit(l[2], l[3], (svc(l[4]) || [0, {}])[1].name); });
  return head("Logs") + filters("Filter log lines", "", p ? "All time" : "Today", p ? "" : Q, p ? '<a class="btn" href="#/logs" aria-label="Clear the service filter">' + p[1].name + " " + ic("x") + "</a>" : "") +'<div class="body"><div class="card"><div class="lh cols-logs" style="--cols:' + c + '"><span>Time</span><span>Level</span><span>Machine</span><span>Service</span><span>Message</span></div>' +
    (rows.map(function (l) { var q = svc(l[4]); return '<div class="li slim cols-logs" style="--cols:' + c + '">' + mono((l[5] || DAYS[0]) + " " + l[0]) + tag(l[1] === "error" ? "Error" : "Info", l[1] === "error" ? "bad" : "") + tag(l[2]) + (q ? '<a href="#/s/' + q[0].id + "/" + l[4] + '">' + q[1].name + "</a>" : "<span>Dokkit</span>") + "<span>" + l[3] + "</span></div>"; }).join("") || empty("scroll", "No log lines match.")) + (p && JOBS[sid] && rows.length ? '<div class="foot">' + (rows.length > 1 ? "The last " + rows.length + " runs." : "The last run.") + "</div>" : "") + "</div></div>";
}
function ownTop(e) { var f = e.frames.filter(function (x) { return x[3]; }).pop(); return f[0] + " in " + f[1] + ", line " + f[2]; }
function viewErrors() {
  var off = [svc("relay"), svc("intake-portal")];
  return head("Errors") + filters("Filter errors") + '<div class="body">' +
    '<div class="card"><div class="lh cols-inbox cols-err"><span>Error</span><span>Last 24 days</span><span class="r">Count</span><span class="pl">Machine</span><span>Last seen</span><span></span></div>' +
    (ERRS.map(function (e) { return '<a class="li cols-inbox cols-err" href="#/e/' + e.id + '"><div><div class="ti">' + ic("bug") + "<span>" + e.type + '</span></div><div class="sub mono">' + ownTop(e) + '</div><div class="meta">' + tag(svc(e.s)[1].name) + tag(e.rel, "mono") + caught(e) + "</div></div>" + spark(e, 118, 28) + '<div class="num">' + e.n + "<small>reports</small></div>" + tag(e.pcs.length > 1 ? e.pcs.length + " PCs" : e.pcs[0]) + mono(e.last) + ic("caret-right") + "</a>"; }).join("") || empty("check-circle", "No errors in the last 24 days.")) +
    (off.length ? '<div class="foot">' + ic("bug") + "<span>" + off[0][1].name + " and " + off[1][1].name + ' are not sending errors yet.</span><button class="btn sm end" type="button" onclick="flip(\'addr\')">' + ic("link") + (ui.addr ? "Hide addresses" : "Show addresses") + "</button></div>" : "") + "</div>" +
    (ui.addr ? '<div class="card"><h2>Addresses to set<span class="end">One app key for each service</span></h2><dl class="kv" style="--cols: 150px minmax(0,1fr)">' + off.map(function (p, i) { return "<dt>" + p[1].name + '</dt><dd><span class="mono">' + "https://" + ["dka_7c2f", "dka_e05b"][i] + "…@<wbr>" + HOST + "<wbr>/" + p[1].id + "</span></dd>"; }).join("") + '</dl><div class="foot"><span>The key was shown once, when it was made. If it was not kept, make a new one in Settings. Give each app its address as <span class="mono">SENTRY_DSN</span> and restart it. The key can only send.</span></div></div>' : "") + "</div>";
}
function viewError(e) {
  var p = svc(e.s), lib = [], out = "", open = libOpen[e.id], zzz = snoozed[e.id];
  function row(f) { return '<div class="li slim fr ' + (f[3] ? "own" : "lib") + '"><span class="mono">' + f[0] + (f[3] ? " " + tag("App") : "") + '</span><span class="mono mute">' + f[1] + '</span><span class="mono mute r">line ' + f[2] + "</span></div>"; }
  function flush() { if (lib.length) out += '<button type="button" class="li slim more" aria-expanded="' + !!open + '" onclick="toggleLib(\'' + e.id + '\')"><span class="ti"><span>' + lib.length + " library frame" + (lib.length > 1 ? "s" : "") + "</span></span>" + ic("caret-down") + "</button>" + (open ? lib.map(row).join("") : ""); lib = []; }
  e.frames.slice().reverse().forEach(function (f) { if (f[3]) { flush(); out += row(f); } else lib.push(f); });
  flush();
  return '<div class="crumb"><a href="#/errors">Errors</a>' + ic("caret-right") + "<span>" + e.type + "</span></div>" +
    head(ic("bug") + " " + e.type, '<button class="btn" type="button"' + (zzz ? " disabled" : ' onclick="snooze(\'' + e.id + '\')"') + ">" + ic("clock") + (zzz ? "Snoozed" : "Snooze") + '</button><a class="btn" href="#/logs?s=' + e.s + '">' + ic("scroll") + "Logs</a>") +
    '<div class="filters" style="padding-top:10px">' + tag(e.n + " reports") + '<span class="st">since ' + mono(e.first) + "</span></div>" +
    '<div class="body rail"><div style="display:grid; gap:18px; min-width:0">' +
    '<div class="card"><h2>Reports<span class="end">Last 24 days</span></h2><div class="chart">' + bigChart(e, e.dep, "Reports", 24) + "</div></div>" +
    '<div class="card"><h2>Stack<span class="end">The app\'s own code is marked</span></h2>' + out + '<div class="foot">Dokkit does not collect the message text of an error unless a service is set to keep it.</div></div></div>' +
    '<div class="card"><h2>Details</h2>' + kv([["Service", '<a href="#/s/' + p[0].id + "/" + p[1].id + '">' + p[1].name + "</a>"], ["Release", mono(e.rel)], ["First seen", mono(e.first)], ["Last seen", mono(e.last)], [e.pcs.length > 1 ? "Machines" : "Machine", "<span>" + e.pcs.map(function (x) { return '<a href="#/m/pcs">' + x + "</a>"; }).join(", ") + "</span>"], ["Caught", e.handled ? "By the app" : "No"], ["Tags", e.tags.map(function (t) { return tag(t[0] + ": " + t[1]); }).join("")]]) + "</div></div>";
}
function viewFound() {
  var f = found(), on = function (p) { return picked[p[1].id]; }, dis = f.some(on) ? "" : " disabled", off = offers();
  var scan = MACHINES.map(function (m) {
    var mine = f.filter(function (p) { return p[0] === m; });
    return mine.length ? '<div class="grp">' + lvl(mstate(m)) + m.name + '<span class="mute" style="font-weight:400">' + m.kind + '</span><span class="end">' + tag(mine.length + " found") + "</span></div>" + mine.map(function (p) {
      var s = p[1];
      return '<label class="li slim hov cols-found"><input class="chk" type="checkbox"' + (picked[s.id] ? " checked" : "") + ' onchange="pick(\'' + s.id + '\')" aria-label="Select ' + s.name + '"><div class="ti"><span>' + s.name + '</span></div><span class="how">' + how(s) + '</span><span class="mute">' + saw(s) + '</span><a class="go" href="#/s/' + m.id + "/" + s.id + '" aria-label="Open">' + ic("caret-right") + "</a></label>";
    }).join("") : "";
  }).join("");
  return head(f.length || off.length ? "Found, waiting for you" : "Found") + '<div class="body">' +
    '<div class="card"><h2>What a scan found' + chip(f.length) + (f.length ? '<span class="end"><button class="btn sm primary" type="button"' + dis + ' onclick="sweep(watched)">' + ic("plus") + 'Watch selected</button><button class="btn sm" type="button"' + dis + ' onclick="sweep(dismissed)">Dismiss selected</button></span>' : "") + "</h2>" +
    (scan ? '<div class="lh cols-found"><input class="chk" type="checkbox"' + (f.every(on) ? " checked" : f.some(on) ? " data-some" : "") + ' onchange="pickAll(this.checked)" aria-label="Select all"><span>Found</span><span>How it was found</span><span>What Dokkit saw</span><span></span></div>' + scan : empty("check-circle", "Everything found is either watched or dismissed.")) + "</div>" +
    '<div class="card"><h2>Tasks waiting to be accepted' + chip(off.length) + "</h2>" +
    (off.map(function (t) { return '<div class="li hov cols-act" style="--cols: minmax(0,1fr) auto"><div><div class="ti">' + ic("terminal-window") + "<span>" + t.name + '</span></div><code class="cmd">' + t.cmd + '</code><div class="meta">' + tag(t.m) + '<span>Would run as <span class="mono">' + t.acct + '</span></span></div></div><div style="display:flex; gap:6px"><button class="btn" type="button" onclick="acceptTask(\'' + t.id + '\')">Accept</button><button class="btn" type="button" onclick="dismissTask(\'' + t.id + '\')">Dismiss</button></div></div>'; }).join("") || empty("check-circle", "No task is waiting to be accepted.")) +
    (f.length || off.length ? '<div class="foot">Nothing here is watched or run until you say so. A task runs only the command shown, on its own machine.</div>' : "") + "</div></div>";
}
// at(row, column key) gives [version there, newest]; a row with a fourth value links there
function vt(first, cols, rows, at) {
  var body = rows.map(function (r) {
    return "<tr" + (r[3] ? "" : ' class="flat"') + '><th scope="row">' + (r[3] ? '<a href="' + r[3] + '">' + r[0] + "</a>" : r[0]) + "</th>" + cols.map(function (c) { var x = at(r, c[0]), v = x[0]; return "<td>" + (!v ? "" : v !== x[1] ? tag(vshow(v), "warn") : vshow(v)) + "</td>"; }).join("") + "<td>" + (r[3] ? ic("caret-right") : "") + "</td></tr>";
  }).join("");
  return '<div class="scroll"><table class="vt"><thead><tr><th scope="col">' + first + "</th>" + cols.map(function (c) { return '<th scope="col">' + c[1] + "</th>"; }).join("") + "<th></th></tr></thead><tbody>" + body + '</tbody></table></div><div class="foot">' + tag("Behind the newest", "warn") + "<span>Empty: not installed there</span></div>";
}
function viewVersions() {
  var hosts = MACHINES.filter(function (m) { return m.id !== "pcs" && m.id !== "depends"; }), rows = [["Dokkit", SELFV.newest, SELFV.on]], apps = M("pcs").services, c = nc("minmax(0,1fr) 110px 90px minmax(0,1.6fr) 16px", "minmax(150px,1fr) 64px 40px minmax(190px,1.6fr) 16px", 548);
  hosts.forEach(function (m) { m.services.forEach(function (s) { var on = {}; if (s.ver && !JOBS[s.id]) { on[m.id] = s.ver; rows.push([s.name, s.ver, on, "#/s/" + m.id + "/" + s.id]); } }); });
  return head("Versions") + '<div class="body">' +
    '<div class="card"><h2>Services<span class="end">Which version is on which machine</span></h2>' + vt("Service", hosts.map(function (m) { return [m.id, m.name]; }), rows, function (r, k) { return [r[2][k], r[1]]; }) + "</div>" +
    '<div class="card"><h2>Desktop apps<span class="end">The newest version of each, and the PCs not on it</span></h2>' + (apps.length ? '<div class="lh" style="--cols:' + c + '"><span>App</span><span>Version</span><span class="r">PCs</span><span class="pl">Behind or held</span><span></span></div>' + apps.map(function (s) {
      var on = ON[s.id] || {}, ns = Object.keys(on), odd = ns.filter(function (n) { return on[n] !== s.ver; });
      return '<a class="li slim" style="--cols:' + c + '" href="#/s/pcs/' + s.id + '"><div class="ti"><span>' + s.name + "</span></div>" + mono(s.ver) + '<span class="mono r">' + (ON[s.id] ? ns.length : PCN.length - Object.keys(QUIET).length) + '</span><div class="meta pl">' + odd.map(function (n) { return (HELD[s.id] || {})[n] ? tag(ic("push-pin") + PC + n + " " + on[n] + " held", "mono") : tag(ic("clock-countdown") + PC + n + " " + on[n] + " behind", "warn mono"); }).join("") + "</div>" + ic("caret-right") + "</a>";
    }).join("") : empty("desktop", "No desktop app has reported a version yet.")) + "</div></div>";
}
function viewDeploys() {
  var c = "minmax(0,1.2fr) minmax(0,1.2fr) 120px 110px 140px 16px";
  return head("Deploys") + filters("Filter deploys", "", "All time") + '<div class="body"><div class="card"><div class="lh cols-dep" style="--cols:' + c + '"><span>Service</span><span>Version</span><span>Machine</span><span>When</span><span>How it was seen</span><span></span></div>' +
    (DEPLOYS.map(function (d) { return '<a class="li slim cols-dep" style="--cols:' + c + '" href="#/s/' + d[0] + "/" + d[1] + '"><div class="ti"><span>' + svc(d[1])[1].name + '</span></div><span class="mono" style="display:flex; flex-wrap:wrap; align-items:center; gap:6px">' + vshow(d[2]) + ic("arrow-right") + vshow(d[3]) + (d[7] ? failed() : "") + "</span>" + tag(d[4]) + mono(d[5]) + tag(d[6] === "ci" ? "Reported by CI" : "Noticed by Dokkit") + ic("caret-right") + "</a>"; }).join("") || empty("rocket-launch", "No deploy seen yet.")) + "</div></div>";
}
function task(id) { return TASKS.filter(function (t) { return t.id === id; })[0]; }
function viewTasks() {
  var mine = TASKS.filter(function (t) { return t.ok; }), n = offers().length, c = nc("minmax(0,1fr) 110px 150px 250px 84px", "minmax(140px,1fr) 64px 92px 68px 76px", 528), rc = nc("minmax(0,1fr) 110px 150px 110px 90px 90px 16px", "minmax(150px,1fr) 72px 96px 76px 80px 56px 16px", 662);
  return head("Tasks", n ? '<a class="btn" href="#/found">' + ic("binoculars") + n + " waiting to be accepted</a>" : "") + '<div class="body">' +
    '<div class="card"><div class="lh cols-task" style="--cols:' + c + '"><span>Task</span><span>Machine</span><span>Last run</span><span>Result</span><span></span></div>' +
    (mine.map(function (t) {
      var last = RUNS.filter(function (r) { return r.t === t.id; })[0];
      return '<div class="li hov cols-task" style="--cols:' + c + '"><div><div class="ti">' + ic("terminal-window") + "<span>" + t.name + '</span></div><code class="cmd">' + t.cmd + "</code></div>" + tag(t.m) + never(last ? last.at : "Never") + (last ? result(last.code) : "<span></span>") + '<button class="btn" type="button" onclick="runTask(\'' + t.id + '\')">' + ic("play") + "Run</button></div>";
    }).join("") || empty("terminal-window", "No task has been accepted yet. Tasks that are waiting are under Found.")) + "</div>" +
    '<div class="card runs"><h2>Recent runs' + chip(RUNS.length) + "</h2>" + (RUNS.length ? '<div class="lh" style="--cols:' + rc + '"><span>Task</span><span>Machine</span><span>Started</span><span>Result</span><span class="r">Took</span><span class="r">Exit code</span><span></span></div>' +
      RUNS.map(function (r, i) { var t = task(r.t); return runRow(rc, '<div class="ti"><span>' + t.name + "</span></div>" + tag(t.m) + mono(r.at) + result(r.code) + '<span class="mono r">' + took(r.dur) + '</span><span class="mono r">' + r.code + "</span>",r.out || t.out, ui.run && !i); }).join("") : empty("clock-countdown", "No task has run yet.")) + "</div></div>";
}
function chTag(w) { var ch = w.ch; return tag(w.who !== "Me" ? ch + ", " + w.who.toLowerCase() : ch === "Page" ? "Page, PagerDuty" : ch === "Digest" ? "Morning digest" : ch === "Push" ? "Push, " + chan.push : ch); }
function viewAlerts() {
  var c = nc("minmax(0,1fr) 190px 140px 34px", "minmax(140px,1fr) 130px 118px 34px", 496), names = MACHINES.map(function (m) { return m.name; });
  MACHINES.forEach(function (m) { m.services.forEach(function (s) { names.push(s.name); }); });
  return head("Alerts", ui.edit ? "" : '<button class="btn primary" type="button" onclick="flip(\'edit\')">' + ic("plus") + "New rule</button>") + '<div class="body">' +
    (ui.edit ? '<div class="card"><h2>New rule</h2><div class="form"><label>What it watches' + sel(names, draft.what, "draft.what=this.value", "What it watches") + "</label><label>When it" + sel(Object.keys(WHEN), draft.when, "draft.when=this.value", "When") + "</label><label>Alerts after" + sel(AFTER, draft.after, "draft.after=this.value", "Alerts after") + "</label><label>Reaches you by" + sel(CHANNELS, draft.ch, "draft.ch=this.value", "Reaches you by") + "</label><label>Who" + sel(["Me", "All owners"], draft.who, "draft.who=this.value", "Who") + '</label></div><div class="foot"><button class="btn primary" type="button" onclick="saveRule()">Save rule</button><button class="btn" type="button" onclick="flip(\'edit\')">Cancel</button></div></div>' : "") +
    '<div class="card"><div class="lh cols-rule" style="--cols:' + c + '"><span>Rule</span><span>Reaches you by</span><span>Alerts after</span><span class="r">On</span></div>' +
    (RULES.map(function (w, i) { return '<div class="li slim cols-rule" style="--cols:' + c + '"><div class="ti">' + ic("bell") + "<span>" + w.name + "</span></div>" + chTag(w) + '<span class="mute">' + w.after + '</span><input class="switch" type="checkbox"' + (w.on ? " checked" : "") + ' onchange="RULES[' + i + '].on=this.checked" aria-label="Rule on"></div>'; }).join("") || empty("bell", "No rules yet. Dokkit will stay quiet until you make one.")) + "</div>" +
    '<div class="card"><h2>Suggestions' + chip(SUGG.length) + "</h2>" +
    (SUGG.map(function (x, i) { return '<div class="li hov cols-act" style="--cols: minmax(0,1fr) auto"><div class="tip">' + ic("lightbulb") + "<span>" + x.text + '</span></div><div style="display:flex; gap:6px"><button class="btn" type="button" onclick="settle(' + i + ', 1)">Accept</button><button class="btn" type="button" onclick="settle(' + i + ')">Dismiss</button></div></div>'; }).join("") || empty("check-circle", "No suggestions right now.")) +
    '<div class="foot">Dokkit only suggests. It never changes a rule by itself.</div></div>' +
    '<div class="card"><h2>Channels</h2><dl class="kv"><dt>Page</dt><dd>Through PagerDuty<span class="hint">For what cannot wait until morning. It keeps ringing until someone answers.</span></dd><dt>Push</dt><dd>' + sel(["PagerDuty low urgency", "ntfy", "Pushover"], chan.push, "chan.push=this.value;render()", "Push goes through", "wide") + '<span class="hint">A notification on your phone, for what should be seen today.</span></dd><dt>Email</dt><dd><input class="inp" type="email" style="width:100%; max-width:420px" value="' + chan.email + '" onchange="chan.email=this.value" aria-label="Email address"><span class="hint">For alerts that can wait until you next read your mail.</span></dd><dt>Text</dt><dd><input class="inp" type="tel" style="width:100%; max-width:420px" value="' + chan.text + '" onchange="chan.text=this.value" aria-label="Mobile number"><span class="hint">A short message to this phone, for when a push might be missed.</span></dd><dt>Digest</dt><dd>' + sel(TIMES, chan.digest, "chan.digest=this.value", "Digest time") + ' every morning<span class="hint">Everything that can wait, in one mail.</span></dd><dt>Webhook</dt><dd><input class="inp" type="url" style="width:100%; max-width:420px" placeholder="https://" value="' + chan.hook + '" onchange="chan.hook=this.value" aria-label="Webhook address"><span class="hint">Dokkit sends each alert to this address, for your own tools to pick up.</span></dd></dl></div></div>';
}
function statCards(s) {
  var d = STATS[s.id], c = nc("minmax(0,1fr) repeat(6, 80px)", "minmax(116px,1fr) repeat(6, 64px)", 616), dv = nc("minmax(0,1fr) repeat(6, 80px)", "minmax(150px,1fr) 60px 64px 48px 56px 80px 64px", 638), q = nc("minmax(0,1fr) 84px", "minmax(150px,1fr) 84px", 280);
  if (!d) return "";
  if (d.upstream) return '<div class="card"><h2>Upstream<span class="end">Last 5 minutes</span></h2>' + tbl(c, ["Service", "Calls", "Errors", "p50", "p95", "Timeouts", "Abandoned"], d.upstream) + "</div>" +
    '<div class="card"><h2>Devices with errors<span class="end">Last 5 minutes</span></h2>' + (d.failing.length ? tbl(dv, ["Device", "Employee", "Requests", "Errors", "Refused", "Rate limited", "Last seen"], d.failing.map(function (f) { return [f[0] + ' <span class="mono mute">' + f[1] + "</span>"].concat(f.slice(2)); })) : '<p class="lead">No device has errors.</p>') + "</div>";
  return '<div class="two"><div class="card"><h2>Work queue<span class="end">Ready by kind</span></h2>' + tbl(q, ["Kind", "Ready"], d.queue) + '</div><div class="card"><h2>Failures<span class="end">Last 24 hours</span></h2>' + tbl(q, ["Kind", "Count"], d.fail) + "</div></div>" +
    '<div class="card"><h2>Storage</h2>' + kv(d.disk) + "</div>";
}
function settingsMore() {
  var c = nc("130px 110px minmax(0,1fr) 120px 84px", "112px 70px minmax(140px,1fr) 86px 72px", 568);
  return '<div class="card"><h2>Keys<span class="end">' + sel(KINDS.map(function (k) { return k[0]; }), keyKind, "keyKind=this.value", "Kind of key", "sm") + '<button class="btn sm primary" type="button" onclick="makeKey()">' + ic("plus") + "New key</button></span></h2>" +
    (newKey ? '<div class="once"><span class="mono">' + newKey + '</span><button class="btn sm" type="button" onclick="copy(\'' + newKey + "')\">" + ic("copy") + 'Copy</button></div><p class="lead" style="padding-top:0">Shown once. Copy it now. Dokkit keeps only a hash of it.</p>' : "") +
    (KEYS.length ? '<div class="lh cols-key" style="--cols:' + c + '"><span>Kind</span><span>Starts with</span><span>What it is for</span><span>Last used</span><span></span></div>' +
      KEYS.map(function (k, i) { return '<div class="li slim hov cols-key" style="--cols:' + c + '"><b style="font-weight:600">' + k.kind + "</b>" + mono(k.key + "…") + '<span class="mute">' + k.use + "</span>" + never(k.last) + '<button class="btn sm" type="button" onclick="revokeKey(' + i + ')">Revoke</button></div>'; }).join("") : empty("key", "No keys. Make an enrolment token to put Dokkit on a machine.")) + "</div>" +
    '<div class="card"><h2>People' + chip(1) + '<span class="end"><button class="btn sm" type="button">' + ic("plus") + 'Add person</button></span></h2><div class="est" style="--cols: auto minmax(0,1fr) auto; align-items:center"><span class="av">' + ME.slice(0, 2).toUpperCase() + "</span><b>" + ME + "</b>" + tag("Owner", "brand") + '</div><div class="lh sub"><span>What each role can do</span></div><dl class="kv"><dt>Owner</dt><dd>Everything, including keys and people.</dd><dt>Member</dt><dd>Sees everything and can act: watch, snooze, accept, run tasks. Cannot make keys or add people.</dd><dt>Viewer</dt><dd>Sees everything except secrets and keys. Cannot change anything.</dd></dl></div>' +
    '<div class="card"><h2>Dokkit itself</h2>' + kv(SELF, "200px minmax(0,1fr)") + "</div>" +
    '<div class="card"><h2>Access for AI tools<span class="end">What a token for them may do</span></h2><dl class="kv"><dt>Address</dt>' + addrRow("https://" + HOST + "/mcp") +
    [["read", "Read", "See states, issues, jobs, deploys and errors."], ["read-logs", "Read logs", "See what is written in the logs."], ["act", "Act", "Snooze, mark as seen and run accepted tasks."]].map(function (x) { return "<dt>" + x[1] + '</dt><dd style="flex-wrap:nowrap; gap:10px"><input class="switch" type="checkbox"' + (mcp[x[0]] ? " checked" : "") + ' onchange="mcp[\'' + x[0] + '\']=this.checked" aria-label="' + x[1] + '"><span class="mute">' + x[2] + "</span></dd>"; }).join("") +
    '</dl><div class="foot">Making keys, managing people and accepting what was found are never offered to AI tools.</div></div>';
}

function viewSettings() {
  // swatches carry the theme classes, so they paint from the same tokens as the page
  var dk = "t-dark" + (look.base !== "neutral" ? " d-" + look.base : ""), th = (look.theme === "dark" ? "t-dark" : "t-light") + " ac";
  function opts(key, list) {
    return '<div class="opts">' + list.map(function (o) {
      return '<button type="button" class="opt' + (look[key] === o[0] ? " on" : "") + '" onclick="setLook(&quot;' + key + "&quot;, &quot;" + o[0] + '&quot;)"><span class="sw ' + o[2] + '"></span>' + o[1] + "</button>";
    }).join("") + "</div>";
  }
  return head("Settings") + '<div class="body set">' + settingsMore() +
    '<div class="card"><h2>Appearance</h2><dl class="kv"><dt>Theme</dt><dd>' + opts("theme", [["light", "Light", "t-light"], ["dark", "Dark", dk]]) + "</dd><dt>Dark base</dt><dd>" + opts("base", [["neutral", "Neutral", "t-dark"], ["plum", "Plum", "t-dark d-plum"], ["slate", "Slate", "t-dark d-slate"]]) + '<span class="hint">Applies in dark</span></dd><dt>Accent</dt><dd>' + opts("accent", [["violet", "Violet", th], ["orange", "Orange", th + " a-orange"], ["blue", "Blue", th + " a-blue"], ["teal", "Teal", th + " a-teal"]]) + "</dd></dl></div></div>";
}

// ---------- actions and router ----------
function snooze(i) { (i == null ? Object.keys(tick).filter(function (k) { return tick[k]; }) : [i]).forEach(function (k) { snoozed[k] = true; }); tick = {}; render(); }
function tickOne(i) { tick[i] = !tick[i]; render(); }
function tickAll(on) { NOW.forEach(function (n, i) { tick[i] = on && !snoozed[i]; }); render(); }
function watch(id) { watched[id] = true; render(); }
function setTab(t) { tab = t; render(); }
function setTheme(t) { setLook("theme", t); }
function flip(k) { ui[k] = !ui[k]; render(); }
function toggleLib(id) { libOpen[id] = !libOpen[id]; render(); }
function pick(id) { picked[id] = !picked[id]; render(); }
function pickAll(on) { found().forEach(function (p) { picked[p[1].id] = on; }); render(); }
function copy(text) { if (navigator.clipboard) navigator.clipboard.writeText(text); }
function sweep(into) { found().forEach(function (p) { if (picked[p[1].id]) into[p[1].id] = true; }); picked = {}; render(); }
function acceptTask(id) { task(id).ok = true; render(); }
function dismissTask(id) { TASKS = TASKS.filter(function (t) { return t.id !== id; }); render(); }
function runTask(id) { RUNS.unshift({ t: id, at: "Just now", code: 0, dur: task(id).dur }); render(); }
function saveRule() { RULES.push({ name: draft.what + " " + WHEN[draft.when], ch: draft.ch, who: draft.who, after: draft.after, on: true }); draft = blank(); ui.edit = false; render(); }
function settle(i, yes) { if (yes) SUGG[i].go(); SUGG.splice(i, 1); render(); }
function makeKey() {
  var p = KINDS.filter(function (k) { return k[0] === keyKind; })[0][1], h = hash(p + KEYS.length), k = p;
  while (k.length < 24) { h = (h * 73 + 19) % 9973; k += "abcdefghjkmnpqrstuvwxyz23456789"[h % 31]; }
  KEYS.unshift({ kind: keyKind, key: k.slice(0, 8), use: "New, not used yet.", last: "Never" }); newKey = k; render();
}
function revokeKey(i) { KEYS.splice(i, 1); render(); }
// the strip under 760 px scrolls sideways: bring the current item to its middle
function centre() {
  var sd = document.getElementById("side"), on = sd.querySelector && (sd.querySelector(".nav.up") || sd.querySelector(".nav.on")), x;
  if (on) {
    x = Math.max(0, Math.min(on.offsetLeft - (sd.clientWidth - on.offsetWidth) / 2, sd.scrollWidth - sd.clientWidth));
    // an item cut by the left edge is shown whole instead
    [].forEach.call(sd.children, function (a) { if (a.offsetLeft < x && a.offsetLeft + a.offsetWidth > x) x = a === sd.firstElementChild ? 0 : a.offsetLeft; });
    sd.scrollLeft = x;
  }
  edges();
}
// which way the strip still scrolls; 16 px is padding, not an item
function edges() { var sd = document.getElementById("side"); if (sd.classList) { sd.classList.toggle("more-l", sd.scrollLeft > 16); sd.classList.toggle("more-r", sd.scrollLeft < sd.scrollWidth - sd.clientWidth - 16); } }
// ui=sx: whatever scrolls sideways in the page is put 90 px along, to show a pinned column at work
function nudge() { [].forEach.call(document.querySelectorAll("#page *"), function (el) { if (el.scrollWidth > el.clientWidth && /auto|scroll/.test(getComputedStyle(el).overflowX)) el.scrollLeft = 90; }); }
function place() { centre(); if (ui.sx && document.querySelectorAll) nudge(); }
// ?y=: scroll there and put the page height in the title, once layout has settled and whenever the height changes
var ro;
function stamp() { window.scrollTo(0, ui.y); document.title = "h=" + document.documentElement.scrollHeight + " " + document.title.replace(/^h=\d+ /, ""); }
function render() {
  var hq = location.hash.replace(/^#\//, "").split("?"), p = hq[0].split("/"), r = p[0] || "inbox", html, active = r;
  var e = r === "e" ? ERRS.filter(function (x) { return x.id === p[1]; })[0] : null;
  if (r !== "settings") newKey = "";
  var m = (r === "m" || r === "s") ? M(p[1]) : null, s = m && r === "s" ? m.services.filter(function (x) { return x.id === p[2]; })[0] : null;
  if (ui.snoozed) { if (e) snoozed[e.id] = true; if (s) NOW.forEach(function (n, i) { if (n.s === s.id) snoozed[i] = true; }); }
  if (r === "s" && s) { html = viewService(m, s); active = "m:" + m.id; }
  else if (r === "m" && m) { html = viewAll(m); active = "m:" + m.id; }
  else if (r === "all") html = viewAll();
  else if (r === "jobs") html = viewJobs();
  else if (r === "logs") html = viewLogs((hq[1] || "").replace(/^s=/, ""));
  else if (r === "errors") html = viewErrors();
  else if (r === "e" && e) { html = viewError(e); active = "errors"; }
  else if (r === "found") html = viewFound();
  else if (r === "versions") html = viewVersions();
  else if (r === "deploys") html = viewDeploys();
  else if (r === "tasks") html = viewTasks();
  else if (r === "alerts") html = viewAlerts();
  else if (r === "settings") html = viewSettings();
  else { html = viewInbox(); active = "inbox"; }
  var keep = "a,button,input,select,summary", was = document.activeElement, box = was && was.closest && was.closest("#side,#page"), at = box ? [].indexOf.call(box.querySelectorAll(keep), was) : -1;
  var sd = document.getElementById("side");
  sd.innerHTML = side(active);
  document.getElementById("page").innerHTML = html;
  if (document.querySelectorAll) [].forEach.call(document.querySelectorAll(".chk[data-some]"), function (c) { c.indeterminate = true; });
  if (at >= 0) { var f = box.querySelectorAll(keep); (f[Math.min(at, f.length - 1)] || box).focus(); }
  // again once the fonts are in, which is when the strip has its real width
  place(); if (document.fonts) document.fonts.ready.then(place);
  var h = document.querySelector && document.querySelector("#page h1");
  if (h) document.title = h.textContent + " | Dokkit";
  if (ui.y != null) document.fonts.ready.then(function () { setTimeout(function () { stamp(); if (!ro && window.ResizeObserver) (ro = new ResizeObserver(stamp)).observe(document.getElementById("page")); }, 300); });
  return h;
}
window.addEventListener("resize", function () { if (document.querySelector(".chart") && chartW() !== CW) render(); else centre(); });
if (document.getElementById("side").addEventListener) document.getElementById("side").addEventListener("scroll", edges);
if (typeof matchMedia === "function") matchMedia(NARROW).addEventListener("change", function () { render(); });
window.addEventListener("hashchange", function () {
  function go() { var h = render(); window.scrollTo(0, 0); if (h) h.focus(); }
  if (document.startViewTransition && !matchMedia("(prefers-reduced-motion: reduce)").matches) document.startViewTransition(go); else go();
});
// states that need a click, opened from the address: ?ui=sel,selall,empty,picked,watched,accepted,q,frames,run,newkey,snoozed,allowner
if (ui.sel) tick[0] = tick[1] = true;
if (ui.selall) NOW.forEach(function (n, i) { tick[i] = true; });
if (ui.empty) NOW.forEach(function (n, i) { snoozed[i] = true; });
if (ui.watched) { found().forEach(function (p) { watched[p[1].id] = true; }); TASKS.forEach(function (t) { t.ok = true; }); }
if (ui.accepted) SUGG.splice(0).forEach(function (x) { x.go(); });
if (ui.allowner) RULES[0].who = "All owners";
if (ui.picked) found().slice(0, 2).forEach(function (p) { picked[p[1].id] = true; });
if (ui.frames) ERRS.forEach(function (e) { libOpen[e.id] = true; });
applyLook();
if (ui.newkey) makeKey(); else render();
