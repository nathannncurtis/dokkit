// Direction C, Hero: the state fills the top of the screen; issues swipe one at a time.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var openMachines = {}, openMore = {}, issueTab = null;

  function route() {
    var h = location.hash || U.startRoute();
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/") };
  }

  // ---------- chrome ----------
  function nav(current) {
    var tabs = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="c-nav" aria-label="Main">' + tabs.map(function (t) {
      var on = t[0] === current;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + '><span class="pill">' + icon(t[2]) + "</span><span>" + t[1] + "</span></a>";
    }).join("") + "</nav>";
  }
  function topbar(title, opts) {
    opts = opts || {};
    var s = C.selected(), many = C.servers().length > 1;
    return '<header class="c-top">' +
      (opts.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (opts.backLabel || "Back") + '">' + icon(opts.backIcon || "arrow-left") + "</button>" : '<span class="c-top-gap"></span>') +
      '<div class="c-top-t"><h1>' + esc(title) + "</h1>" + (opts.server !== false && s ? '<p class="sub">' + esc(s.name) + "</p>" : "") + "</div>" +
      (opts.tools ? (many ? '<button class="iconbtn" type="button" data-picker aria-label="Switch server">' + icon("swap") + "</button>" : "") +
        '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function ptr() { return '<div class="c-ptr" id="ptr" aria-hidden="true"><span class="c-ptr-dot">' + icon("arrows-clockwise") + "</span></div>"; }

  // ---------- small parts ----------
  function pipTone(mark) { return mark === "down" ? "down" : mark === "degraded" ? "degraded" : ""; }
  function svcRow(r) {
    return '<a class="c-svc" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="mono name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id];
    var out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub c-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="c-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub c-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function machineRow(c) {
    var open = !!openMachines[c.id];
    return '<section class="c-mrow' + (open ? " open" : "") + '">' +
      '<button class="c-mhead" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      (c.hardware ? '<span class="pip ' + pipTone(c.mark) + '" aria-hidden="true"></span>' : '<span class="c-gicon" aria-hidden="true">' + icon("cloud") + "</span>") +
      '<span class="c-mtext"><span class="mono c-mname">' + esc(c.name) + "</span>" +
      (c.status ? '<span class="sub' + (c.down ? " c-down" : "") + '">' + esc(c.status) + "</span>" : "") +
      '<span class="sub">' + esc(c.counts) + "</span></span>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</button>" +
      (open ? '<div class="c-mbody settle">' +
        (c.meters.length ? '<div class="c-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
        (c.notice ? '<p class="c-notice t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
        '<div class="c-svcs">' + services(c) + "</div>" +
        (c.hardware ? '<a class="btn soft block" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
        "</div>" : "") +
      "</section>";
  }
  function freshLine(f) {
    if (f.warn || f.detail) return "";
    return '<p class="c-age mono">' + icon("clock") + " " + esc(f.text) + "</p>";
  }
  function notice(tone, ic, title, text) {
    return '<div class="panel pad c-notice-box">' + U.ic(tone, ic) + '<div><p class="h2">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div></div>";
  }

  // ---------- home ----------
  function home() {
    var s = C.selected();
    if (!s) return { full: U.firstRun() };
    var st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) {
      return {
        tone: "quiet",
        body: '<div class="c-hero t-quiet settle"><span class="ic lg c-hic">' + icon("hourglass-medium") + '</span><p class="eyebrow">' + esc(C.greeting()) + '</p><h2 class="c-big">No snapshot yet</h2>' +
          '<p class="lede">This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.</p></div>' +
          '<div class="c-body settle">' + (f.detail ? U.ageBanner(f) : "") + "</div>"
      };
    }
    var h = C.home(snap), top = h.top;
    var tone = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var icn = { down: "warning-octagon", degraded: "hourglass-medium", soon: "calendar", ok: "check-circle" }[tone];
    var big = top.kind === "fine" ? top.headline
      : h.needs.length ? C.plural(h.needs.length, "thing needs you", "things need you")
      : C.plural(h.soon.length, "thing is coming up", "things are coming up");
    // The big line already says how many need you, so the lede carries on from there.
    var lede = top.kind === "fine" ? top.detail
      : h.needs.length ? h.lede.replace(/^[^.]*\.\s*/, "")
      : "Nothing needs you. Plan for " + (h.soon.length === 1 ? "it" : "them") + " when it suits you.";

    var hero = '<div class="c-hero t-' + tone + ' settle"><span class="ic lg c-hic">' + icon(icn) + '</span>' +
      '<p class="eyebrow">' + icon("hand-waving") + " " + esc(C.greeting()) + '</p><h2 class="c-big">' + esc(big) + '</h2><p class="lede">' + esc(lede) + "</p>" + freshLine(f) + "</div>";

    var body = '<div class="c-body settle">';
    if (f.warn || f.detail) body += U.ageBanner(f);
    var lo = C.leftOut(snap); if (lo) body += '<p class="sub c-left">' + icon("info") + " " + esc(lo) + "</p>";

    if (top.kind === "attention") {
      var both = h.needs.length && h.soon.length;
      if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";
      var list = issueTab === "needs" ? h.needs : h.soon;
      body += '<section class="c-issues" aria-label="Issues">' +
        (both ? '<div class="seg" role="group" aria-label="Show"><button type="button" data-itab="needs" aria-pressed="' + (issueTab === "needs") + '">Needs you <span class="mono">' + h.needs.length + '</span></button><button type="button" data-itab="soon" aria-pressed="' + (issueTab === "soon") + '">Coming up <span class="mono">' + h.soon.length + "</span></button></div>"
          : '<h2 class="group-h">' + (issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>") +
        '<div class="c-snap" id="snap" tabindex="0" aria-label="' + esc(issueTab === "needs" ? "Needs you" : "Coming up") + ', swipe for the next one">' +
        list.map(function (i) { return '<div class="c-slide">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>" +
        (list.length > 1 ? '<div class="c-dots"><span class="dots" aria-hidden="true">' + list.map(function (_, n) { return "<i" + (n === 0 ? ' class="on"' : "") + "></i>"; }).join("") + '</span><span class="sub mono" id="pos" aria-live="polite">1 of ' + list.length + "</span></div>" : "") +
        "</section>";
      if (h.snoozed) body += '<p class="c-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
      if (h.fineLine) body += '<div class="allgood">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    } else if (h.snoozed) {
      body += '<p class="c-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    }

    var hw = h.hardware.filter(function (c) { return c.lastDay; });
    if (hw.length) {
      body += '<section class="panel pad c-day"><h2 class="h2">The last day</h2><p class="sub">Each block is half an hour. Now is on the right.</p><div class="c-day-rows">' +
        hw.map(function (c) { return '<a class="mono" href="#machine/' + esc(c.id) + '">' + esc(c.name) + "</a>" + U.strip(c.id, true); }).join("") + "</div>" + U.legend() + "</section>";
    }
    if (h.hardware.length) body += '<h2 class="group-h">Machines</h2><div class="panel c-mlist">' + h.hardware.map(machineRow).join("") + "</div>";
    if (h.groups.length) body += '<h2 class="group-h">Not on a machine</h2><div class="panel c-mlist">' + h.groups.map(machineRow).join("") + "</div>";
    body += "</div>";
    return { tone: tone, body: hero + body };
  }

  // ---------- service ----------
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot;
    var f = s ? C.freshness(s.state) : null;
    if (!snap) return { body: '<div class="c-body settle">' + (f ? U.ageBanner(f) : "") + notice("quiet", "hourglass-medium", "No snapshot yet", "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.") + "</div>" };
    var v = C.service(snap, id);
    if (!v) return { body: '<div class="c-body settle">' + notice("quiet", "info", "Not in this snapshot", "The newest snapshot no longer lists this service.") + "</div>" };
    var tone = v.level.tone;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var hero = '<div class="c-hero sm t-' + tone + ' settle"><span class="ic c-hic">' + icon(v.level.icon) + '</span><p class="eyebrow">' + U.tag(tone, v.level.word) + (v.machine ? ' <a class="mono c-mlink" href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : "") + "</p>" +
      '<h2 class="c-big mono">' + esc(v.name) + "</h2>" + (v.note ? '<p class="lede">' + esc(v.note) + "</p>" : "") + (line ? '<p class="sub mono c-kind">' + esc(line) + "</p>" : "") + freshLine(f) + "</div>";
    var b = '<div class="c-body settle">' + (f.warn || f.detail ? U.ageBanner(f) : "");
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub c-left">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var nm = C.names(snap)[i.service];
      var meta = [nm, i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += '<section class="panel c-sec"><div class="panel-head"><span class="h2">Open issue</span><span class="sub mono">' + esc(i.short_id) + "</span></div>" +
        '<div class="c-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + '</p><h3>' + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="meta mono">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="c-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="c-time">' + v.history.slice().reverse().map(function (e, n) {
          return '<li><span class="dot ' + (n === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub mono">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : "") + "</section>";
    }
    if (v.checks.length) {
      b += '<section class="panel c-sec"><div class="panel-head"><span class="h2">Checks</span><span class="sub mono">' + v.checks.length + "</span></div>" +
        v.checks.map(function (c) {
          return '<div class="c-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div><p class="mono c-cname">' + esc(c.name) + '</p><p class="c-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</p>" +
            (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>";
        }).join("") + "</section>";
    }
    if (v.job.length) {
      var run = v.jobRaw && v.jobRaw.last_run;
      b += '<section class="panel c-sec"><div class="panel-head"><span class="h2">Job</span></div><dl class="c-dl">' +
        v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl>" +
        (run && run.result === "running" && run.total ? '<div class="c-prog"><div class="meter" role="progressbar" aria-valuenow="' + run.done + '" aria-valuemax="' + run.total + '"><b class="run" style="width:' + Math.round(run.done / run.total * 100) + '%"></b></div></div>' : "") + "</section>";
    }
    if (v.chart.some(function (x) { return x != null; })) {
      b += '<section class="panel pad c-sec"><div class="c-sec-h"><span class="h2">Last 24 hours</span>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" + U.chart(v.chart, v.metric) +
        '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></section>';
    }
    if (v.logs.length) b += '<section class="panel c-sec"><div class="panel-head"><span class="h2">Last log lines</span><span class="sub mono">' + v.logs.length + '</span></div><div class="c-logs">' + U.logLines(v.logs) + "</div></section>";
    b += "</div>";
    return { body: hero + b };
  }

  // ---------- machine ----------
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot;
    var f = s ? C.freshness(s.state) : null;
    if (!snap) return { body: '<div class="c-body settle">' + (f ? U.ageBanner(f) : "") + notice("quiet", "hourglass-medium", "No snapshot yet", "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.") + "</div>" };
    var m = C.machineById(snap, id);
    if (!m) return { body: '<div class="c-body settle">' + notice("quiet", "info", "Not in this snapshot", "The newest snapshot no longer lists this machine.") + "</div>" };
    var c = C.card(m), tone = c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it."
      : c.down ? "It has stopped reporting." : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look here." : "All good. " + c.counts + ".";
    var hero = '<div class="c-hero sm t-' + (c.planned ? "quiet" : tone) + ' settle"><span class="ic c-hic">' + icon(c.planned ? "moon" : tone === "ok" ? "check-circle" : tone === "down" ? "warning-octagon" : "hourglass-medium") + "</span>" +
      '<p class="eyebrow">' + (c.word ? U.tag(c.planned ? "quiet" : tone, c.word) : "") + (m.os ? " " + esc(m.os) : "") + '</p><h2 class="c-big mono">' + esc(c.name) + '</h2><p class="lede">' + esc(lede) + "</p>" +
      (c.status ? '<p class="sub mono c-kind">' + esc(c.status) + "</p>" : "") + freshLine(f) + "</div>";
    var b = '<div class="c-body settle">' + (f.warn || f.detail ? U.ageBanner(f) : "");
    if (c.meters.length) b += '<section class="panel pad c-vitals">' + c.meters.map(U.meter).join("") + "</section>";
    else if (c.hardware) b += '<p class="sub c-line">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += '<section class="panel pad c-sec"><span class="h2">The last day</span><p class="sub" style="margin-bottom:12px">Each block is half an hour.</p>' + U.strip(c.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div style="margin-top:10px">' + U.legend() + "</div></section>";
    if (mine.length) b += '<h2 class="group-h">Needs a look</h2><div class="stack">' + mine.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div>";
    b += '<h2 class="group-h">Services</h2><div class="panel c-svcs pad-s">' + services(c) + "</div></div>";
    return { body: hero + b };
  }

  // ---------- render ----------
  function render() {
    var r = route(), app = document.getElementById("app"), out;
    if (r.name === "lock") out = U.phone({ body: U.lockScreen() });
    else if (r.name === "first") out = U.phone({ body: U.firstRun() });
    else if (r.name === "add") out = U.phone({ top: topbar("Add a server", { back: true, backIcon: "x", backLabel: "Cancel", server: false }), body: U.addServer(r.id) });
    else if (r.name === "servers") out = U.phone({ top: topbar("Servers", { server: false }), body: '<div class="pad-screen settle">' + U.serversList() + "</div>", bottom: nav("servers") });
    else if (r.name === "settings") out = U.phone({ top: topbar("Settings", { server: false }), body: '<div class="pad-screen settle">' + U.settingsGroups() + U.about() + "</div>", bottom: nav("settings") });
    else {
      var page = r.name === "service" ? service(r.id) : r.name === "machine" ? machine(r.id) : home();
      if (page.full) out = U.phone({ body: page.full });
      else {
        var title = r.name === "service" ? "Service" : r.name === "machine" ? "Machine" : "Home";
        var noServer = !C.servers().length;
        out = U.phone({
          top: topbar(title, { back: r.name !== "home", tools: !noServer }),
          body: ptr() + (noServer ? '<div class="c-body settle">' + notice("quiet", "device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.") + "</div>" : page.body),
          bottom: nav(r.name === "home" ? "home" : "")
        });
      }
      app.innerHTML = out;
      var ph = app.querySelector(".phone");
      if (page && page.tone) ph.dataset.tone = page.tone;
      else if (page && !page.full) {
        var hero = app.querySelector(".c-hero");
        if (hero) ph.dataset.tone = (hero.className.match(/t-(\w+)/) || [])[1];
      }
      after();
      return;
    }
    app.innerHTML = out;
    after();
  }

  function after() {
    U.wire(render);
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = function () { if (history.length > 1) history.back(); else location.hash = "#home"; }; });
    document.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { spin(true); U.fakeRefresh(function () { spin(false); }); }; });
    document.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = picker; });
    document.querySelectorAll("[data-machine]").forEach(function (b) { b.onclick = function () { openMachines[b.dataset.machine] = !openMachines[b.dataset.machine]; keepScroll(render); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; keepScroll(render); }; });
    document.querySelectorAll("[data-itab]").forEach(function (b) { b.onclick = function () { issueTab = b.dataset.itab; keepScroll(render); }; });
    var snap = document.getElementById("snap");
    if (snap) {
      var dots = document.querySelectorAll(".c-dots .dots i"), pos = document.getElementById("pos"), n = snap.children.length;
      snap.addEventListener("scroll", function () {
        var w = snap.children[0].getBoundingClientRect().width + 10;
        var k = Math.max(0, Math.min(n - 1, Math.round(snap.scrollLeft / w)));
        dots.forEach(function (d, j) { d.classList.toggle("on", j === k); });
        if (pos) pos.textContent = (k + 1) + " of " + n;
      }, { passive: true });
    }
    pullToRefresh();
  }
  function keepScroll(fn) { var s = document.getElementById("screen"), y = s ? s.scrollTop : 0; fn(); var t = document.getElementById("screen"); if (t) t.scrollTop = y; }

  function picker() {
    var cur = C.selected();
    U.openLayer('<h2 class="h2" style="margin:0 4px 10px">Show a server</h2>' + C.servers().map(function (s) {
      var on = cur && s.id === cur.id;
      return '<button class="c-pick" type="button" data-pick="' + esc(s.id) + '"' + (on ? ' aria-current="true"' : "") + '><span><span class="srv-name">' + esc(s.name) + '</span><span class="sub mono">' + esc(C.host(s.relay)) + "</span></span>" + (on ? icon("check") : "") + "</button>";
    }).join(""), "sheet");
    setTimeout(function () {
      document.querySelectorAll("[data-pick]").forEach(function (b) {
        b.onclick = function () { C.select(b.dataset.pick); U.closeLayer(); setTimeout(render, C.reduced ? 0 : 230); };
      });
    }, 0);
  }

  function spin(on) { var p = document.getElementById("ptr"); if (p) p.classList.toggle("show", on); }
  function pullToRefresh() {
    var sc = document.getElementById("screen"), p = document.getElementById("ptr");
    if (!sc || !p) return;
    var y0 = null, dy = 0;
    function start(y) { if (sc.scrollTop <= 0) { y0 = y; dy = 0; } }
    function move(y) { if (y0 == null) return; dy = Math.max(0, y - y0); p.style.setProperty("--pull", Math.min(dy, 90) + "px"); p.classList.toggle("ready", dy > 70); }
    function end() {
      if (y0 == null) return;
      p.style.removeProperty("--pull"); p.classList.remove("ready");
      if (dy > 70) { spin(true); U.fakeRefresh(function () { spin(false); }); }
      y0 = null; dy = 0;
    }
    sc.addEventListener("touchstart", function (e) { start(e.touches[0].clientY); }, { passive: true });
    sc.addEventListener("touchmove", function (e) { move(e.touches[0].clientY); }, { passive: true });
    sc.addEventListener("touchend", end);
    sc.addEventListener("mousedown", function (e) { if (!e.target.closest("a,button,input,select,textarea,.c-snap")) start(e.clientY); });
    window.onmousemove = function (e) { move(e.clientY); };
    window.onmouseup = end;
  }

  window.addEventListener("hashchange", function () { render(); var s = document.getElementById("screen"); if (s) { s.scrollTop = 0; s.focus({ preventScroll: true }); } });
  render();
})();
