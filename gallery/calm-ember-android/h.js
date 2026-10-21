// Direction H, Depth: soft light in layers behind glass cards; sheets grow out of what you tap.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var openMachines = {}, openMore = {}, issueTab = null, counted = null;
  var reduced = C.reduced;
  var timelines = window.CSS && CSS.supports("animation-timeline: --a") && CSS.supports("timeline-scope: --a");

  function route() {
    var h = location.hash || U.startRoute();
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/") };
  }

  // ---------- chrome ----------
  function orbs(tone) {
    return '<div class="h-orbs t-' + tone + '" aria-hidden="true"><span class="o o1"><i></i></span><span class="o o2"><i></i></span><span class="o o3"><i></i></span></div>';
  }
  function nav(current) {
    var tabs = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="h-nav" aria-label="Main">' + tabs.map(function (t) {
      var on = t[0] === current;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + '><span class="pill">' + icon(t[2]) + "</span><span>" + t[1] + "</span></a>";
    }).join("") + "</nav>";
  }
  function topbar(title, opts) {
    opts = opts || {};
    var s = C.selected(), many = C.servers().length > 1;
    var server = opts.server !== false && s
      ? (many && opts.tools ? '<button class="h-chip" type="button" data-picker aria-label="Showing ' + esc(s.name) + ', switch server"><span class="mono">' + esc(s.name) + "</span>" + icon("caret-down") + "</button>"
        : '<span class="h-chip quiet mono">' + esc(s.name) + "</span>")
      : "";
    return '<header class="h-top">' +
      (opts.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (opts.backLabel || "Back") + '">' + icon(opts.backIcon || "arrow-left") + "</button>" : '<span class="h-top-gap"></span>') +
      '<h1 class="h-top-t">' + esc(title) + "</h1>" + server +
      (opts.tools ? '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function ptr() { return '<div class="c-ptr h-ptr" id="ptr" aria-hidden="true"><span class="c-ptr-dot">' + icon("arrows-clockwise") + "</span></div>"; }
  function glass(cls, inner, tag) { tag = tag || "section"; return "<" + tag + ' class="h-glass ' + (cls || "") + '">' + inner + "</" + tag + ">"; }

  // ---------- small parts ----------
  function pipTone(mark) { return mark === "down" ? "down" : mark === "degraded" ? "degraded" : ""; }
  function svcRow(r) {
    return '<a class="h-svc" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="mono name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id], out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub h-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="h-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub h-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function machineRow(c) {
    var open = !!openMachines[c.id];
    return '<section class="h-mrow' + (open ? " open" : "") + '" data-row="' + esc(c.id) + '">' +
      '<button class="h-mhead" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      (c.hardware ? '<span class="pip ' + pipTone(c.mark) + '" aria-hidden="true"></span>' : '<span class="h-gicon" aria-hidden="true">' + icon("cloud") + "</span>") +
      '<span class="h-mtext"><span class="h-mname mono">' + esc(c.name) + "</span>" +
      (c.status ? '<span class="sub' + (c.down ? " h-down" : "") + '">' + esc(c.status) + "</span>" : "") +
      '<span class="sub">' + esc(c.counts) + "</span></span>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</button>" +
      '<div class="h-fold"' + (open ? "" : " inert") + '><div><div class="h-mbody">' +
      (c.meters.length ? '<div class="h-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
      (c.notice ? '<p class="h-notice t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
      '<div class="h-svcs">' + services(c) + "</div>" +
      (c.hardware ? '<a class="btn soft block" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
      "</div></div></div></section>";
  }
  function ageLine(f) {
    if (f.warn || f.detail) return "";
    return '<p class="h-age">' + icon("clock") + " " + esc(f.text) + "</p>";
  }
  function notice(tone, ic, title, text) {
    return glass("pad h-notice-box h-rise", U.ic(tone, ic) + '<div><p class="h2">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div>");
  }
  function pageHead(title, lede) {
    return '<header class="h-hero h-page-head"><h2 class="h-title">' + esc(title) + "</h2>" + (lede ? '<p class="lede">' + esc(lede) + "</p>" : "") + "</header>";
  }
  var NOSNAP = "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.";

  // ---------- home ----------
  function home() {
    var s = C.selected();
    if (!s) return { full: U.firstRun(), tone: "brand" };
    var st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) {
      return {
        tone: "quiet",
        body: '<header class="h-hero"><span class="ic lg h-hic t-quiet">' + icon("hourglass-medium") + '</span><p class="eyebrow">' + esc(C.greeting()) + '</p><h2 class="h-title">No snapshot yet</h2>' +
          '<p class="lede">' + esc(NOSNAP) + "</p></header>" + '<div class="h-body">' + (f.detail ? U.ageBanner(f) : "") + "</div>"
      };
    }
    var h = C.home(snap), top = h.top;
    var tone = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var hw = snap.machines.filter(function (m) { return m.kind === "enrolled"; });
    var running = 0; snap.machines.forEach(function (m) { m.services.forEach(function (x) { if ((x.environment == null || x.environment === "production") && x.state === "ok") running++; }); });

    var num, unit, lede, eyebrow;
    if (top.kind === "fine") {
      num = running; unit = running === 1 ? "thing running,<br>all fine" : "things running,<br>all fine";
      eyebrow = icon("check-circle") + " Everything is fine"; lede = top.detail;
    } else if (h.needs.length) {
      num = h.needs.length; unit = h.needs.length === 1 ? "thing<br>needs you" : "things<br>need you";
      eyebrow = icon("hand-waving") + " " + esc(C.greeting()); lede = h.lede.replace(/^[^.]*\.\s*/, "");
    } else {
      num = h.soon.length; unit = h.soon.length === 1 ? "thing is<br>coming up" : "things are<br>coming up";
      eyebrow = icon("hand-waving") + " " + esc(C.greeting()); lede = "Nothing needs you. Plan for " + (h.soon.length === 1 ? "it" : "them") + " when it suits you.";
    }
    var stats = top.kind === "fine"
      ? [["Machines up", hw.filter(function (m) { return !m.down; }).length + '<small>/' + hw.length + "</small>", null], ["Needs you", "0", null]].concat(h.snoozed ? [["Snoozed", String(h.snoozedList.length), null]] : [])
      : [["Needs you", String(h.needs.length), h.needs.length ? "needs" : null], ["Coming up", String(h.soon.length), h.soon.length ? "soon" : null]].concat(h.snoozedList.length ? [["Snoozed", String(h.snoozedList.length), null]] : []);
    if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";

    var hero = '<header class="h-hero">' +
      '<p class="eyebrow">' + eyebrow + "</p>" +
      '<div class="h-fig"><span class="h-num" data-count="' + num + '">' + num + '</span><span class="h-unit">' + unit + "</span></div>" +
      '<p class="lede">' + esc(lede) + "</p>" +
      '<div class="h-stats">' + stats.map(function (x) {
        var tab = x[2], on = tab && tab === issueTab && top.kind !== "fine";
        return (tab ? '<button type="button" data-itab="' + tab + '" aria-pressed="' + !!on + '"' : "<div") + ' class="h-stat' + (on ? " on" : "") + '"><span class="v">' + x[1] + '</span><span class="k">' + x[0] + "</span>" + (tab ? "</button>" : "</div>");
      }).join("") + "</div>" + ageLine(f) + "</header>";

    var body = '<div class="h-body">';
    if (f.warn || f.detail) body += U.ageBanner(f);
    var lo = C.leftOut(snap); if (lo) body += '<p class="sub h-left">' + icon("info") + " " + esc(lo) + "</p>";

    if (top.kind === "attention") {
      var list = issueTab === "needs" ? h.needs : h.soon;
      body += '<section class="h-issues h-rise" aria-label="Issues"><div class="h-sec-h"><h2 class="h2">' + (issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>" +
        (list.length > 1 ? '<span class="sub mono" id="pos" aria-live="polite">1 of ' + list.length + "</span>" : "") + "</div>" +
        '<div class="c-snap h-snap" id="snap" tabindex="0" aria-label="' + esc(issueTab === "needs" ? "Needs you" : "Coming up") + ', swipe for the next one">' +
        list.map(function (i) { return '<div class="c-slide">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>" +
        (list.length > 1 ? '<div class="h-dots" aria-hidden="true">' + list.map(function (_, n) { return "<i" + (n === 0 ? ' class="on"' : "") + "></i>"; }).join("") + "</div>" : "") +
        "</section>";
      if (h.snoozed) body += '<p class="h-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
      if (h.fineLine) body += '<div class="allgood h-allgood h-rise">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    } else if (h.snoozed) {
      body += '<p class="h-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    }

    var day = h.hardware.filter(function (c) { return c.lastDay; });
    if (day.length) {
      body += glass("pad h-day h-rise", '<div class="h-sec-h"><h2 class="h2">The last day</h2><span class="sub">Each block is half an hour</span></div><div class="h-day-rows">' +
        day.map(function (c) { return '<a class="mono" href="#machine/' + esc(c.id) + '">' + esc(c.name) + "</a>" + U.strip(c.id, true); }).join("") + "</div>" +
        '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div><div class="h-legend">' + U.legend() + "</div>");
    }
    if (h.hardware.length) body += '<h2 class="group-h">Machines</h2>' + glass("h-mlist h-rise", h.hardware.map(machineRow).join(""));
    if (h.groups.length) body += '<h2 class="group-h">Not on a machine</h2>' + glass("h-mlist h-rise", h.groups.map(machineRow).join(""));
    body += "</div>";
    return { tone: tone, body: hero + body, count: num };
  }

  // ---------- service ----------
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot;
    var f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", body: '<div class="h-body h-pt">' + (f ? U.ageBanner(f) : "") + notice("quiet", "hourglass-medium", "No snapshot yet", NOSNAP) + "</div>" };
    var v = C.service(snap, id);
    if (!v) return { tone: "quiet", body: '<div class="h-body h-pt">' + notice("quiet", "info", "Not in this snapshot", "The newest snapshot no longer lists this service.") + "</div>" };
    var tone = v.level.tone;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var hero = '<header class="h-hero h-hero-card"><div class="h-glass h-herocard t-' + tone + '"><span class="ic h-hic t-' + tone + '">' + icon(v.level.icon) + "</span>" +
      '<p class="eyebrow">' + U.tag(tone, v.level.word) + (v.machine ? ' <span>on <a class="mono h-mlink" href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a></span>" : "") + "</p>" +
      '<h2 class="h-name mono">' + esc(v.name) + "</h2>" + (v.note ? '<p class="lede">' + esc(v.note) + "</p>" : "") + (line ? '<p class="sub mono h-kind">' + esc(line) + "</p>" : "") + ageLine(f) + "</div></header>";
    var b = '<div class="h-body">' + (f.warn || f.detail ? U.ageBanner(f) : "");
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub h-left">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var nm = C.names(snap)[i.service];
      var meta = [nm, i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += glass("h-sec h-rise", '<div class="h-sec-h pad-h"><h2 class="h2">Open issue</h2><span class="sub mono">' + esc(i.short_id) + "</span></div>" +
        '<div class="h-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + "</p><h3>" + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="meta mono">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="h-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="h-time">' + v.history.slice().reverse().map(function (e, n) {
          return '<li><span class="dot ' + (n === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub mono">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : ""));
    }
    if (v.checks.length) {
      b += glass("h-sec h-rise", '<div class="h-sec-h pad-h"><h2 class="h2">Checks</h2><span class="sub mono">' + v.checks.length + "</span></div>" +
        v.checks.map(function (c) {
          return '<div class="h-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div><p class="mono h-cname">' + esc(c.name) + '</p><p class="h-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</p>" +
            (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>";
        }).join(""));
    }
    if (v.job.length) {
      var run = v.jobRaw && v.jobRaw.last_run;
      b += glass("h-sec h-rise", '<div class="h-sec-h pad-h"><h2 class="h2">Job</h2></div><dl class="h-dl">' +
        v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl>" +
        (run && run.result === "running" && run.total ? '<div class="h-prog"><div class="meter" role="progressbar" aria-valuenow="' + run.done + '" aria-valuemax="' + run.total + '"><b class="run" style="width:' + Math.round(run.done / run.total * 100) + '%"></b></div></div>' : ""));
    }
    if (v.chart.some(function (x) { return x != null; })) {
      b += glass("pad h-sec h-rise", '<div class="h-sec-h"><h2 class="h2">Last 24 hours</h2>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" + U.chart(v.chart, v.metric) +
        '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div>');
    }
    if (v.logs.length) b += glass("h-sec h-rise", '<div class="h-sec-h pad-h"><h2 class="h2">Last log lines</h2><span class="sub mono">' + v.logs.length + '</span></div><div class="h-logs">' + U.logLines(v.logs) + "</div>");
    b += "</div>";
    return { tone: tone, body: hero + b, title: v.name };
  }

  // ---------- machine ----------
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot;
    var f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", body: '<div class="h-body h-pt">' + (f ? U.ageBanner(f) : "") + notice("quiet", "hourglass-medium", "No snapshot yet", NOSNAP) + "</div>" };
    var m = C.machineById(snap, id);
    if (!m) return { tone: "quiet", body: '<div class="h-body h-pt">' + notice("quiet", "info", "Not in this snapshot", "The newest snapshot no longer lists this machine.") + "</div>" };
    var c = C.card(m), tone = c.planned ? "quiet" : c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it."
      : c.down ? "It has stopped reporting." : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look here." : "All good. " + c.counts + ".";
    var hero = '<header class="h-hero h-hero-card"><div class="h-glass h-herocard t-' + tone + '"><span class="ic h-hic t-' + tone + '">' + icon(c.planned ? "moon" : tone === "ok" ? "check-circle" : tone === "down" ? "warning-octagon" : "hourglass-medium") + "</span>" +
      '<p class="eyebrow">' + (c.word ? U.tag(tone, c.word) : "") + (m.os ? " <span>" + esc(m.os) + "</span>" : "") + '</p><h2 class="h-name mono">' + esc(c.name) + '</h2><p class="lede">' + esc(lede) + "</p>" +
      (c.status ? '<p class="sub mono h-kind">' + esc(c.status) + "</p>" : "") + ageLine(f) + "</div></header>";
    var b = '<div class="h-body">' + (f.warn || f.detail ? U.ageBanner(f) : "");
    if (c.meters.length) b += glass("h-vitals h-rise", c.meters.map(function (x) {
      return '<div class="h-vital"><span class="k">' + esc(x.label) + (x.subject ? ' <span class="mono">' + esc(x.subject) + "</span>" : "") + '</span><span class="v' + (x.hot ? " hot" : "") + '">' + x.percent + "<small>%</small></span>" +
        '<div class="meter"><b class="' + (x.hot ? "hot" : "") + '" style="width:' + x.percent + '%"></b></div></div>';
    }).join(""));
    else if (c.hardware) b += '<p class="sub h-line">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += glass("pad h-sec h-rise", '<div class="h-sec-h"><h2 class="h2">The last day</h2><span class="sub">Each block is half an hour</span></div>' + U.strip(c.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div class="h-legend">' + U.legend() + "</div>");
    if (mine.length) b += '<h2 class="group-h">Needs a look</h2><div class="stack">' + mine.map(function (i) { return '<div class="h-rise">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>";
    b += '<h2 class="group-h">Services</h2>' + glass("h-svcs pad-s h-rise", services(c)) + "</div>";
    return { tone: tone, body: hero + b };
  }

  // ---------- render ----------
  function shell(o) {
    return U.phone({ top: o.top, body: (o.ptr ? ptr() : "") + '<div class="h-under" aria-hidden="true"></div>' + o.body, bottom: o.nav });
  }
  function render() {
    var r = route(), app = document.getElementById("app"), out, tone = "brand", page = null;
    if (r.name === "lock") out = U.phone({ body: U.lockScreen() });
    else if (r.name === "first") out = U.phone({ body: U.firstRun() });
    else if (r.name === "add") out = shell({ top: topbar("Add a server", { back: true, backIcon: "x", backLabel: "Cancel", server: false }), body: pageHead(r.id === "paste" ? "Paste a code" : "Add a server", null) + '<div class="h-shared">' + U.addServer(r.id) + "</div>" });
    else if (r.name === "servers") {
      var n = C.servers().length, cur = C.selected();
      out = shell({ top: topbar("Servers", { server: false }), body: pageHead("Servers", n ? C.plural(n, "server is", "servers are") + " paired with this phone. Showing " + cur.name + "." : "No server is paired with this phone yet.") + '<div class="h-shared">' + U.serversList() + "</div>", nav: nav("servers") });
    } else if (r.name === "settings") {
      out = shell({ top: topbar("Settings", { server: false }), body: pageHead("Settings", "Everything here starts at the value the app has always used. Change what suits you.") + '<div class="h-shared">' + U.settingsGroups() + U.about() + "</div>", nav: nav("settings") });
    } else {
      page = r.name === "service" ? service(r.id) : r.name === "machine" ? machine(r.id) : home();
      tone = page.tone || "brand";
      if (page.full) out = U.phone({ body: page.full });
      else {
        var title = r.name === "service" ? "Service" : r.name === "machine" ? "Machine" : "Home";
        var noServer = !C.servers().length;
        out = shell({
          top: topbar(title, { back: r.name !== "home", tools: !noServer }), ptr: true,
          body: noServer ? '<div class="h-body h-pt">' + notice("quiet", "device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.") + "</div>" : page.body,
          nav: nav(r.name === "home" ? "home" : "")
        });
      }
    }
    app.innerHTML = out;
    var ph = app.querySelector(".phone");
    ph.classList.add("h-ph");
    if (ph.querySelector(".h-top")) ph.classList.add("has-top");
    if (ph.querySelector(".h-nav")) ph.classList.add("has-nav");
    if (ph.querySelector(".h-hero")) ph.classList.add("has-hero");
    ph.insertAdjacentHTML("afterbegin", orbs(tone));
    ph.dataset.tone = tone;
    after(r, page);
  }

  function after(r, page) {
    U.wire(render);
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = back; });
    document.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { spin(true); U.fakeRefresh(function () { spin(false); }); }; });
    document.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = picker; });
    document.querySelectorAll("[data-machine]").forEach(function (b) { b.onclick = function () { toggleMachine(b); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; keepScroll(render); }; });
    document.querySelectorAll("[data-itab]").forEach(function (b) { b.onclick = function () { if (issueTab === b.dataset.itab) return; issueTab = b.dataset.itab; keepScroll(render); }; });
    snapDots();
    pullToRefresh();
    scrollFallback(document.getElementById("screen"), document.querySelector(".phone"));
    riseFallback(document.getElementById("screen"));
    if (page && r.name === "home" && page.count != null) countUp(page.count);
  }
  function back() { if (history.length > 1) history.back(); else location.hash = "#home"; }
  function keepScroll(fn) { var s = document.getElementById("screen"), y = s ? s.scrollTop : 0; fn(); var t = document.getElementById("screen"); if (t) t.scrollTop = y; }

  function toggleMachine(b) {
    var id = b.dataset.machine, row = b.closest(".h-mrow"), open = !openMachines[id];
    openMachines[id] = open;
    row.classList.toggle("open", open);
    b.setAttribute("aria-expanded", open);
    var fold = row.querySelector(".h-fold");
    if (open) fold.removeAttribute("inert"); else fold.setAttribute("inert", "");
  }

  function snapDots() {
    var snap = document.getElementById("snap");
    if (!snap) return;
    var dots = document.querySelectorAll(".h-dots i"), pos = document.getElementById("pos"), n = snap.children.length;
    snap.addEventListener("scroll", function () {
      var w = snap.children[0].getBoundingClientRect().width + 12;
      var k = Math.max(0, Math.min(n - 1, Math.round(snap.scrollLeft / w)));
      dots.forEach(function (d, j) { d.classList.toggle("on", j === k); });
      if (pos) pos.textContent = (k + 1) + " of " + n;
    }, { passive: true });
  }

  // The big figure counts up once when Home first shows it.
  function countUp(n) {
    var el = document.querySelector(".h-num");
    if (!el || reduced || counted === C.scenario + n || n < 1) { counted = C.scenario + n; return; }
    counted = C.scenario + n;
    var t0 = null, dur = 700;
    function step(t) {
      if (t0 == null) t0 = t;
      var p = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - p, 3);
      el.textContent = Math.round(e * n);
      if (p < 1) requestAnimationFrame(step);
    }
    el.textContent = "0";
    requestAnimationFrame(step);
  }

  // Where CSS scroll timelines are missing, the same effects follow a variable set on scroll.
  function scrollFallback(sc, ph) {
    if (!sc || timelines || reduced) return;
    ph.classList.add("h-js");
    var raf = 0;
    function set() { raf = 0; var y = sc.scrollTop; ph.style.setProperty("--sy", y); }
    sc.addEventListener("scroll", function () { if (!raf) raf = requestAnimationFrame(set); }, { passive: true });
    set();
  }
  function riseFallback(sc) {
    if (!sc || timelines || reduced || !("IntersectionObserver" in window)) return;
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { root: sc, threshold: 0.08 });
    sc.querySelectorAll(".h-rise").forEach(function (el) { el.classList.add("h-io"); io.observe(el); });
  }

  // ---------- flyouts: sheets and dialogs grow out of what was tapped ----------
  var lastTap = null;
  document.addEventListener("pointerdown", function (e) {
    var t = e.target.closest(".issue, .h-svc, button, a, [role=button]");
    lastTap = t ? t.getBoundingClientRect() : null;
  }, true);
  document.addEventListener("keydown", function () { lastTap = null; }, true);

  function grow(el, from, reverse, done) {
    if (reduced || !el.animate) { if (done) done(); return; }
    var to = el.getBoundingClientRect();
    var start;
    if (from && to.width && to.height) {
      var dx = from.left - to.left, dy = from.top - to.top, sx = Math.max(.05, from.width / to.width), sy = Math.max(.05, from.height / to.height);
      start = { transform: "translate(" + dx + "px," + dy + "px) scale(" + sx + "," + sy + ")", opacity: 0.35 };
    } else start = { transform: "translateY(24px) scale(.96)", opacity: 0 };
    var end = { transform: "none", opacity: 1 };
    el.style.transformOrigin = "0 0";
    var a = el.animate(reverse ? [end, start] : [start, end], { duration: reverse ? 240 : 420, easing: reverse ? "cubic-bezier(.4,0,.6,1)" : "cubic-bezier(.2,.8,.2,1)", fill: reverse ? "forwards" : "none" });
    Array.prototype.forEach.call(el.children, function (k) {
      k.animate(reverse ? [{ opacity: 1 }, { opacity: 0 }] : [{ opacity: 0 }, { opacity: 0, offset: .35 }, { opacity: 1 }], { duration: reverse ? 140 : 420, easing: "ease-out", fill: reverse ? "forwards" : "none" });
    });
    a.onfinish = function () { if (done) done(); };
  }
  // Shared sheets and dialogs (picker, remove) are watched so they can grow from the tap and shrink back to it.
  var layerOrigin = new WeakMap();
  new MutationObserver(function (ms) {
    ms.forEach(function (m) {
      if (m.type === "childList") m.addedNodes.forEach(function (n) {
        if (n.nodeType !== 1 || !n.matches(".sheet, .dialog")) return;
        layerOrigin.set(n, lastTap);
        n.classList.add("h-grow");
        requestAnimationFrame(function () { grow(n, lastTap, false); });
      });
      if (m.type === "attributes" && m.target.matches(".sheet.h-grow, .dialog.h-grow") && !m.target.classList.contains("show") && m.oldValue && m.oldValue.indexOf("show") > -1) {
        grow(m.target, layerOrigin.get(m.target), true);
      }
    });
  }).observe(document.getElementById("app"), { childList: true, subtree: true, attributes: true, attributeFilter: ["class"], attributeOldValue: true });

  // A service tapped on Home or a machine opens over it, growing out of the card; the URL still says #service/<id>.
  var fly = null, skipHash = null;
  document.addEventListener("click", function (e) {
    var a = e.target.closest('a[href^="#service/"]');
    if (!a || fly || e.defaultPrevented || e.metaKey || e.ctrlKey) return;
    var r = route();
    if (r.name !== "home" && r.name !== "machine") return;
    e.preventDefault();
    var origin = a.closest(".issue, .h-svc") || a;
    openFly(a.getAttribute("href").split("/").slice(1).join("/"), origin);
  });
  function openFly(id, origin) {
    var ph = document.querySelector(".phone"), page = service(id);
    var s = C.selected();
    var wrap = document.createElement("div");
    wrap.className = "h-fly";
    wrap.setAttribute("role", "dialog"); wrap.setAttribute("aria-modal", "true"); wrap.setAttribute("aria-label", page.title || "Service");
    wrap.dataset.tone = page.tone || "quiet";
    wrap.innerHTML = orbs(page.tone || "quiet") +
      '<header class="h-top h-flyhead"><button class="iconbtn" type="button" data-flyback aria-label="Back">' + icon("arrow-left") + '</button><h1 class="h-top-t">Service</h1>' +
      (s ? '<span class="h-chip quiet mono">' + esc(s.name) + "</span>" : "") + '<button class="iconbtn" type="button" data-flyrefresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button></header>" +
      '<div class="h-flyscreen" id="flyscreen" tabindex="-1"><div class="h-under"></div>' + page.body + "</div>";
    ph.appendChild(wrap);
    fly = { el: wrap, origin: origin, prev: location.hash || "#home" };
    skipHash = "#service/" + id;
    location.hash = skipHash;
    wrap.querySelector("[data-flyback]").onclick = back;
    wrap.querySelector("[data-flyrefresh]").onclick = function () { U.fakeRefresh(); };
    U.wire(render);
    scrollFallback(wrap.querySelector("#flyscreen"), wrap);
    riseFallback(wrap.querySelector("#flyscreen"));
    grow(wrap, origin.getBoundingClientRect(), false, function () { var f = document.getElementById("flyscreen"); if (f) f.focus({ preventScroll: true }); });
  }
  function closeFly(then) {
    var f = fly; fly = null;
    var from = f.origin && f.origin.isConnected ? f.origin.getBoundingClientRect() : null;
    grow(f.el, from, true, function () { f.el.remove(); if (then) then(f); });
  }

  // ---------- picker ----------
  function picker() {
    var cur = C.selected();
    U.openLayer('<h2 class="h2" style="margin:0 4px 10px">Show a server</h2>' + C.servers().map(function (s) {
      var on = cur && s.id === cur.id, fr = C.freshness(s.state);
      return '<button class="h-pick" type="button" data-pick="' + esc(s.id) + '"' + (on ? ' aria-current="true"' : "") + '><span><span class="srv-name">' + esc(s.name) + '</span><span class="sub mono">' + esc(C.host(s.relay)) + " · " + esc(fr.text.replace("Snapshot made ", "")) + "</span></span>" + (on ? icon("check") : "") + "</button>";
    }).join(""), "sheet");
    setTimeout(function () {
      document.querySelectorAll("[data-pick]").forEach(function (b) {
        b.onclick = function () { C.select(b.dataset.pick); U.closeLayer(); setTimeout(render, reduced ? 0 : 250); };
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

  window.addEventListener("hashchange", function () {
    if (skipHash && location.hash === skipHash) { skipHash = null; return; }
    skipHash = null;
    if (fly) {
      var r = route();
      if (r.name === "service") { fly.el.remove(); fly = null; }
      else {
        closeFly(function (f) { if ((location.hash || "#home") !== f.prev) { render(); var s = document.getElementById("screen"); if (s) s.scrollTop = 0; } });
        return;
      }
    }
    render();
    var s = document.getElementById("screen");
    if (s) { s.scrollTop = 0; s.focus({ preventScroll: true }); }
  });
  render();
})();
