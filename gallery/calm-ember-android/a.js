// Direction A: the web app's inbox on a phone.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var app = document.getElementById("app");
  var openMachines = {}, openMore = {};

  function routeParts() { return (location.hash.slice(1) || "home").split("/"); }

  // ---------- chrome ----------
  function topBar(title, back) {
    var s = C.selected(), many = C.servers().length > 1;
    return '<header class="a-top">' +
      (back ? '<button class="iconbtn" type="button" id="back" aria-label="Back">' + icon("arrow-left") + "</button>" : "") +
      '<div class="a-top-t"><span class="a-top-h">' + esc(title) + "</span>" + (s ? '<span class="a-top-s mono">' + esc(s.name) + "</span>" : "") + "</div>" +
      (many ? '<button class="iconbtn" type="button" id="picker" aria-label="Switch server">' + icon("swap") + "</button>" : "") +
      (s ? '<button class="iconbtn" type="button" id="refresh" aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") + "</header>";
  }
  function plainTop(title, backTo) {
    return '<header class="a-top">' + (backTo ? '<button class="iconbtn" type="button" id="back" aria-label="Cancel">' + icon("arrow-left") + "</button>" : "") +
      '<div class="a-top-t"><span class="a-top-h">' + esc(title) + "</span></div></header>";
  }
  function nav(cur) {
    var tabs = [["home", "house", "Home"], ["servers", "hard-drives", "Servers"], ["settings", "gear", "Settings"]];
    return '<nav class="a-nav" aria-label="Main">' + tabs.map(function (t) {
      var on = t[0] === cur;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + '><span class="a-nav-i">' + icon(t[1]) + "</span><span>" + t[2] + "</span></a>";
    }).join("") + "</nav>";
  }
  function pull() { return '<div class="a-pull" id="pull" aria-hidden="true">' + icon("arrows-clockwise") + "</div>"; }

  // ---------- states shared by server screens ----------
  function serverFrame(content) {
    var s = C.selected();
    if (!s) return notice("device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.");
    var out = U.ageBanner(C.freshness(s.state));
    var snap = s.state.snapshot;
    if (!snap) return out + notice("hourglass-medium", "No snapshot yet", "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.");
    var lo = C.leftOut(snap);
    return out + (lo ? '<p class="sub a-left">' + icon("scissors") + " " + esc(lo) + "</p>" : "") + content(snap);
  }
  function notice(ic, h, t) {
    return '<section class="panel pad a-notice">' + U.ic("quiet", ic) + '<p class="h2">' + esc(h) + '</p><p class="sub">' + esc(t) + "</p></section>";
  }

  // ---------- home ----------
  function home() {
    if (!C.servers().length) return { body: U.firstRun(), bare: true };
    var body = '<div class="a-page settle">' +
      '<header class="a-head"><p class="eyebrow">' + icon("hand-waving") + " " + C.greeting() + '</p><h1 class="title">Home</h1>' +
      (C.selected().state.snapshot ? '<p class="lede">' + esc(C.home(C.selected().state.snapshot).lede) + "</p>" : "") + "</header>" +
      serverFrame(homeBody) + "</div>";
    return { top: topBar("Dokkit", false), body: body, nav: "home" };
  }
  function homeBody(snap) {
    var h = C.home(snap), out = "";
    if (h.top.kind === "attention") {
      if (h.needs.length) out += '<h2 class="group-h">' + icon("tray") + " Needs you <span class=\"a-n\">" + h.needs.length + "</span></h2>" + '<div class="stack">' + h.needs.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div>";
      if (h.soon.length) out += '<h2 class="group-h">' + icon("calendar") + " Coming up <span class=\"a-n\">" + h.soon.length + "</span></h2>" + '<div class="stack">' + h.soon.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div>";
    } else {
      out += '<div class="allgood a-fine">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.top.headline) + '</p><p class="sub mono">' + esc(h.top.detail) + "</p></div></div>";
    }
    if (h.snoozed) out += '<p class="a-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    if (h.fineLine && h.top.kind === "attention") out += '<div class="allgood">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    if (h.hardware.length) {
      out += '<section class="panel pad a-day" aria-labelledby="day-h"><h2 class="h2" id="day-h">Your machines, the last day</h2><p class="sub">Each block is half an hour. Now is on the right.</p><div class="a-day-rows">' +
        h.hardware.map(function (c) { return '<a href="#machine/' + esc(c.id) + '" class="a-day-row"><span class="mono">' + esc(c.name) + "</span>" + U.strip(c.id, true) + "</a>"; }).join("") +
        "</div>" + U.legend() + "</section>";
      out += '<h2 class="group-h">' + icon("hard-drives") + " Machines</h2>" + '<div class="stack">' + h.hardware.map(machineCard).join("") + "</div>";
    }
    if (h.groups.length) out += '<h2 class="group-h">' + icon("cloud") + " Not on a machine</h2>" + '<div class="stack">' + h.groups.map(machineCard).join("") + "</div>";
    return out;
  }
  function machineCard(c) {
    var open = !!openMachines[c.id], more = !!openMore[c.id];
    var tone = c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var spoken = [c.name, c.status].concat(c.meters.map(function (m) { return m.label + " " + m.percent + " percent" + (m.hot ? ", high" : ""); })).concat([c.counts, c.notice]).filter(Boolean).join(". ");
    var head = '<button class="a-mc-head" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '" aria-label="' + esc(spoken) + '">' +
      '<span class="a-mc-row">' + (c.hardware ? '<span class="pip ' + tone + '" aria-hidden="true"></span>' : U.ic("quiet", "cloud", "sm")) + '<span class="a-mc-name mono">' + esc(c.name) + "</span>" +
      (c.word ? U.tag(tone, c.word) : "") + icon(open ? "caret-up" : "caret-down").replace('class="ph', 'class="a-chev ph') + "</span>" +
      (c.status ? '<span class="sub a-mc-status">' + esc(c.status.replace(/^(Up|Down) · /, "")) + "</span>" : "") +
      (c.meters.length ? '<span class="a-meters">' + c.meters.map(U.meter).join("") + "</span>" : "") +
      '<span class="sub mono a-counts">' + esc(c.counts) + "</span>" +
      (c.notice ? '<span class="a-notice-line t-quiet">' + icon("calendar-blank") + " " + esc(c.notice) + "</span>" : "") + "</button>";
    var kids = "";
    if (open) {
      kids = '<div class="a-kids">';
      if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) kids += '<p class="sub a-line">Nothing is watched on it.</p>';
      c.trouble.concat(c.fine, more ? c.moreFine : []).forEach(function (r) { kids += kid(r); });
      if (c.moreFine.length) kids += '<button class="a-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
      if (c.quietLine) kids += '<p class="sub a-line">' + esc(c.quietLine) + "</p>";
      kids += (c.hardware ? '<a class="btn soft a-open-m" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") + "</div>";
    }
    return '<section class="panel a-mc' + (c.down ? " is-down" : c.inTrouble ? " is-trouble" : "") + '">' + head + kids + "</section>";
  }
  function kid(r) {
    var tone = r.level.tone;
    return '<a class="a-kid" href="#service/' + esc(r.id) + '"><span class="pip ' + (tone === "quiet" ? "quiet" : tone) + '" aria-hidden="true"></span><span class="mono a-kid-n">' + esc(r.name) + '</span><span class="tag t-' + tone + '">' + esc(r.level.word) + "</span></a>";
  }

  // ---------- service ----------
  function servicePage(id) {
    var body = '<div class="a-page settle">' + serverFrame(function (snap) {
      var v = C.service(snap, id);
      if (!v) return notice("question", "Not in this snapshot", "The newest snapshot no longer lists this service.");
      var lv = v.level, out = "";
      out += '<header class="a-hero">' + U.ic(lv.tone, lv.icon, "lg") + '<div><p class="eyebrow">' + U.tag(lv.tone, lv.word) + (v.machine ? ' <span class="mono">' + esc(v.machine) + "</span>" : "") + '</p><h1 class="title mono a-mono-title">' + esc(v.name) + "</h1>" +
        (v.note ? '<p class="lede">' + esc(v.note) + "</p>" : "") +
        (function () { var l = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · "); return l ? '<p class="sub mono">' + esc(l) + "</p>" : ""; })() + "</div></header>";
      if (v.issue) {
        var i = v.issue, st = C.issueState(i), ilv = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(i.state), fl = C.flags(i);
        var meta = [C.names(snap)[i.service], i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean).join(" · ");
        out += '<section class="panel a-issue"><div class="a-issue-top t-' + ilv.tone + '"><div class="a-row-sb">' + U.tag(ilv.tone, ilv.word) + '<span class="mono sub">' + esc(i.short_id) + "</span></div>" +
          '<h2 class="a-issue-h">' + esc(i.title) + "</h2>" + (i.note ? '<p class="a-issue-note">' + esc(i.note) + "</p>" : "") + '<p class="sub mono">' + esc(meta) + "</p>" +
          (fl.length ? '<div class="a-flags">' + fl.map(function (f) { return U.tag(f.tone, f.text); }).join("") + "</div>" : "") + "</div>" +
          (v.history.length ? '<div class="pad"><h3 class="a-h3">What happened</h3><ol class="a-timeline">' + v.history.slice().reverse().map(function (h, k) {
            return '<li><span class="a-dot ' + (k === 0 ? "t-" + ilv.tone : "t-quiet") + '" aria-hidden="true"></span><div><div>' + esc(h.text) + '</div><div class="sub mono">' + esc([h.ago, h.when].filter(Boolean).join(" · ")) + "</div></div></li>";
          }).join("") + "</ol></div>" : "") + "</section>";
      }
      if (v.checks.length) out += '<section class="panel"><div class="panel-head"><span class="h2">Checks</span><span class="sub mono">' + v.checks.length + "</span></div>" + v.checks.map(function (c) {
        return '<div class="a-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div><p class="a-check-n mono">' + esc(c.name) + "</p>" + (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div>" + U.tag(c.level.tone, c.level.word) + "</div>";
      }).join("") + "</section>";
      if (v.job.length) {
        var run = v.jobRaw && v.jobRaw.last_run, prog = run && run.result === "running" && run.total ? Math.floor(run.done / run.total * 100) : null;
        out += '<section class="panel pad"><h2 class="h2">Job</h2><dl class="a-facts">' + v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl>" +
          (prog != null ? '<div class="meter" role="progressbar" aria-label="Progress" aria-valuenow="' + prog + '" aria-valuemin="0" aria-valuemax="100"><b class="run" style="width:' + prog + '%"></b></div>' : "") + "</section>";
      }
      if (v.chart.some(function (x) { return x != null; })) out += '<section class="panel pad"><div class="a-row-sb"><h2 class="h2">Last 24 hours</h2>' + (v.metric ? '<span class="sub mono">' + esc(v.metric) + "</span>" : "") + "</div>" + U.chart(v.chart, v.metric) + '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></section>';
      if (v.logs.length) out += '<section class="panel"><div class="panel-head"><span class="h2">Last log lines</span><span class="sub mono">' + v.logs.length + '</span></div><div class="a-logs">' + U.logLines(v.logs) + "</div></section>";
      return out;
    }) + "</div>";
    return { top: topBar("Service", true), body: body, nav: "home" };
  }

  // ---------- machine ----------
  function machinePage(id) {
    var body = '<div class="a-page settle">' + serverFrame(function (snap) {
      var m = C.machineById(snap, id);
      if (!m) return notice("question", "Not in this snapshot", "The newest snapshot no longer lists this machine.");
      var c = C.card(m), tone = c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
      var mine = snap.issues.filter(function (i) { return i.machine === id && !i.closed_at; });
      var lede = c.down ? "Not reporting since " + C.ago(m.last_seen_at) + "." + (c.planned ? " That is planned, so Dokkit does not worry about it." : "")
        : c.inTrouble ? C.plural(c.trouble.length, "service needs", "services need") + " a look here." : "All good. " + c.counts + ".";
      var out = '<header class="a-hero">' + U.ic(tone, tone === "ok" ? "check-circle" : tone === "down" ? "warning-octagon" : "hourglass-medium", "lg") +
        '<div><p class="eyebrow">' + (c.word ? U.tag(tone, c.word) : "") + (m.os ? ' <span class="mono">' + esc(m.os) + "</span>" : "") + '</p><h1 class="title mono a-mono-title">' + esc(c.name) + '</h1><p class="lede">' + esc(lede) + "</p>" +
        (c.notice ? '<p class="sub">' + esc(c.notice) + "</p>" : "") + "</div></header>";
      if (c.meters.length) out += '<section class="panel pad a-vitals">' + c.meters.map(U.meter).join("") + "</section>";
      if (c.hardware) out += '<section class="panel pad"><h2 class="h2">The last day</h2><p class="sub">Each block is half an hour.</p><div style="margin-top:12px">' + U.strip(c.id) + '</div><div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div></section>';
      if (mine.length) out += '<h2 class="group-h">Needs a look</h2><div class="stack">' + mine.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div>";
      var rows = c.trouble.concat(c.fine, c.moreFine);
      out += '<section class="panel"><div class="a-shead"><span class="h2">Services</span><span class="sub mono">' + esc(c.counts) + "</span></div>" +
        (rows.length ? rows.map(kid).join("") : '<p class="sub a-line">Nothing is watched on it.</p>') + (c.quietLine ? '<p class="sub a-line">' + esc(c.quietLine) + "</p>" : "") + "</section>";
      return out;
    }) + "</div>";
    return { top: topBar("Machine", true), body: body, nav: "home" };
  }

  // ---------- render ----------
  function render() {
    var p = routeParts(), r = p[0], v;
    if (r === "lock") v = { body: U.lockScreen(), bare: true };
    else if (r === "first") v = { body: U.firstRun(), bare: true };
    else if (r === "add") v = { top: plainTop("Add a server", true), body: U.addServer(p[1]), bare: true };
    else if (r === "service") v = servicePage(decodeURIComponent(p[1] || ""));
    else if (r === "machine") v = machinePage(decodeURIComponent(p[1] || ""));
    else if (r === "servers") v = { body: '<div class="a-page settle"><header class="a-head"><h1 class="title">Servers</h1><p class="lede">The Dokkit servers this phone can show. Tap one to show it.</p></header>' + U.serversList() + "</div>", nav: "servers" };
    else if (r === "settings") v = { body: '<div class="a-page settle"><header class="a-head"><h1 class="title">Settings</h1><p class="lede">Everything this phone decides on its own. Each starts at today\'s value.</p></header><div class="stack">' + U.settingsGroups() + U.about() + "</div></div>", nav: "settings" };
    else v = home();
    var scroll = document.getElementById("screen");
    var keep = scroll && render.lastRoute === location.hash ? scroll.scrollTop : 0;
    app.innerHTML = U.phone({ top: (v.top || "") + (v.nav ? pull() : ""), body: v.body, bottom: v.bare && !v.nav ? "" : nav(v.nav) });
    render.lastRoute = location.hash;
    var sc = document.getElementById("screen");
    sc.scrollTop = keep;
    U.wire(render);
    wire(sc);
  }

  function wire(sc) {
    var back = document.getElementById("back");
    if (back) back.onclick = function () { if (history.length > 1) history.back(); else location.hash = "#home"; };
    var ref = document.getElementById("refresh");
    if (ref) ref.onclick = function () { ref.querySelector("i").classList.add("spin"); U.fakeRefresh(function () { ref.querySelector("i").classList.remove("spin"); }); };
    var pk = document.getElementById("picker");
    if (pk) pk.onclick = function () {
      var cur = C.selected();
      U.openLayer('<h2 class="h2" style="margin-bottom:8px">Show which server?</h2>' + C.servers().map(function (s) {
        var f = C.freshness(s.state);
        return '<button class="a-pick" type="button" data-pick="' + s.id + '"><span><span class="a-pick-n mono">' + esc(s.name) + '</span><span class="sub">' + esc(f.text) + "</span></span>" + (s.id === cur.id ? icon("check") : "") + "</button>";
      }).join(""), "sheet");
      setTimeout(function () {
        document.querySelectorAll("[data-pick]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.pick); U.closeLayer(); U.toast("Showing " + C.selected().name + "."); render(); }; });
      }, 0);
    };
    document.querySelectorAll("[data-machine]").forEach(function (b) { b.onclick = function () { openMachines[b.dataset.machine] = !openMachines[b.dataset.machine]; render(); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; render(); }; });
    var cancel = document.querySelector(".a-top #back[aria-label=Cancel]");
    if (cancel) cancel.onclick = function () { location.hash = C.servers().length ? "#servers" : "#first"; };
    pullToRefresh(sc);
  }

  function pullToRefresh(sc) {
    var ind = document.getElementById("pull");
    if (!ind || !C.selected()) return;
    var y0 = null, dy = 0, busy = false;
    function start(y) { if (sc.scrollTop <= 0 && !busy) { y0 = y; dy = 0; } }
    function move(y, e) {
      if (y0 == null) return;
      dy = Math.max(0, Math.min(90, y - y0));
      if (dy > 4 && e && e.cancelable) e.preventDefault();
      ind.style.opacity = Math.min(1, dy / 60); ind.style.transform = "translate(-50%," + (dy * .6) + "px)";
    }
    function end() {
      if (y0 == null) return;
      y0 = null;
      if (dy > 60) {
        busy = true; ind.classList.add("on"); ind.querySelector("i").classList.add("spin");
        U.fakeRefresh(function () { busy = false; ind.classList.remove("on"); ind.querySelector("i").classList.remove("spin"); ind.style.opacity = 0; ind.style.transform = ""; });
      } else { ind.style.opacity = 0; ind.style.transform = ""; }
    }
    sc.addEventListener("touchstart", function (e) { start(e.touches[0].clientY); }, { passive: true });
    sc.addEventListener("touchmove", function (e) { move(e.touches[0].clientY, e); }, { passive: false });
    sc.addEventListener("touchend", end);
    sc.addEventListener("mousedown", function (e) { if (!e.target.closest("a,button,input,select,textarea")) start(e.clientY); });
    window.onmousemove = function (e) { move(e.clientY); };
    window.onmouseup = end;
  }

  if (!location.hash) history.replaceState(null, "", location.pathname + location.search + U.startRoute());
  window.addEventListener("hashchange", function () { render(); var sc = document.getElementById("screen"); if (sc) sc.focus({ preventScroll: true }); });
  render();
})();
