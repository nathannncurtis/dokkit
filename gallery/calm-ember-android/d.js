(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var app = document.getElementById("app");
  var openCards = {}, openMore = {};

  function parts() { return (location.hash.slice(1) || "home").split("/"); }

  // ---------- helpers ----------
  function worst(state) {
    var s = state.snapshot;
    if (!s) return "quiet";
    var needs = s.inbox.needs_you || [];
    if (needs.some(function (i) { return i.state === "down"; })) return "down";
    if (needs.length) return "degraded";
    if ((s.inbox.soon || []).length) return "soon";
    return "ok";
  }
  function mono(t) { return '<span class="mono">' + esc(t) + "</span>"; }

  // ---------- chrome ----------
  function bar(o) {
    var sel = C.selected(), many = C.servers().length > 1;
    var server = !sel ? "" : many
      ? '<button class="chip" type="button" id="pick-server" aria-haspopup="dialog" aria-label="Showing ' + esc(sel.name) + '. Switch server"><span class="pip ' + worst(sel.state) + '"></span>' + mono(sel.name) + icon("caret-down") + "</button>"
      : '<span class="chip still"><span class="pip ' + worst(sel.state) + '"></span>' + mono(sel.name) + "</span>";
    return '<header class="appbar">' +
      (o.back ? '<button class="iconbtn" type="button" id="back" aria-label="Back">' + icon("arrow-left") + "</button>" : "") +
      '<div class="appbar-t"><span class="appbar-title">' + esc(o.title) + "</span>" + (o.server !== false ? server : "") + "</div>" +
      (o.refresh ? '<button class="iconbtn" type="button" id="refresh" aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function nav(cur) {
    var tabs = [["home", "house", "Home"], ["servers", "hard-drives", "Servers"], ["settings", "gear", "Settings"]];
    return '<nav class="tabbar" aria-label="Main">' + tabs.map(function (t) {
      return '<a href="#' + t[0] + '"' + (t[0] === cur ? ' aria-current="page"' : "") + '><span class="tab-ic">' + icon(t[1]) + "</span>" + t[2] + "</a>";
    }).join("") + "</nav>";
  }
  var ptr = '<div class="ptr" id="ptr" aria-hidden="true"><span>' + icon("arrows-clockwise") + "</span></div>";

  // ---------- pieces ----------
  function notice(iconName, title, text) {
    return '<div class="panel pad notice">' + U.ic("quiet", iconName) + '<p class="h2">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div>";
  }
  function stateTag(lv) { return U.tag(lv.tone, lv.word); }
  function fineBox(top) {
    return '<div class="allgood big">' + U.ic("ok", "check-circle") + "<div><p>" + esc(top.headline) + '</p><p class="sub">' + esc(top.detail) + "</p></div></div>";
  }
  function issueList(list, snap) { return '<div class="stack">' + list.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div>"; }

  function heatPanel(cards) {
    var hw = cards.filter(function (c) { return c.lastDay; });
    if (!hw.length) return "";
    return '<section class="panel pad heat"><p class="h2">Your machines, the last day</p><p class="sub">Each block is half an hour. Now is on the right.</p>' +
      '<div class="heat-rows">' + hw.map(function (c) {
        return '<a href="#machine/' + esc(c.id) + '" class="heat-row"><span class="mono">' + esc(c.name) + "</span>" + U.strip(c.id, true) + "</a>";
      }).join("") + "</div>" + U.legend() + "</section>";
  }

  function kid(r) {
    return '<a class="kid" href="#service/' + esc(r.id) + '"><span class="pip ' + r.level.tone + '"></span><span class="mono kid-n">' + esc(r.name) + "</span>" + (r.state === "ok" ? '<span class="sub">OK</span>' : stateTag(r.level)) + "</a>";
  }
  function machineCard(c) {
    var open = !!openCards[c.id], more = !!openMore[c.id];
    var head = '<button class="mc-head" type="button" data-card="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      '<span class="pip ' + c.mark + '"></span><span class="mc-name mono">' + esc(c.name) + "</span>" +
      (c.word ? U.tag(c.down ? "down" : c.inTrouble ? "degraded" : "ok", c.word) : "") + icon("caret-down").replace('class="ph', 'class="chev ph') + "</button>";
    var body = '<div class="mc-body">' +
      (c.status ? '<p class="sub mono small">' + esc(c.status) + "</p>" : "") +
      (c.meters.length ? '<div class="mc-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
      '<p class="sub">' + esc(c.counts) + "</p>" +
      (c.notice ? '<p class="mc-notice">' + icon("calendar") + " " + esc(c.notice) + "</p>" : "") + "</div>";
    var kids = "";
    if (open) {
      var empty = !c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine;
      kids = '<div class="kids">' + (empty ? '<p class="sub kid-line">Nothing is watched on it.</p>' : "") +
        c.trouble.map(kid).join("") + c.fine.map(kid).join("") + (more ? c.moreFine.map(kid).join("") : "") +
        (c.moreFine.length ? '<button class="kid more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>" : "") +
        (c.quietLine ? '<p class="sub kid-line">' + esc(c.quietLine) + "</p>" : "") +
        (c.hardware ? '<a class="kid open-m" href="#machine/' + esc(c.id) + '">Open ' + mono(c.name) + " " + icon("arrow-right") + "</a>" : "") + "</div>";
    }
    return '<section class="panel mc' + (open ? " open" : "") + '">' + head + body + kids + "</section>";
  }

  // ---------- screens ----------
  function snapshotGate(state, fn) {
    if (!C.servers().length) return notice("device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.");
    var out = U.ageBanner(C.freshness(state));
    if (!state.snapshot) return out + notice("hourglass-medium", "No snapshot yet", "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.");
    var lo = C.leftOut(state.snapshot);
    return out + (lo ? '<p class="sub leftout">' + icon("info") + " " + esc(lo) + "</p>" : "") + fn(state.snapshot);
  }

  function home(seg) {
    var sel = C.selected();
    if (!sel) return { top: "", body: U.firstRun(), bottom: "" };
    var state = sel.state, snap = state.snapshot;
    var h = snap ? C.home(snap) : null;
    seg = seg || "needs";
    var head = '<div class="pagehead"><p class="eyebrow">' + icon("hand-waving") + " " + C.greeting() + '</p><h1 class="title">Home</h1>' +
      (h ? '<p class="lede">' + esc(h.lede) + "</p>" : "") + "</div>";
    var body = snapshotGate(state, function (s) {
      var segs = [["needs", "Needs you", h.needs.length], ["soon", "Coming up", h.soon.length], ["machines", "Machines", h.hardware.length]];
      var segHtml = '<div class="segwrap"><div class="seg" role="tablist" aria-label="Show">' + segs.map(function (x) {
        return '<button type="button" role="tab" data-seg="' + x[0] + '" aria-pressed="' + (x[0] === seg) + '" aria-selected="' + (x[0] === seg) + '">' + x[1] + ' <span class="n mono">' + x[2] + "</span></button>";
      }).join("") + "</div></div>";
      var content = "";
      if (seg === "needs") {
        var t = h.top;
        content = t.kind === "attention"
          ? '<p class="group-h">' + U.icon(t.urgent ? "warning-octagon" : "calendar") + " " + esc(t.title) + "</p>" + issueList(t.issues, s)
          : fineBox(t);
        if (h.snoozed) content += '<p class="snoozed">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
        if (t.kind === "attention" && h.fineLine) content += '<div class="allgood">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
      } else if (seg === "soon") {
        content = h.soon.length ? issueList(h.soon, s) : '<div class="panel pad notice">' + U.ic("ok", "calendar-check") + '<p class="h2">Nothing is coming up</p><p class="sub">No expiries or forecasts to plan for.</p></div>';
      } else {
        content = heatPanel(h.hardware) + '<div class="stack">' + h.hardware.map(machineCard).join("") + "</div>" +
          (h.groups.length ? '<p class="group-h">' + icon("cloud") + ' Not on a machine</p><div class="stack">' + h.groups.map(machineCard).join("") + "</div>" : "");
      }
      return segHtml + '<div class="seg-body settle" id="segbody">' + content + "</div>";
    });
    return { top: bar({ title: "Dokkit", refresh: true }), body: ptr + '<div class="page settle">' + head + body + "</div>", bottom: nav("home") };
  }

  function servicePage(id, seg) {
    var sel = C.selected();
    var top = bar({ title: "Service", back: true, refresh: true });
    if (!sel) return { top: top, body: '<div class="page">' + notice("device-mobile", "No server paired", "Choose Servers and add one.") + "</div>", bottom: nav("home") };
    var body = snapshotGate(sel.state, function (s) {
      var v = C.service(s, id);
      if (!v) return notice("info", "Not in this snapshot", "The newest snapshot no longer lists this service.");
      var segs = [["overview", "Overview", true], ["issue", "Issue", !!v.issue], ["chart", "Chart", v.chart.some(function (x) { return x != null; })], ["logs", "Logs", v.logs.length > 0]].filter(function (x) { return x[2]; });
      if (!segs.some(function (x) { return x[0] === seg; })) seg = "overview";
      var lv = v.level;
      var hero = '<div class="hero">' + U.ic(lv.tone, lv.icon, "lg") + '<div><p class="eyebrow">' + stateTag(lv) + (v.machine ? ' on <a class="mono" href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : "") + '</p><h1 class="title mono svc-title">' + esc(v.name) + "</h1>" +
        (v.note ? '<p class="lede">' + esc(v.note) + "</p>" : "") + "</div></div>";
      var segHtml = segs.length > 1 ? '<div class="segwrap"><div class="seg" role="tablist" aria-label="Show">' + segs.map(function (x) {
        return '<button type="button" role="tab" data-sseg="' + x[0] + '" aria-pressed="' + (x[0] === seg) + '" aria-selected="' + (x[0] === seg) + '">' + x[1] + (x[0] === "logs" ? ' <span class="n mono">' + v.logs.length + "</span>" : "") + "</button>";
      }).join("") + "</div></div>" : "";
      var c = "";
      if (seg === "overview") {
        var line = [v.kind, v.version && "version " + v.version, v.environment].filter(Boolean);
        c += line.length ? '<dl class="facts panel pad"><dt>Kind</dt><dd>' + esc(v.kind || "—") + "</dd>" + (v.version ? '<dt>Version</dt><dd class="mono">' + esc(v.version) + "</dd>" : "") + (v.environment ? "<dt>Where</dt><dd>" + esc(v.environment) + "</dd>" : "") + "</dl>" : "";
        if (v.issue) c += '<a class="panel pad jumpcard t-' + C.level(C.issueState(v.issue)).tone + '" href="#service/' + esc(id) + '/issue">' + icon("warning-circle") + "<span><b>Open issue " + mono(v.issue.short_id) + "</b><br>" + esc(v.issue.title) + "</span>" + icon("arrow-right") + "</a>";
        if (v.checks.length) c += '<section class="panel"><div class="panel-head"><span class="h2">Checks</span><span class="sub mono">' + v.checks.length + "</span></div>" + v.checks.map(function (ch) {
          return '<div class="row"><div class="row-top"><span class="mono">' + esc(ch.name) + "</span>" + stateTag(ch.level) + "</div>" + (ch.note ? '<p class="sub">' + esc(ch.note) + "</p>" : "") + (ch.checked ? '<p class="sub small mono">Checked ' + esc(ch.checked) + "</p>" : "") + "</div>";
        }).join("") + "</section>";
        if (v.job.length) {
          var r = v.jobRaw && v.jobRaw.last_run, prog = r && r.result === "running" && r.total ? Math.floor(r.done / r.total * 100) : null;
          c += '<section class="panel"><div class="panel-head"><span class="h2">Job</span></div>' + (prog != null ? '<div class="row"><div class="meter" role="progressbar" aria-valuenow="' + prog + '" aria-valuemin="0" aria-valuemax="100" aria-label="Progress"><b class="run" style="width:' + prog + '%"></b></div><p class="sub small mono">' + prog + "% done</p></div>" : "") +
            '<dl class="facts pad">' + v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl></section>";
        }
      } else if (seg === "issue") {
        var i = v.issue, st = C.issueState(i), il = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(st);
        var meta = [C.names(s)[i.service], i.machine, "open " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
        c += '<section class="panel pad issue-detail t-' + il.tone + '"><div class="row-top">' + stateTag(il) + mono(i.short_id) + "</div><h2 class=\"h2\">" + esc(i.title) + "</h2>" +
          (i.note ? "<p>" + esc(i.note) + "</p>" : "") + '<p class="sub mono small">' + meta.map(esc).join(" · ") + "</p>" +
          (C.flags(i).length ? '<div class="flags">' + C.flags(i).map(function (f) { return U.tag(f.tone, f.text); }).join("") + "</div>" : "") + "</section>";
        if (v.history.length) c += '<section class="panel pad"><p class="h2" style="margin-bottom:14px">What happened</p><ol class="timeline">' + v.history.slice().reverse().map(function (e, k) {
          return '<li><span class="dot ' + (k === 0 ? "t-" + il.tone : "t-quiet") + '"></span><div><div>' + esc(e.text) + '</div><div class="sub small mono">' + esc(e.ago || "") + (e.when ? " · " + esc(e.when) : "") + "</div></div></li>";
        }).join("") + "</ol></section>";
      } else if (seg === "chart") {
        c += '<section class="panel pad"><p class="h2">Last 24 hours</p>' + (v.metric ? '<p class="sub">' + esc(v.metric) + "</p>" : "") + '<div style="margin-top:14px">' + U.chart(v.chart, v.metric) + '</div><div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div></section>';
      } else {
        c += '<section class="panel"><div class="panel-head"><span class="h2">Last log lines</span><span class="sub mono">' + v.logs.length + '</span></div><div class="pad-s">' + U.logLines(v.logs) + "</div></section>";
      }
      return hero + segHtml + '<div class="seg-body stack settle">' + c + "</div>";
    });
    return { top: top, body: ptr + '<div class="page settle">' + body + "</div>", bottom: nav("home") };
  }

  function machinePage(id) {
    var sel = C.selected();
    var top = bar({ title: "Machine", back: true, refresh: true });
    var body = !sel ? notice("device-mobile", "No server paired", "Choose Servers and add one.") : snapshotGate(sel.state, function (s) {
      var m = C.machineById(s, id);
      if (!m) return notice("info", "Not in this snapshot", "The newest snapshot no longer lists this machine.");
      var c = C.card(m);
      var issues = s.issues.filter(function (i) { return i.machine === id && !i.closed_at; });
      var lede = c.down ? "It stopped reporting. " + (c.notice ? "That is planned." : "") : c.inTrouble ? C.plural(c.trouble.length, "thing needs", "things need") + " a look here." : "All good. " + c.counts + ".";
      var out = '<div class="hero">' + U.ic(c.mark === "ok" ? "ok" : c.mark, c.down ? "plugs" : c.inTrouble ? "warning-circle" : "check-circle", "lg") + '<div><p class="eyebrow">' + (c.word ? U.tag(c.down ? "down" : c.inTrouble ? "degraded" : "ok", c.word) : "") + " " + esc(m.os || "") + '</p><h1 class="title mono svc-title">' + esc(c.name) + '</h1><p class="lede">' + esc(lede) + "</p>" + (c.status ? '<p class="sub mono small">' + esc(c.status) + "</p>" : "") + "</div></div>";
      if (c.notice) out += '<div class="banner t-soon">' + icon("calendar") + "<p>" + esc(c.notice) + "</p></div>";
      if (c.meters.length) out += '<section class="panel pad vitals">' + c.meters.map(function (mt) {
        return '<div class="vital"><div class="m-top"><span>' + esc(mt.label) + (mt.subject ? " " + mono(mt.subject) : "") + '</span><b class="big mono' + (mt.hot ? " hot" : "") + '">' + mt.percent + "<small>%</small></b></div>" +
          '<div class="meter" role="meter" aria-label="' + esc(mt.label) + '" aria-valuenow="' + mt.percent + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (mt.hot ? "hot" : "") + '" style="width:' + mt.percent + '%"></b></div></div>';
      }).join("") + "</section>";
      if (c.lastDay) out += '<section class="panel pad"><p class="h2">The last day</p><p class="sub" style="margin-bottom:12px">Each block is half an hour.</p>' + U.strip(c.id) + '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div></section>';
      if (issues.length) out += '<p class="group-h">Needs a look</p>' + issueList(issues, s);
      var all = c.trouble.concat(c.fine, c.moreFine);
      out += '<section class="panel"><div class="panel-head"><span class="h2">Services</span><span class="sub">' + esc(c.counts) + "</span></div>" + (all.length ? '<div class="kids">' + all.map(kid).join("") + (c.quietLine ? '<p class="sub kid-line">' + esc(c.quietLine) + "</p>" : "") + "</div>" : '<p class="sub pad">' + (c.quietLine ? esc(c.quietLine) : "Nothing is watched on it.") + "</p>") + "</section>";
      return '<div class="stack">' + out + "</div>";
    });
    return { top: top, body: ptr + '<div class="page settle">' + body + "</div>", bottom: nav("home") };
  }

  function simplePage(title, html, tab) {
    return { top: "", body: '<div class="page settle"><div class="pagehead"><h1 class="title">' + title + "</h1></div>" + html + "</div>", bottom: nav(tab) };
  }

  // ---------- render ----------
  var lastRoute = null;
  function render(keep) {
    var p = parts(), r = p[0], screen = document.getElementById("screen");
    var scroll = keep && screen ? screen.scrollTop : 0;
    var v;
    if (r === "lock") v = { top: "", body: U.lockScreen(), bottom: "" };
    else if (r === "first") v = { top: "", body: U.firstRun(), bottom: "" };
    else if (r === "add") v = { top: '<header class="appbar"><button class="iconbtn" type="button" id="back" aria-label="Cancel">' + icon("x") + '</button><div class="appbar-t"><span class="appbar-title">Add a server</span></div></header>', body: U.addServer(p[1]), bottom: "" };
    else if (r === "service") v = servicePage(p[1], p[2]);
    else if (r === "machine") v = machinePage(p[1]);
    else if (r === "servers") v = simplePage("Servers", '<p class="lede" style="margin-bottom:16px">The Dokkit servers this phone shows. Tap one to show it.</p><div class="stack">' + U.serversList() + "</div>", "servers");
    else if (r === "settings") v = simplePage("Settings", '<p class="lede" style="margin-bottom:16px">How this phone behaves. Each starts at today\'s value.</p><div class="stack">' + U.settingsGroups() + U.about() + "</div>", "settings");
    else v = home(p[1]);
    app.innerHTML = U.phone(v);
    screen = document.getElementById("screen");
    if (keep) screen.scrollTop = scroll;
    lastRoute = location.hash;
    U.wire(render);
    wire();
  }

  function wire() {
    var back = document.getElementById("back");
    if (back) back.onclick = function () { if (history.length > 1) history.back(); else location.hash = "#home"; };
    var rf = document.getElementById("refresh");
    if (rf) rf.onclick = function () { rf.querySelector("i").classList.add("spin"); U.fakeRefresh(function () { rf.querySelector("i").classList.remove("spin"); }); };
    var pick = document.getElementById("pick-server");
    if (pick) pick.onclick = serverSheet;
    document.querySelectorAll("[data-seg]").forEach(function (b) { b.onclick = function () { history.replaceState(null, "", "#home/" + b.dataset.seg); render(true); }; });
    document.querySelectorAll("[data-sseg]").forEach(function (b) { b.onclick = function () { history.replaceState(null, "", "#service/" + parts()[1] + "/" + b.dataset.sseg); render(true); }; });
    document.querySelectorAll("[data-card]").forEach(function (b) { b.onclick = function () { openCards[b.dataset.card] = !openCards[b.dataset.card]; render(true); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; render(true); }; });
    pullToRefresh();
  }

  function serverSheet() {
    var cur = C.selected();
    U.openLayer('<h2 class="h2" style="font-size:19px;margin-bottom:4px">Show a server</h2><p class="sub" style="margin-bottom:10px">Each one is paired on its own.</p>' +
      C.servers().map(function (s) {
        var f = C.freshness(s.state);
        return '<button class="sheet-row" type="button" data-pick="' + s.id + '"><span class="pip ' + worst(s.state) + '"></span><span class="sr-t"><span class="mono">' + esc(s.name) + '</span><span class="sub' + (f.warn ? " warn" : "") + '">' + esc(f.text) + "</span></span>" + (s.id === cur.id ? '<span class="sr-check" aria-label="Showing">' + icon("check") + "</span>" : "") + "</button>";
      }).join("") + '<a class="btn block" href="#servers" data-close style="margin-top:10px">' + icon("sliders-horizontal") + " Manage servers</a>", "sheet");
    setTimeout(function () {
      document.querySelectorAll("[data-pick]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.pick); U.closeLayer(); render(); U.toast("Showing " + C.selected().name + "."); }; });
    }, 0);
  }

  function pullToRefresh() {
    var screen = document.getElementById("screen"), ind = document.getElementById("ptr");
    if (!screen || !ind) return;
    var y0 = null, dy = 0;
    screen.addEventListener("pointerdown", function (e) { if (screen.scrollTop <= 0 && e.isPrimary) { y0 = e.clientY; dy = 0; } });
    screen.addEventListener("pointermove", function (e) {
      if (y0 == null) return;
      dy = Math.max(0, Math.min(90, e.clientY - y0));
      if (dy > 8) ind.classList.add("pull");
      ind.style.setProperty("--pull", dy + "px");
    });
    function end() {
      if (y0 == null) return;
      y0 = null;
      if (dy > 64) {
        ind.classList.add("busy");
        U.fakeRefresh(function () { ind.classList.remove("busy", "pull"); ind.style.removeProperty("--pull"); });
      } else { ind.classList.remove("pull"); ind.style.removeProperty("--pull"); }
    }
    screen.addEventListener("pointerup", end);
    screen.addEventListener("pointercancel", end);
  }

  window.addEventListener("hashchange", function () { if (location.hash !== lastRoute) render(); });
  if (!location.hash) history.replaceState(null, "", U.startRoute());
  render();
})();
