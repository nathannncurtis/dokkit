// Direction J, Statement: one inset gradient card per page that settles into a pinned card as you scroll,
// big cards under it, and an issue card that opens into its own page.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var openMachines = {}, openMore = {}, issueTab = null;
  var seen = {}, morphId = null, quiet = false, pendingBack = null;
  var canTimeline = window.CSS && CSS.supports("animation-timeline: scroll()");

  function route() {
    var h = location.hash || U.startRoute();
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/") };
  }

  // ---------- chrome ----------
  function nav(current) {
    var tabs = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="j-nav" aria-label="Main">' + tabs.map(function (t) {
      var on = t[0] === current;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + '><span class="pill">' + icon(t[2]) + "</span><span>" + t[1] + "</span></a>";
    }).join("") + "</nav>";
  }
  function topbar(title, opts) {
    opts = opts || {};
    var s = C.selected(), many = C.servers().length > 1;
    return '<header class="j-top">' +
      (opts.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (opts.backLabel || "Back") + '" style="margin-left:0">' + icon(opts.backIcon || "arrow-left") + "</button>" : '<span class="j-top-gap"></span>') +
      '<div class="j-top-t" style="padding-left:' + (opts.back ? 8 : 0) + 'px"><h1>' + esc(title) + "</h1>" + (opts.server !== false && s ? '<p class="sub">' + esc(s.name) + "</p>" : "") + "</div>" +
      (opts.tools ? (many ? '<button class="iconbtn" type="button" data-picker aria-label="Switch server">' + icon("swap") + "</button>" : "") +
        '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function ptr() { return '<div class="j-ptr" id="ptr" aria-hidden="true"><span class="j-ptr-dot">' + icon("arrows-clockwise") + "</span></div>"; }

  // The statement card at the top of every page.
  function hero(o) {
    return '<div class="j-pin"><section class="j-hero j-tone-' + o.tone + '"' + (o.morph ? ' style="view-transition-name:j-morph"' : "") + ">" +
      '<div class="j-fold"><div class="j-hrow"><span class="j-hic" aria-hidden="true">' + icon(o.icon) + '</span><p class="j-eye">' + (o.eye || "") + "</p></div></div>" +
      '<h2 class="j-big' + (o.mono ? " mono" : "") + '">' + o.big + "</h2>" +
      '<div class="j-fold">' + (o.lede ? '<p class="j-lede">' + o.lede + "</p>" : "") + (o.extra || "") + (o.age ? '<p class="j-age">' + icon("clock") + " " + esc(o.age) + "</p>" : "") + "</div>" +
      "</section></div>";
  }
  // A number that ticks up once, the first time it is shown.
  function num(n, key) { return '<span class="j-num" data-to="' + n + '" data-key="' + esc(key) + '">' + n + "</span>"; }
  function figure(n, word, tone, key) { return '<div class="j-fig ' + (n ? tone : "") + '"><b>' + num(n, key) + "</b><span>" + esc(word) + "</span></div>"; }
  function card(inner, cls) { return '<section class="j-card j-rise ' + (cls || "") + '">' + inner + "</section>"; }
  function notice(tone, ic, title, text) {
    return card('<div class="j-pad" style="display:flex;gap:16px;align-items:flex-start">' + U.ic(tone, ic) + '<div><p class="j-h">' + esc(title) + '</p><p class="j-hsub">' + esc(text) + "</p></div></div>");
  }
  function ageLine(f) { return f && !f.warn && !f.detail ? f.text : null; }

  // ---------- small parts ----------
  function pipTone(mark) { return mark === "down" ? "down" : mark === "degraded" ? "degraded" : ""; }
  function svcRow(r) {
    return '<a class="j-svc" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="mono name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id], out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub j-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="j-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub j-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function machineRow(c) {
    var open = !!openMachines[c.id];
    return '<section class="j-mrow' + (open ? " open" : "") + '">' +
      '<button class="j-mhead" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      (c.hardware ? '<span class="pip ' + pipTone(c.mark) + '" aria-hidden="true"></span>' : '<span class="j-gicon" aria-hidden="true">' + icon("cloud") + "</span>") +
      '<span class="j-mtext"><span class="mono j-mname">' + esc(c.name) + "</span>" +
      (c.status ? '<span class="sub' + (c.down ? " j-down" : "") + '">' + esc(c.status) + "</span>" : "") +
      '<span class="sub">' + esc(c.counts) + "</span></span>" + icon("caret-down").replace('class="ph', 'class="chev ph') + "</button>" +
      (open ? '<div class="j-mbody">' +
        (c.meters.length ? '<div class="j-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
        (c.notice ? '<p class="j-notice t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
        '<div class="j-svcs">' + services(c) + "</div>" +
        (c.hardware ? '<a class="btn soft block" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
        "</div>" : "") +
      "</section>";
  }
  function noSnapshot(f) {
    return { tone: "quiet", top: hero({ tone: "quiet", icon: "hourglass-medium", eye: esc(C.greeting()), big: "No snapshot yet",
      lede: "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again." }),
      body: f && f.detail ? U.ageBanner(f) : "" };
  }

  // ---------- home ----------
  function home() {
    var s = C.selected();
    if (!s) return null;
    var st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) return noSnapshot(f);
    var h = C.home(snap), top = h.top;
    var tone = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var icn = { down: "warning-octagon", degraded: "hourglass-medium", soon: "calendar", ok: "check-circle" }[tone];
    var big = top.kind === "fine" ? esc(top.headline)
      : h.needs.length ? num(h.needs.length, "hero-needs") + " " + (h.needs.length === 1 ? "thing needs you" : "things need you")
      : num(h.soon.length, "hero-soon") + " " + (h.soon.length === 1 ? "thing is coming up" : "things are coming up");
    var lede = top.kind === "fine" ? top.detail
      : h.needs.length ? h.lede.replace(/^[^.]*\.\s*/, "")
      : "Nothing needs you. Plan for " + (h.soon.length === 1 ? "it" : "them") + " when it suits you.";

    var b = "";
    if (f.warn || f.detail) b += U.ageBanner(f);
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub j-left">' + icon("info") + " " + esc(lo) + "</p>";
    var fine = snap.inbox.fine && snap.inbox.fine.services || 0;
    b += card('<div class="j-figs">' + figure(h.needs.length, "need you", tone === "down" ? "down" : "degraded", "fig-needs") + figure(h.soon.length, "coming up", "soon", "fig-soon") + figure(fine, "fine", "ok", "fig-fine") + "</div>");

    if (top.kind === "attention") {
      var both = h.needs.length && h.soon.length;
      if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";
      var list = issueTab === "needs" ? h.needs : h.soon;
      b += (both ? '<div class="seg j-seg" role="group" aria-label="Show"><button type="button" data-itab="needs" aria-pressed="' + (issueTab === "needs") + '">Needs you <span class="mono">' + h.needs.length + '</span></button><button type="button" data-itab="soon" aria-pressed="' + (issueTab === "soon") + '">Coming up <span class="mono">' + h.soon.length + "</span></button></div>"
          : '<h2 class="j-label">' + (issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>") +
        '<div class="j-issues">' + list.map(function (i) {
          return '<div class="j-rise" data-morph="' + esc(i.service) + '"' + (morphId === i.service ? ' style="view-transition-name:j-morph"' : "") + ">" + U.issueCard(i, snap, "#service/" + i.service) + "</div>";
        }).join("") + "</div>";
      if (h.snoozed) b += '<p class="j-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
      if (h.fineLine) b += '<div class="allgood j-good j-rise">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    } else if (h.snoozed) {
      b += '<p class="j-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    }

    var hw = h.hardware.filter(function (c) { return c.lastDay; });
    if (hw.length) {
      b += card('<div class="j-pad"><h2 class="j-h">The last day</h2><p class="j-hsub">Each block is half an hour. Now is on the right.</p><div class="j-day-rows">' +
        hw.map(function (c, n) { return '<a class="mono" href="#machine/' + esc(c.id) + '">' + esc(c.name) + "<span>" + icon("caret-right") + "</span></a>" + U.strip(c.id, true).replace('class="strip', 'data-row="' + n + '" class="strip'); }).join("") +
        "</div>" + U.legend() + "</div>");
    }
    if (h.hardware.length) b += '<h2 class="j-label">Machines</h2>' + card('<div class="j-mlist">' + h.hardware.map(machineRow).join("") + "</div>");
    if (h.groups.length) b += '<h2 class="j-label">Not on a machine</h2>' + card('<div class="j-mlist">' + h.groups.map(machineRow).join("") + "</div>");
    return { tone: tone, top: hero({ tone: tone, icon: icn, eye: icon("hand-waving") + " " + esc(C.greeting()), big: big, lede: esc(lede), age: ageLine(f) }), body: b };
  }

  // ---------- service ----------
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return noSnapshot(f);
    var v = C.service(snap, id);
    if (!v) return { tone: "quiet", top: hero({ tone: "quiet", icon: "info", eye: "Service", big: "Not in this snapshot", lede: "The newest snapshot no longer lists this service." }), body: "" };
    var tone = v.level.tone;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var top = hero({ tone: tone, icon: v.level.icon, mono: true, morph: morphId === id,
      eye: U.tag(tone, v.level.word) + (v.machine ? ' <a class="mono" href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : ""),
      big: esc(v.name), lede: v.note ? esc(v.note) : "", extra: line ? '<p class="sub mono" style="margin-top:8px;font-size:12.5px">' + esc(line) + "</p>" : "", age: ageLine(f) });
    var b = f.warn || f.detail ? U.ageBanner(f) : "";
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub j-left">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var nm = C.names(snap)[i.service];
      var meta = [nm, i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += card('<div class="j-chead"><span class="j-h">Open issue</span><span class="sub">' + esc(i.short_id) + "</span></div>" +
        '<div class="j-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + "</p><h3>" + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="meta mono">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="j-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="j-time">' + v.history.slice().reverse().map(function (e, n) {
          return '<li><span class="dot ' + (n === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub mono">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : ""));
    }
    if (v.checks.length) {
      b += card('<div class="j-chead"><span class="j-h">Checks</span><span class="sub">' + v.checks.length + "</span></div>" +
        '<div style="padding-bottom:8px">' + v.checks.map(function (c) {
          return '<div class="j-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div><p class="mono j-cname">' + esc(c.name) + '</p><p class="j-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</p>" +
            (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>";
        }).join("") + "</div>");
    }
    if (v.job.length) {
      var run = v.jobRaw && v.jobRaw.last_run;
      b += card('<div class="j-chead"><span class="j-h">Job</span></div><dl class="j-dl">' +
        v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl>" +
        (run && run.result === "running" && run.total ? '<div class="j-prog"><div class="meter" role="progressbar" aria-valuenow="' + run.done + '" aria-valuemax="' + run.total + '"><b class="run" style="width:' + Math.round(run.done / run.total * 100) + '%"></b></div></div>' : ""));
    }
    if (v.chart.some(function (x) { return x != null; })) {
      var present = v.chart.filter(function (x) { return x != null; });
      b += card('<div class="j-pad"><div style="display:flex;justify-content:space-between;align-items:baseline;gap:10px"><span class="j-h">Last 24 hours</span>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" +
        '<p style="margin:10px 0 0;font-size:34px;font-weight:800;letter-spacing:-.03em;font-variant-numeric:tabular-nums">' + num(Math.round(present[present.length - 1]), "chart-" + id) + '<span class="sub" style="font-size:14px;font-weight:600;margin-left:6px">now</span></p>' +
        U.chart(v.chart, v.metric) + '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></div>', "j-chart");
    }
    if (v.logs.length) b += card('<div class="j-chead"><span class="j-h">Last log lines</span><span class="sub">' + v.logs.length + '</span></div><div class="j-logs">' + U.logLines(v.logs) + "</div>");
    return { tone: tone, top: top, body: b };
  }

  // ---------- machine ----------
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return noSnapshot(f);
    var m = C.machineById(snap, id);
    if (!m) return { tone: "quiet", top: hero({ tone: "quiet", icon: "info", eye: "Machine", big: "Not in this snapshot", lede: "The newest snapshot no longer lists this machine." }), body: "" };
    var c = C.card(m), tone = c.planned ? "quiet" : c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it."
      : c.down ? "It has stopped reporting." : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look here." : "All good. " + c.counts + ".";
    var top = hero({ tone: tone, mono: true, icon: c.planned ? "moon" : tone === "ok" ? "check-circle" : tone === "down" ? "warning-octagon" : "hourglass-medium",
      eye: (c.word ? U.tag(tone, c.word) : "") + (m.os ? " " + esc(m.os) : ""), big: esc(c.name), lede: esc(lede),
      extra: c.status ? '<p class="sub mono" style="margin-top:8px;font-size:12.5px">' + esc(c.status) + "</p>" : "", age: ageLine(f) });
    var b = f.warn || f.detail ? U.ageBanner(f) : "";
    if (c.meters.length) {
      b += card('<div class="j-vitals">' + c.meters.map(function (x, n) {
        return '<div class="j-vital' + (x.hot ? " hot" : "") + '"><span class="k">' + esc(x.label) + (x.subject ? ' <span class="mono">' + esc(x.subject) + "</span>" : "") + "</span><b>" + num(x.percent, "v-" + id + n) + "<small>%</small></b>" +
          '<div class="meter" role="meter" aria-label="' + esc(x.label) + '" aria-valuenow="' + x.percent + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (x.hot ? "hot" : "") + '" style="width:' + x.percent + '%"></b></div></div>';
      }).join("") + "</div>");
    } else if (c.hardware) b += '<p class="sub j-line">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += card('<div class="j-pad"><span class="j-h">The last day</span><p class="j-hsub" style="margin-bottom:16px">Each block is half an hour.</p>' + U.strip(c.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div style="margin-top:12px">' + U.legend() + "</div></div>");
    if (mine.length) b += '<h2 class="j-label">Needs a look</h2><div class="j-issues">' + mine.map(function (i) { return '<div class="j-rise" data-morph="' + esc(i.service) + '">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>";
    b += '<h2 class="j-label">Services</h2>' + card('<div class="j-svcs pad-s">' + services(c) + "</div>");
    return { tone: tone, top: top, body: b };
  }

  // ---------- servers, settings and the rest, in the same card ----------
  function serversPage() {
    var list = C.servers(), cur = C.selected();
    if (!list.length) return { tone: "quiet", top: hero({ tone: "quiet", icon: "device-mobile", eye: "Servers", big: "No server paired",
      lede: "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it." }), body: '<a class="btn primary block" href="#add">' + icon("plus") + " Add a server</a>" };
    var f = C.freshness(cur.state);
    return { tone: "brand", top: hero({ tone: "brand", icon: "hard-drives", eye: "Servers", big: num(list.length, "srv-n") + (list.length === 1 ? " server paired" : " servers paired"),
      lede: "Showing " + esc(cur.name) + ". Remove one and its key, token and saved snapshot leave this phone.", age: f.text }), body: U.serversList() };
  }
  function settingsPage() {
    var n = C.SETTINGS.filter(function (s) { return C.isChanged(s.key); }).length;
    return { tone: "brand", top: hero({ tone: "brand", icon: "sliders-horizontal", eye: "Settings", big: n ? num(n, "set-n") + " changed" : "All on defaults",
      lede: "Each starts at the value the app has always used, and shows it with a Reset next to it." }), body: U.settingsGroups() + U.about() };
  }
  function centerCard(tone, inner) { return '<div class="j-center j-settle"><section class="j-hero j-tone-' + tone + '">' + inner + "</section></div>"; }
  function lockPage() {
    var msg = C.scenario === "nolock" ? "Set a screen lock on this phone to use Dokkit." : C.scenario === "stayed" ? "Dokkit stayed locked." : "Unlock with your fingerprint, face or screen lock.";
    var tone = C.scenario === "nolock" || C.scenario === "stayed" ? "degraded" : "brand";
    return centerCard(tone, '<div class="j-hrow"><span class="j-hic" aria-hidden="true">' + icon("lock-simple") + '</span><p class="j-eye">Dokkit</p></div><h1 class="j-big">Dokkit is locked</h1><p class="j-lede">' + esc(msg) + "</p>" +
      '<button class="btn primary block" type="button" data-go="#home" style="min-height:52px;border-radius:16px">' + icon("fingerprint") + " Unlock</button>");
  }
  function firstPage() {
    return centerCard("brand", '<div class="j-mark">' + U.mark(64) + '</div><h1 class="j-big">Dokkit</h1><p class="j-lede">A read-only view of your Dokkit server. Alerts still reach you the usual way. Nothing here can change anything.</p>' +
      '<p class="sub" style="margin-top:12px">The code is in the Dokkit web interface: Settings, Phones, Add a phone.</p>' +
      '<div class="j-acts"><a class="btn primary block" href="#add" style="min-height:52px;border-radius:16px">' + icon("qr-code") + ' Scan the code</a><a class="btn ghost block" href="#add/paste">Paste the code instead</a></div>');
  }
  function addPage(mode) {
    var paste = mode === "paste";
    return { tone: "brand", top: hero({ tone: "brand", icon: paste ? "clipboard-text" : "qr-code", eye: "Add a server", big: paste ? "Paste the code" : "Scan the code",
      lede: paste ? "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone." : "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once." }),
      body: '<div class="j-add">' + U.addServer(mode) + "</div>" };
  }

  // ---------- render ----------
  function page(r) {
    if (r.name === "servers") return serversPage();
    if (r.name === "settings") return settingsPage();
    if (r.name === "add") return addPage(r.id);
    if (r.name === "service") return service(r.id);
    if (r.name === "machine") return machine(r.id);
    return home();
  }
  function render() {
    var r = route(), app = document.getElementById("app"), out, tone = "brand";
    if (r.name === "lock") out = U.phone({ body: lockPage() }), tone = C.scenario === "nolock" || C.scenario === "stayed" ? "degraded" : "brand";
    else if (r.name === "first" || (r.name === "home" && !C.servers().length)) out = U.phone({ body: firstPage() });
    else {
      var p = page(r);
      tone = p.tone;
      var tab = r.name === "servers" || r.name === "settings" ? r.name : r.name === "home" ? "home" : "";
      var title = { home: "Home", service: "Service", machine: "Machine", servers: "Servers", settings: "Settings", add: "Add a server" }[r.name] || "Home";
      var inner = ["home", "service", "machine"].indexOf(r.name) > -1;
      out = U.phone({
        top: topbar(title, { back: r.name === "service" || r.name === "machine" || r.name === "add", backIcon: r.name === "add" ? "x" : null, backLabel: r.name === "add" ? "Cancel" : null, tools: inner, server: inner }),
        body: (inner ? ptr() : "") + p.top + '<div class="j-body">' + p.body + "</div>",
        bottom: r.name === "add" ? "" : nav(tab)
      });
    }
    app.innerHTML = out;
    var ph = app.querySelector(".phone");
    ph.classList.add("j", "j-tone-" + tone);
    after();
  }

  function after() {
    U.wire(render);
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = back; });
    document.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { b.classList.add("j-spin"); spin(true); U.fakeRefresh(function () { spin(false); b.classList.remove("j-spin"); }); }; });
    document.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = picker; });
    document.querySelectorAll("[data-machine]").forEach(function (b) { b.onclick = function () { openMachines[b.dataset.machine] = !openMachines[b.dataset.machine]; keepScroll(render); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; keepScroll(render); }; });
    document.querySelectorAll("[data-itab]").forEach(function (b) { b.onclick = function () { issueTab = b.dataset.itab; keepScroll(render); }; });
    document.querySelectorAll("[data-morph]").forEach(function (el) {
      el.addEventListener("click", function (e) {
        if (e.target.closest("a") && !e.target.closest('a[href^="#service/"]')) return;
        e.preventDefault();
        openInto(el, "#service/" + el.dataset.morph);
      });
    });
    settleOnScroll();
    fillOnce();
    tickOnce();
    pullToRefresh();
  }
  function keepScroll(fn) { var s = document.getElementById("screen"), y = s ? s.scrollTop : 0; fn(); var t = document.getElementById("screen"); if (t) { t.scrollTop = y; t.dispatchEvent(new Event("scroll")); } }

  // ---------- motion ----------
  // Where there is no scroll timeline, a listener feeds the same --p the CSS uses.
  function settleOnScroll() {
    var sc = document.getElementById("screen");
    if (!sc) return;
    if (C.reduced) return;
    if (canTimeline) { sc.classList.add("j-scroll"); return; }
    var queued = false;
    function set() { queued = false; sc.style.setProperty("--p", Math.min(1, Math.max(0, sc.scrollTop / 240)).toFixed(3)); }
    sc.addEventListener("scroll", function () { if (!queued) { queued = true; requestAnimationFrame(set); } }, { passive: true });
    set();
  }
  function fillOnce() {
    document.querySelectorAll(".strip").forEach(function (s, n) {
      var key = (location.hash || "#home") + (s.getAttribute("aria-label") || n);
      if (seen[key] || C.reduced) return;
      seen[key] = true;
      s.classList.add("j-fill");
      s.style.setProperty("--row", s.dataset.row || 0);
      Array.prototype.forEach.call(s.children, function (c, i) { c.style.setProperty("--i", i); });
    });
    document.querySelectorAll(".j-chart").forEach(function (c) {
      var key = "chart" + location.hash;
      if (seen[key] || C.reduced) return;
      seen[key] = true;
      c.classList.add("j-fillc");
      c.querySelectorAll(".spark i").forEach(function (b, i) { b.style.setProperty("--i", i); });
    });
  }
  function tickOnce() {
    document.querySelectorAll(".j-num").forEach(function (el) {
      var key = el.dataset.key, to = +el.dataset.to;
      if (seen["n" + key] === to || C.reduced || !to) { seen["n" + key] = to; return; }
      var from = seen["n" + key] || 0;
      seen["n" + key] = to;
      var t0 = performance.now(), dur = 700;
      (function step(t) {
        var k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
        el.textContent = Math.round(from + (to - from) * e);
        if (k < 1) requestAnimationFrame(step);
      })(t0);
    });
  }

  // An issue card opens into its page: a view transition where there is one, a growing card where there is not.
  function openInto(el, hash) {
    var id = hash.split("/")[1];
    if (C.reduced) { location.hash = hash; return; }
    morphId = id;
    if (document.startViewTransition) {
      el.style.viewTransitionName = "j-morph";
      document.startViewTransition(function () { quiet = true; location.hash = hash; render(); toTop(); });
      return;
    }
    var from = el.getBoundingClientRect(), ph = document.querySelector(".phone").getBoundingClientRect();
    var card = el.querySelector(".issue") || el, fly = document.createElement("div");
    fly.className = "j-fly";
    fly.style.cssText = "left:" + from.left + "px;top:" + from.top + "px;width:" + from.width + "px;height:" + from.height + "px;background:" + getComputedStyle(card).backgroundImage + "," + getComputedStyle(card).backgroundColor;
    document.body.appendChild(fly);
    fly.animate([{ left: from.left + "px", top: from.top + "px", width: from.width + "px", height: from.height + "px", borderRadius: "24px" },
      { left: ph.left + "px", top: ph.top + "px", width: ph.width + "px", height: ph.height + "px", borderRadius: "0px" }], { duration: 380, easing: "cubic-bezier(.2,.8,.2,1)", fill: "forwards" })
      .onfinish = function () {
        quiet = true; location.hash = hash; render(); toTop();
        fly.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 220, fill: "forwards" }).onfinish = function () { fly.remove(); };
      };
  }
  function back() {
    var r = route();
    if (r.name === "service" && morphId === r.id && document.startViewTransition && !C.reduced) {
      document.startViewTransition(function () { return new Promise(function (res) { pendingBack = res; history.back(); setTimeout(function () { if (pendingBack) { pendingBack(); pendingBack = null; } }, 400); }); })
        .finished.then(function () { morphId = null; });
      return;
    }
    if (history.length > 1) history.back(); else location.hash = "#home";
  }
  function toTop() { var s = document.getElementById("screen"); if (s) { s.scrollTop = 0; s.focus({ preventScroll: true }); } }

  function picker() {
    var cur = C.selected();
    U.openLayer('<h2 class="j-h" style="margin:0 6px 12px">Show a server</h2>' + C.servers().map(function (s) {
      var on = cur && s.id === cur.id;
      return '<button class="j-pick" type="button" data-pick="' + esc(s.id) + '"' + (on ? ' aria-current="true"' : "") + '><span><span class="srv-name">' + esc(s.name) + '</span><span class="sub mono">' + esc(C.host(s.relay)) + "</span></span>" + (on ? icon("check") : "") + "</button>";
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
    sc.addEventListener("mousedown", function (e) { if (!e.target.closest("a,button,input,select,textarea,[data-morph]")) start(e.clientY); });
    window.onmousemove = function (e) { move(e.clientY); };
    window.onmouseup = end;
  }

  window.addEventListener("hashchange", function () {
    if (quiet) { quiet = false; return; }
    render(); toTop();
    if (pendingBack) { pendingBack(); pendingBack = null; }
  });
  render();
})();
