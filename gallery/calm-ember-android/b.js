(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var app = document.getElementById("app");
  var open = {}, more = {}, under = "#home", stack = [];

  // ---------- chrome ----------
  function topbar(title, o) {
    o = o || {};
    var sel = C.selected(), many = C.servers().length > 1;
    return '<header class="b-top">' +
      (o.back ? '<button class="iconbtn" type="button" data-back aria-label="Back">' + icon("arrow-left") + "</button>" : "") +
      '<div class="b-top-t"><h1>' + esc(title) + "</h1>" + (sel && !o.noServer ? '<p class="sub mono">' + esc(sel.name) + "</p>" : "") + "</div>" +
      (many && !o.noServer ? '<button class="iconbtn" type="button" id="pick" aria-label="Switch server">' + icon("swap") + "</button>" : "") +
      (o.refresh ? '<button class="iconbtn" type="button" id="refresh" aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") + "</header>";
  }
  function nav(tab) {
    var tabs = [["home", "house", "Home"], ["servers", "hard-drives", "Servers"], ["settings", "gear", "Settings"]];
    return '<nav class="b-nav" aria-label="Main">' + tabs.map(function (t) {
      return '<a href="#' + t[0] + '"' + (t[0] === tab ? ' aria-current="page"' : "") + '><span class="b-nav-i">' + icon(t[1]) + "</span><span>" + t[2] + "</span></a>";
    }).join("") + "</nav>";
  }
  var PTR = '<div class="b-ptr" id="ptr" aria-hidden="true"><span class="spin">' + icon("arrows-clockwise") + "</span></div>";

  // ---------- home ----------
  function counter(n, word, tone, ic) {
    return '<div class="b-count t-' + (n ? tone : "quiet") + '">' + icon(ic) + '<b class="mono">' + n + "</b><span>" + word + "</span></div>";
  }
  function topBox(h, snap) {
    var t = h.top;
    if (t.kind === "fine") return '<section class="b-topbox t-ok">' + U.ic("ok", "check-circle", "sm") + '<div><p class="h2">' + esc(t.headline) + '</p><p class="sub">' + esc(t.detail) + "</p></div></section>";
    return '<section class="b-topbox ' + (t.urgent ? "t-down" : "t-soon") + '"><p class="h2">' + esc(t.title) + "</p>" +
      t.issues.map(function (i) {
        return '<a class="b-topline" href="#service/' + i.service + '"><span class="pip ' + (t.urgent ? i.state : "soon") + '"></span><span><b>' + esc(i.title) + '</b><span class="sub mono">' + esc(C.issueLine(i, snap)) + "</span></span>" + icon("caret-right") + "</a>";
      }).join("") + "</section>";
  }
  function machineIssues(snap, id) {
    var ib = snap.inbox, all = (ib.needs_you || []).concat(ib.soon || [], ib.snoozed || []);
    return all.filter(function (i) { return i.machine === id; });
  }
  function issueRow(i, snap) {
    var st = C.issueState(i), lv = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(st);
    var fl = C.flags(i);
    return '<div class="b-iss ' + st + '">' + U.ic(lv.tone, lv.icon, "sm") + '<div class="b-iss-b"><p class="b-iss-t">' + esc(i.title) + '</p><p class="sub">' + esc(C.sentence(i, snap)) + "</p>" +
      '<p class="b-meta mono">' + esc(i.short_id) + (i.count > 1 ? " · " + i.count + " times" : "") + "</p>" +
      (fl.length ? '<div class="b-flags">' + fl.map(function (f) { return U.tag(f.tone, f.text); }).join("") + "</div>" : "") +
      '<a class="btn soft" href="#service/' + i.service + '">' + esc(C.nextStep(i)) + " " + icon("arrow-right") + "</a></div></div>";
  }
  function svcRow(r) {
    return '<a class="b-svc" href="#service/' + r.id + '"><span class="pip ' + r.level.tone + '"></span><span class="mono b-svc-n">' + esc(r.name) + '</span><span class="b-svc-w">' + esc(r.level.word) + "</span>" + icon("caret-right") + "</a>";
  }
  function kids(c) {
    var empty = !c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine;
    var m = more[c.id];
    return '<div class="b-kids">' + (empty ? '<p class="sub b-line">Nothing is watched on it.</p>' : "") +
      c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (m ? c.moreFine.map(svcRow).join("") : "") +
      (c.moreFine.length ? '<button class="b-more" type="button" data-more="' + c.id + '">' + (m ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>" : "") +
      (c.quietLine ? '<p class="sub b-line">' + esc(c.quietLine) + "</p>" : "") + "</div>";
  }
  function machineCard(c, snap) {
    var tone = c.down ? "down" : c.inTrouble ? "degraded" : "ok", isOpen = !!open[c.id];
    var word = c.word || (c.inTrouble ? "Trouble" : "Fine");
    var issues = machineIssues(snap, c.id);
    return '<section class="panel b-card' + (c.down || c.inTrouble ? " hot" : "") + '">' +
      '<button class="b-card-h t-' + (c.down || c.inTrouble ? tone : "plain") + '" type="button" data-toggle="' + c.id + '" aria-expanded="' + isOpen + '">' +
      '<span class="b-card-row"><span class="pip ' + tone + '"></span><span class="b-name mono">' + esc(c.name) + "</span>" + U.tag(c.down ? "down" : c.hardware ? "ok" : tone, word) +
      '<span class="b-chev">' + icon(isOpen ? "caret-up" : "caret-down") + "</span></span>" +
      (c.status ? '<span class="sub b-status">' + esc(c.status.replace(/^(Up|Down) · /, "")) + (c.os ? " · " + esc(c.os) : "") + "</span>" : "") + "</button>" +
      '<div class="b-card-b">' +
      (c.lastDay ? U.strip(c.id) : "") +
      (c.meters.length ? '<div class="b-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
      '<p class="sub b-counts">' + esc(c.counts) + "</p>" +
      (c.notice ? '<p class="b-notice t-quiet">' + icon("calendar") + " " + esc(c.notice) + "</p>" : "") +
      (issues.length ? '<div class="b-issues">' + issues.map(function (i) { return issueRow(i, snap); }).join("") + "</div>" : "") +
      (c.hardware ? '<a class="b-open" href="#machine/' + c.id + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
      "</div>" + (isOpen ? kids(c) : "") + "</section>";
  }
  function noSnapshot() {
    return '<section class="panel pad b-notice-big">' + U.ic("quiet", "hourglass-medium") + '<p class="h2">No snapshot yet</p><p class="sub">This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.</p></section>';
  }
  function noServer() {
    return '<section class="panel pad b-notice-big">' + U.ic("quiet", "device-mobile") + '<p class="h2">No server paired</p><p class="sub">In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.</p></section>';
  }
  function homeBody() {
    var sel = C.selected();
    if (!sel) return noServer();
    var st = sel.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) return U.ageBanner(f) + noSnapshot();
    var h = C.home(snap), lo = C.leftOut(snap);
    return '<div class="b-counts-row">' + counter(h.needs.length, "need you", "down", "warning-octagon") + counter(h.soon.length, "coming up", "soon", "calendar") + counter(h.snoozedList.length, "snoozed", "quiet", "moon") + "</div>" +
      U.ageBanner(f) + (lo ? '<p class="sub b-left">' + icon("info") + " " + esc(lo) + "</p>" : "") +
      topBox(h, snap) + (h.snoozed ? '<p class="sub b-snz">' + icon("moon") + " " + esc(h.snoozed) + "</p>" : "") +
      '<h2 class="group-h">' + icon("hard-drives") + " Machines</h2>" +
      '<div class="b-cards">' + h.hardware.map(function (c) { return machineCard(c, snap); }).join("") + "</div>" +
      (h.groups.length ? '<h2 class="group-h">' + icon("cloud") + " Not on a machine</h2>" + '<div class="b-cards">' + h.groups.map(function (c) { return machineCard(c, snap); }).join("") + "</div>" : "") +
      (h.fineLine ? '<div class="allgood">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>' : "") +
      (C.servers().length > 1 ? "" : "");
  }

  // ---------- service (as a sheet) ----------
  function serviceBody(id) {
    var sel = C.selected(), snap = sel && sel.state.snapshot;
    var v = snap && C.service(snap, id);
    if (!v) return '<div class="b-sheet-h"><button class="iconbtn" type="button" data-close aria-label="Close">' + icon("x") + '</button></div><div class="b-notice-big">' + U.ic("quiet", "info") + '<p class="h2">Not in this snapshot</p><p class="sub">The newest snapshot no longer lists this service.</p></div>';
    var f = C.freshness(sel.state), tone = v.level.tone;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var out = '<div class="b-sheet-h">' + U.ic(tone, v.level.icon) + '<div class="b-sheet-t"><h2 class="mono">' + esc(v.name) + '</h2><p class="sub">on <a class="mono" href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a></p></div>" +
      '<button class="iconbtn" type="button" data-close aria-label="Close">' + icon("x") + "</button></div>" +
      '<div class="b-sheet-b settle"><div class="b-state">' + U.tag(tone === "quiet" ? "quiet" : tone, v.level.word) + (line ? '<span class="sub mono">' + esc(line) + "</span>" : "") + "</div>" +
      (v.note ? '<p class="b-note t-' + tone + '">' + esc(v.note) + "</p>" : "") + (f.warn || f.detail ? U.ageBanner(f) : "");
    if (v.issue) {
      var i = v.issue, st = C.issueState(i), fl = C.flags(i);
      var meta = [C.names(snap)[i.service], i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean).join(" · ");
      out += '<section class="b-sec"><div class="b-sec-h"><span class="h2">Open issue</span><span class="sub mono">' + esc(i.short_id) + "</span></div>" +
        '<div class="b-oi ' + st + '">' + U.tag(st === "soon" ? "soon" : C.level(st).tone, st === "soon" ? "Coming up" : C.level(st).word) + '<p class="b-oi-t">' + esc(i.title) + "</p>" +
        (i.note ? '<p class="sub">' + esc(i.note) + "</p>" : "") + '<p class="sub mono b-meta">' + esc(meta) + "</p>" +
        (fl.length ? '<div class="b-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="b-hist">' + v.history.map(function (h) { return "<li><span>" + esc(h.text) + '</span><span class="sub mono">' + esc(h.when || "") + "</span></li>"; }).join("") + "</ol>" : "") + "</section>";
    }
    if (v.checks.length) out += '<section class="b-sec"><div class="b-sec-h"><span class="h2">Checks</span><span class="sub mono">' + v.checks.length + "</span></div>" +
      v.checks.map(function (c) { return '<div class="b-check"><span class="pip ' + c.level.tone + '"></span><div><p class="b-check-n mono">' + esc(c.name) + ' <span class="b-svc-w">' + esc(c.level.word) + "</span></p>" + (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>"; }).join("") + "</section>";
    if (v.job.length) out += '<section class="b-sec"><div class="b-sec-h"><span class="h2">Job</span></div><dl class="b-dl">' + v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl></section>";
    if (v.chart.some(function (x) { return x != null; })) out += '<section class="b-sec"><div class="b-sec-h"><span class="h2">Last 24 hours</span>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" + U.chart(v.chart, v.metric) + '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></section>';
    if (v.logs.length) out += '<section class="b-sec"><div class="b-sec-h"><span class="h2">Last log lines</span><span class="sub mono">' + v.logs.length + "</span></div>" + U.logLines(v.logs) + "</section>";
    return out + "</div>";
  }

  // ---------- machine page ----------
  function machineBody(id) {
    var sel = C.selected(), snap = sel && sel.state.snapshot, m = snap && C.machineById(snap, id);
    if (!m) return '<div class="b-notice-big">' + U.ic("quiet", "info") + '<p class="h2">Not in this snapshot</p><p class="sub">The newest snapshot no longer lists this machine.</p></div>';
    var c = C.card(m), tone = c.down ? "down" : c.inTrouble ? "degraded" : "ok", issues = machineIssues(snap, id);
    var lede = c.down ? "Not reporting." + (c.planned ? " It is in planned downtime, so that is expected." : "") : c.inTrouble ? C.plural(c.trouble.length, "service needs", "services need") + " a look here." : "All good here.";
    var all = c.trouble.concat(c.fine, c.moreFine);
    return '<div class="b-page settle"><header class="b-hero t-' + tone + '">' + U.ic(tone, c.down ? "warning-octagon" : c.inTrouble ? "hourglass-medium" : "check-circle", "lg") +
      '<div><p class="eyebrow">' + U.tag(c.down ? "down" : "ok", c.word || "Fine") + " " + esc(c.os || "") + '</p><h2 class="b-hero-n mono">' + esc(c.name) + '</h2><p class="lede">' + esc(lede) + "</p>" + (c.status ? '<p class="sub mono">' + esc(c.status) + "</p>" : "") + "</div></header>" +
      U.ageBanner(C.freshness(sel.state)) +
      (c.notice ? '<p class="b-notice t-quiet">' + icon("calendar") + " " + esc(c.notice) + "</p>" : "") +
      (c.meters.length ? '<div class="b-vitals">' + c.meters.map(function (x) {
        return '<div class="panel b-vital"><span class="sub">' + esc(x.label) + (x.subject ? ' <span class="mono">' + esc(x.subject) + "</span>" : "") + '</span><span class="b-big mono' + (x.hot ? " hot" : "") + '">' + x.percent + "<small>%</small></span>" +
          '<div class="meter" role="meter" aria-label="' + esc(x.label) + '" aria-valuenow="' + x.percent + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (x.hot ? "hot" : "") + '" style="width:' + x.percent + '%"></b></div></div>';
      }).join("") + "</div>" : "") +
      (c.lastDay ? '<section class="panel pad"><p class="h2">The last day</p><p class="sub" style="margin-bottom:12px">Each block is half an hour.</p>' + U.strip(c.id) + '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div style="margin-top:10px">' + U.legend() + "</div></section>" : "") +
      (issues.length ? '<h2 class="group-h">Needs a look</h2><div class="stack">' + issues.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div>" : "") +
      '<section class="panel"><div class="b-sec-h pad"><span class="h2">Services</span><span class="sub mono">' + esc(c.counts) + "</span></div>" +
      (all.length ? all.map(svcRow).join("") : '<p class="sub b-line">Nothing is watched on it.</p>') + (c.quietLine ? '<p class="sub b-line">' + esc(c.quietLine) + "</p>" : "") + "</section></div>";
  }

  // ---------- pages ----------
  function page(route) {
    var parts = route.slice(1).split("/"), r = parts[0] || "home";
    if (r === "lock") return { body: U.lockScreen() };
    if (r === "first") return { body: U.firstRun() };
    if (r === "add") return { top: topbar("Add a server", { back: true, noServer: true }), body: U.addServer(parts[1]) };
    if (r === "servers") return { top: topbar("Servers", { noServer: true }), body: '<div class="pad-screen settle">' + U.serversList() + "</div>", bottom: nav("servers") };
    if (r === "settings") return { top: topbar("Settings", { noServer: true }), body: '<div class="pad-screen settle"><p class="lede">How this phone shows your servers. Each starts at today\'s value.</p>' + U.settingsGroups() + U.about() + "</div>", bottom: nav("settings") };
    if (r === "machine") return { top: topbar("Machine", { back: true, refresh: true }), body: PTR + machineBody(parts[1]), bottom: nav("home"), ptr: true };
    if (!C.servers().length) return { body: U.firstRun() };
    return { top: topbar("Home", { refresh: true }), body: PTR + '<div class="pad-screen settle b-home">' + homeBody() + "</div>", bottom: nav("home"), ptr: true };
  }

  function render(keepScroll) {
    var route = location.hash || UI.startRoute(), parts = route.slice(1).split("/");
    var sheetId = parts[0] === "service" ? parts[1] : null;
    if (!sheetId) under = route;
    var scroll = keepScroll && document.getElementById("screen") ? document.getElementById("screen").scrollTop : 0;
    var p = page(sheetId ? under : route);
    app.innerHTML = U.phone(p);
    var scr = document.getElementById("screen");
    if (scroll) scr.scrollTop = scroll;
    if (sheetId) { U.openLayer(serviceBody(sheetId), "sheet"); document.querySelector("#layer .sheet") && document.querySelector("#layer .sheet").classList.add("b-sheet"); }
    if (p.ptr) pull(scr);
    wire();
    U.wire(render);
  }

  function back() {
    if (stack.length > 1) history.back();
    else location.hash = (location.hash || "").indexOf("#service/") === 0 && under !== location.hash ? under : "#home";
  }

  function wire() {
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = back; });
    document.querySelectorAll("[data-toggle]").forEach(function (b) { b.onclick = function () { open[b.dataset.toggle] = !open[b.dataset.toggle]; render(true); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { more[b.dataset.more] = !more[b.dataset.more]; render(true); }; });
    var r = document.getElementById("refresh"); if (r) r.onclick = function () { U.fakeRefresh(); };
    var pk = document.getElementById("pick");
    if (pk) pk.onclick = function () {
      var cur = C.selected();
      U.openLayer('<p class="h2" style="margin-bottom:8px">Show a server</p>' + C.servers().map(function (s) {
        return '<button class="b-pick" type="button" data-pickid="' + s.id + '"><span class="mono">' + esc(s.name) + "</span>" + (s.id === cur.id ? icon("check") : "") + "</button>";
      }).join(""), "sheet");
      setTimeout(function () {
        document.querySelectorAll("[data-pickid]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.pickid); U.closeLayer(); setTimeout(render, C.reduced ? 0 : 230); }; });
      }, 0);
    };
  }

  // Closing the service sheet goes back to the page under it.
  document.addEventListener("click", function (e) {
    if (e.target.closest("[data-close]") && (location.hash || "").indexOf("#service/") === 0) setTimeout(back, C.reduced ? 0 : 200);
  });

  function pull(scr) {
    var y0 = null, ptr = document.getElementById("ptr");
    scr.addEventListener("pointerdown", function (e) { y0 = scr.scrollTop <= 0 ? e.clientY : null; });
    scr.addEventListener("pointermove", function (e) {
      if (y0 == null) return;
      var d = e.clientY - y0;
      if (d > 0) ptr.style.height = Math.min(56, d / 2) + "px";
    });
    function end(e) {
      if (y0 == null) return;
      var d = e.clientY - y0; y0 = null;
      if (d > 80) { ptr.classList.add("on"); U.fakeRefresh(function () { ptr.classList.remove("on"); ptr.style.height = ""; }); }
      else ptr.style.height = "";
    }
    scr.addEventListener("pointerup", end); scr.addEventListener("pointercancel", end);
  }

  window.addEventListener("hashchange", function () {
    if (stack.length > 1 && stack[stack.length - 2] === location.hash) stack.pop(); else stack.push(location.hash);
    render();
  });
  if (!location.hash) history.replaceState(null, "", U.startRoute());
  stack.push(location.hash);
  render();
})();
