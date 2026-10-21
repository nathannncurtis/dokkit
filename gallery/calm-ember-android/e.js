(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon, app = document.getElementById("app");
  var openMore = {};

  var TONE = { opened: null, reopened: "degraded", acknowledged: "ok", held: "soon", snoozed: "quiet", paged: "down", closed: "ok" };
  function tileTone(c) { return c.down ? (c.planned ? "planned" : "down") : c.inTrouble ? "degraded" : ""; }
  function stateTag(c) {
    if (!c.hardware) return c.inTrouble ? U.tag("degraded", "In trouble") : U.tag("ok", "Fine");
    if (c.down) return U.tag(c.planned ? "quiet" : "down", c.planned ? "Down, planned" : "Down");
    return c.inTrouble ? U.tag("degraded", "Up, in trouble") : U.tag("ok", "Up");
  }

  // ---------- chrome ----------
  function topbar(title, back) {
    var cur = C.selected(), many = C.servers().length > 1;
    return '<header class="topbar">' + (back ? '<button class="iconbtn" type="button" id="back" aria-label="Back">' + icon("arrow-left") + "</button>" : "") +
      '<div class="who"><b>' + esc(title) + "</b>" + (cur && !many ? "<span>" + esc(cur.name) + "</span>" : "") + "</div>" +
      (cur && many ? '<button class="picker" type="button" id="picker" aria-label="Switch server, showing ' + esc(cur.name) + '">' + esc(cur.name) + " " + icon("caret-down") + "</button>" : "") +
      (cur ? '<button class="iconbtn" type="button" id="refresh" aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") + "</header>";
  }
  function tabs(active) {
    var t = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="tabs" aria-label="Main">' + t.map(function (x) {
      return '<a href="#' + x[0] + '"' + (x[0] === active ? ' aria-current="page"' : "") + ">" + icon(x[2]) + x[1] + "</a>";
    }).join("") + "</nav>";
  }
  function simpleTop(title, backTo) {
    return '<header class="topbar"><button class="iconbtn" type="button" data-go="' + backTo + '" aria-label="Cancel">' + icon("arrow-left") + '</button><div class="who"><b>' + esc(title) + "</b></div></header>";
  }

  // ---------- home ----------
  function notice(iconName, title, text) {
    return '<div class="panel pad" style="text-align:center">' + U.ic("quiet", iconName) + '<p class="h2" style="margin-top:10px">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div>";
  }
  function guard(state) {
    var out = U.ageBanner(C.freshness(state));
    if (!state.snapshot) return { html: (state.problem ? out : "") + notice("hourglass-medium", "No snapshot yet", "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again."), snap: null };
    var lo = C.leftOut(state.snapshot);
    return { html: out + (lo ? '<p class="sub left-out">' + icon("info") + " " + esc(lo) + "</p>" : ""), snap: state.snapshot };
  }
  function events(snap) {
    var list = [];
    snap.issues.forEach(function (i) {
      (i.history || []).forEach(function (e) { list.push({ i: i, e: e }); });
    });
    list.sort(function (a, b) { return new Date(b.e.at) - new Date(a.e.at); });
    return list.slice(0, 6);
  }
  function feed(snap) {
    var ev = events(snap);
    if (!ev.length) return "";
    return '<div class="sec"><h2>What happened</h2><span>latest ' + ev.length + '</span></div><ol class="feed panel pad">' + ev.map(function (x) {
      var tone = TONE[x.e.event] || C.level(C.issueState(x.i) === "soon" ? "soon" : x.i.state).tone;
      var verb = C.cap(x.e.event || "event") + (x.e.by ? " by " + x.e.by : "") + (x.e.note ? ", " + x.e.note : "");
      return '<li><span class="dot t-' + tone + '" aria-hidden="true"></span><a href="#service/' + x.i.service + '"><div class="what">' + esc(verb) + ": <b>" + esc(x.i.title) + '</b></div><div class="when">' + esc(C.ago(x.e.at)) + " · " + esc(x.i.short_id) + "</div></a></li>";
    }).join("") + "</ol>";
  }
  function tile(c) {
    var worst = c.meters.slice().sort(function (a, b) { return b.percent - a.percent; })[0];
    return '<a class="tile ' + tileTone(c) + '" href="#machine/' + encodeURIComponent(c.id) + '" aria-label="' + esc(c.name + ", " + (c.status || c.counts)) + '">' +
      '<span class="tn' + (c.hardware ? "" : " group") + '">' + esc(c.name) + "</span>" + stateTag(c) +
      (c.lastDay ? U.strip(c.id, true) : "") +
      (worst ? '<div class="worst">' + U.meter(worst) + "</div>" : '<div class="worst"></div>') +
      '<span class="counts">' + esc(c.counts) + "</span></a>";
  }
  function home() {
    var cur = C.selected();
    if (!cur) return U.phone({ body: U.firstRun(), bottom: tabs("home") });
    var g = guard(cur.state), body;
    if (!g.snap) body = '<div class="page settle"><div class="note-head"><p class="eyebrow">' + esc(dateLine()) + '</p><h1 class="title">Waiting for the first snapshot</h1></div>' + g.html + "</div>";
    else {
      var h = C.home(g.snap), urgent = h.top.kind === "attention";
      var title = h.top.kind === "fine" ? h.top.headline : h.needs.length ? C.plural(h.needs.length, "thing needs you", "things need you") : C.plural(h.soon.length, "thing is coming up", "things are coming up");
      var lede = h.needs.length ? h.lede.replace(/^[^.]*\.\s*/, "") : h.lede;
      body = '<div class="page settle"><div class="note-head"><p class="eyebrow">' + esc(dateLine()) + '</p><h1 class="title ' + (urgent ? "alert" : "calm") + '">' + esc(title) + '</h1><p class="lede">' + esc(lede) + "</p></div>" + g.html +
        (h.top.kind === "fine" ? '<div class="top-fine">' + U.ic("ok", "check-circle") + "<div><b>" + esc(h.top.headline) + "</b><span>" + esc(h.top.detail) + "</span></div></div>" : "") +
        (h.needs.length ? '<div class="sec"><h2>Needs you</h2><span>' + h.needs.length + "</span></div>" + h.needs.map(function (i) { return U.issueCard(i, g.snap, "#service/" + i.service); }).join("") : "") +
        (h.soon.length ? '<div class="sec"><h2>Coming up</h2><span>' + h.soon.length + "</span></div>" + h.soon.map(function (i) { return U.issueCard(i, g.snap, "#service/" + i.service); }).join("") : "") +
        (h.snoozed ? '<a class="quiet-line" href="#service/' + h.snoozedList[0].service + '">' + icon("moon") + esc(h.snoozed) + '<span class="sub mono" style="margin-left:auto">' + esc(h.snoozedList.map(function (i) { return i.short_id; }).join(", ")) + "</span></a>" : "") +
        (h.fineLine ? '<div class="allgood">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>' : "") +
        feed(g.snap) +
        (h.hardware.length ? '<div class="sec"><h2>Machines</h2><span>' + h.hardware.length + '</span></div><div class="tiles">' + h.hardware.map(tile).join("") + "</div>" : "") +
        (h.hardware.length ? U.legend() : "") +
        (h.groups.length ? '<div class="sec"><h2>Not on a machine</h2><span>' + h.groups.length + '</span></div><div class="tiles">' + h.groups.map(tile).join("") + "</div>" : "") +
        "</div>";
    }
    return U.phone({ top: topbar("Home"), body: '<div class="ptr" id="ptr" aria-hidden="true">' + icon("arrows-clockwise") + "</div>" + body, bottom: tabs("home") });
  }
  function dateLine() { return new Date(C.P.now).toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" }) + " · " + C.greeting().toLowerCase(); }

  // ---------- machine ----------
  function kidRow(r) {
    return '<a href="#service/' + r.id + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="n">' + esc(r.name) + '</span><span class="sub">' + esc(r.level.word) + "</span></a>";
  }
  function machine(id) {
    var cur = C.selected(), snap = cur && cur.state.snapshot, m = snap && C.machineById(snap, id);
    var body;
    if (!m) body = '<div class="page settle">' + notice("question", "Not in this snapshot", "The newest snapshot no longer lists this machine.") + "</div>";
    else {
      var c = C.card(m), more = openMore[c.id], tone = c.down ? (c.planned ? "quiet" : "down") : c.inTrouble ? "degraded" : "ok";
      var mine = snap.issues.filter(function (i) { return i.machine === m.id && !i.closed_at; });
      var empty = !c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine;
      body = '<div class="page settle"><div class="hero">' + U.ic(tone, c.hardware ? (c.down ? "power" : "hard-drives") : "squares-four", "lg") +
        '<div><p class="eyebrow">' + stateTag(c) + (m.os ? ' <span class="mono">' + esc(m.os) + "</span>" : "") + '</p><h1 class="title' + (c.hardware ? " mono" : "") + '">' + esc(c.name) + "</h1>" +
        '<div class="facts">' + (c.status ? '<span class="mono">' + esc(c.status) + "</span>" : "") + "<span>" + esc(c.counts) + "</span>" + (c.notice ? "<span>" + icon("calendar") + " " + esc(c.notice) + "</span>" : "") + "</div></div></div>" +
        (c.meters.length ? '<section class="panel pad"><div class="meters">' + c.meters.map(U.meter).join("") + "</div></section>" : "") +
        (c.lastDay ? '<section class="panel pad stack" style="gap:10px"><span class="h2">The last day</span><p class="sub">Each block is half an hour.</p>' + U.strip(c.id) + '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div>' + U.legend() + "</section>" : "") +
        (mine.length ? '<div class="sec"><h2>Needs a look</h2><span>' + mine.length + "</span></div>" + mine.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") : "") +
        '<div class="sec"><h2>Services</h2><span>' + esc(c.counts) + '</span></div><section class="panel rows">' +
        (empty ? '<div class="line">Nothing is watched on it.</div>' : "") +
        c.trouble.map(kidRow).join("") + c.fine.map(kidRow).join("") + (more ? c.moreFine.map(kidRow).join("") : "") +
        (c.moreFine.length ? '<div><button class="more" type="button" id="more">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button></div>" : "") +
        (c.quietLine ? '<div class="line">' + esc(c.quietLine) + "</div>" : "") + "</section></div>";
    }
    return U.phone({ top: topbar(m ? (m.kind === "enrolled" ? "Machine" : "Group") : "Machine", true), body: '<div class="ptr" id="ptr" aria-hidden="true">' + icon("arrows-clockwise") + "</div>" + body, bottom: tabs("home") });
  }

  // ---------- service ----------
  function story(v, snap) {
    var i = v.issue, st = C.issueState(i), lv = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(st);
    var fl = C.flags(i), meta = [C.names(snap)[i.service], i.machine, "open " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
    var hist = v.history.slice().reverse();
    return '<section class="panel story"><div class="panel-pad-h" style="padding:0"><span class="h2">The story so far</span><span class="sub mono">' + esc(i.short_id) + "</span></div>" +
      '<p class="eyebrow" style="margin-top:8px">' + U.tag(lv.tone, lv.word) + '</p><h2 class="h2" style="font-size:18px">' + esc(i.title) + "</h2>" +
      (i.note ? '<p class="note t-' + lv.tone + '">' + esc(i.note) + "</p>" : "") +
      '<p class="meta">' + meta.map(function (x) { return "<span>" + esc(x) + "</span>"; }).join("") + "</p>" +
      (fl.length ? '<div class="flags">' + fl.map(function (f) { return U.tag(f.tone, f.text); }).join("") + "</div>" : "") +
      (hist.length ? '<ol class="feed">' + hist.map(function (h, k) {
        var ev = (i.history || []).slice().reverse()[k], tone = TONE[ev && ev.event] || lv.tone;
        return '<li><span class="dot t-' + tone + '" aria-hidden="true"></span><div><div class="what">' + esc(h.text) + '</div><div class="when">' + esc(h.ago || "") + (h.when ? " · " + esc(h.when) : "") + "</div></div></li>";
      }).join("") + "</ol>" : "") + "</section>";
  }
  function service(id) {
    var cur = C.selected(), snap = cur && cur.state.snapshot, v = snap && C.service(snap, id), body;
    if (!v) body = '<div class="page settle">' + notice("info", "Not in this snapshot", "The newest snapshot no longer lists this service.") + "</div>";
    else {
      var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
      body = '<div class="page settle"><div class="hero">' + U.ic(v.level.tone, v.level.icon, "lg") + '<div><p class="eyebrow">' + U.tag(v.level.tone, v.level.word) +
        (v.machine ? ' <a class="mono" href="#machine/' + encodeURIComponent(v.machine) + '">' + esc(v.machine) + "</a>" : "") + '</p><h1 class="title mono">' + esc(v.name) + "</h1>" +
        (v.note ? '<p class="lede" style="font-size:15.5px">' + esc(v.note) + "</p>" : "") + (line ? '<p class="sub mono" style="margin-top:4px">' + esc(line) + "</p>" : "") + "</div></div>" +
        (v.issue ? story(v, snap) : "") +
        (v.checks.length ? '<section class="panel"><div class="panel-pad-h"><span class="h2">Checks</span><span class="sub">' + v.checks.length + '</span></div><div class="rows">' + v.checks.map(function (c) {
          return '<div class="chk"><div class="top"><b>' + esc(c.name) + "</b>" + U.tag(c.level.tone, c.level.word) + "</div>" + (c.note ? '<span class="sub">' + esc(c.note) + "</span>" : "") + (c.checked ? '<span class="sub mono">Checked ' + esc(c.checked) + "</span>" : "") + "</div>";
        }).join("") + "</div></section>" : "") +
        (v.job.length ? '<section class="panel"><div class="panel-pad-h"><span class="h2">Job</span></div><div class="rows">' + v.job.map(function (j) { return '<div class="kv"><span>' + esc(j[0]) + "</span><b>" + esc(j[1]) + "</b></div>"; }).join("") + "</div></section>" : "") +
        (v.chart.some(function (x) { return x != null; }) ? '<section class="panel pad stack" style="gap:10px"><div style="display:flex;justify-content:space-between;gap:8px"><span class="h2">Last 24 hours</span>' + (v.metric ? '<span class="sub mono">' + esc(v.metric) + "</span>" : "") + "</div>" + U.chart(v.chart, v.metric) + '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></section>' : "") +
        (v.logs.length ? '<section class="panel"><div class="panel-pad-h"><span class="h2">Last log lines</span><span class="sub">' + v.logs.length + '</span></div><div style="padding:10px 8px 8px">' + U.logLines(v.logs) + "</div></section>" : "") +
        "</div>";
    }
    return U.phone({ top: topbar("Service", true), body: '<div class="ptr" id="ptr" aria-hidden="true">' + icon("arrows-clockwise") + "</div>" + body, bottom: tabs("home") });
  }

  // ---------- the rest ----------
  function servers() {
    return U.phone({ top: '<header class="topbar"><div class="who"><b>Servers</b><span>' + C.plural(C.servers().length, "paired", "paired") + "</span></div></header>",
      body: '<div class="page settle">' + U.serversList() + "</div>", bottom: tabs("servers") });
  }
  function settings() {
    return U.phone({ top: '<header class="topbar"><div class="who"><b>Settings</b><span>this phone</span></div></header>',
      body: '<div class="page settle"><p class="lede" style="font-size:15.5px">What the app decides on its own. Each starts at the value it has always had.</p>' + U.settingsGroups() + U.about() + "</div>", bottom: tabs("settings") });
  }

  // ---------- router ----------
  function render(keepScroll) {
    var y = keepScroll && document.getElementById("screen") ? document.getElementById("screen").scrollTop : 0;
    var r = (location.hash || "#home").slice(1).split("/"), page = r[0];
    var html;
    if (page === "lock") html = U.phone({ body: U.lockScreen() });
    else if (page === "first") html = U.phone({ body: U.firstRun() });
    else if (page === "add") html = U.phone({ top: simpleTop("Add a server", C.servers().length ? "#servers" : "#first"), body: U.addServer(r[1]) });
    else if (page === "service") html = service(decodeURIComponent(r[1] || ""));
    else if (page === "machine") html = machine(decodeURIComponent(r[1] || ""));
    else if (page === "servers") html = servers();
    else if (page === "settings") html = settings();
    else html = home();
    app.innerHTML = html;
    var s = document.getElementById("screen");
    if (keepScroll) s.scrollTop = y;
    wire();
    U.wire(render);
    var h1 = app.querySelector("h1");
    document.title = "Dokkit Today";
    return h1;
  }

  function wire() {
    var back = document.getElementById("back");
    if (back) back.onclick = function () { history.length > 1 ? history.back() : (location.hash = "#home"); };
    var ref = document.getElementById("refresh");
    if (ref) ref.onclick = function () { spinOnce(); };
    var pick = document.getElementById("picker");
    if (pick) pick.onclick = function () {
      var cur = C.selected();
      U.openLayer('<span class="h2">Show a server</span><div class="pick-list">' + C.servers().map(function (s) {
        return '<button type="button" data-pick="' + s.id + '"><span class="n">' + esc(s.name) + "</span>" + (s.id === cur.id ? icon("check") : "") + "</button>";
      }).join("") + "</div>", "sheet");
      setTimeout(function () {
        document.querySelectorAll("[data-pick]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.pick); U.closeLayer(); setTimeout(function () { render(); U.toast("Showing " + C.selected().name + "."); }, 220); }; });
      }, 0);
    };
    var more = document.getElementById("more");
    if (more) more.onclick = function () { var id = decodeURIComponent(location.hash.split("/")[1]); openMore[id] = !openMore[id]; render(true); };
    pullToRefresh();
  }

  function spinOnce() {
    var p = document.getElementById("ptr");
    if (p) { p.classList.add("show"); p.querySelector("i").classList.add("spin"); }
    U.fakeRefresh(function () { if (p) { p.classList.remove("show"); p.querySelector("i").classList.remove("spin"); } });
  }
  function pullToRefresh() {
    var s = document.getElementById("screen"), p = document.getElementById("ptr");
    if (!s || !p) return;
    var startY = null, pulled = false;
    s.addEventListener("pointerdown", function (e) { startY = s.scrollTop <= 0 ? e.clientY : null; pulled = false; });
    s.addEventListener("pointermove", function (e) {
      if (startY == null) return;
      var d = e.clientY - startY;
      if (d > 64 && !pulled) { pulled = true; p.classList.add("show"); }
    });
    var end = function () { if (pulled) spinOnce(); startY = null; pulled = false; };
    s.addEventListener("pointerup", end);
    s.addEventListener("pointercancel", function () { startY = null; if (pulled) p.classList.remove("show"); pulled = false; });
    s.addEventListener("touchstart", function (e) { startY = s.scrollTop <= 0 ? e.touches[0].clientY : null; pulled = false; }, { passive: true });
    s.addEventListener("touchmove", function (e) {
      if (startY == null) return;
      if (e.touches[0].clientY - startY > 64 && !pulled) { pulled = true; p.classList.add("show"); }
    }, { passive: true });
    s.addEventListener("touchend", end);
  }

  window.addEventListener("hashchange", function () {
    render();
    var s = document.getElementById("screen"); if (s) { s.scrollTop = 0; s.focus({ preventScroll: true }); }
  });
  if (!location.hash) history.replaceState(null, "", location.pathname + location.search + U.startRoute());
  render();
})();
