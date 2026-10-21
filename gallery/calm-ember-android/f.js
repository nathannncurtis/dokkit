// Direction F, Flow: one gradient runs the whole page; the hero folds into the top bar as you scroll.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var openMachines = {}, openMore = {}, issueTab = null, counted = {};
  var scrollDriven = window.CSS && CSS.supports && CSS.supports("animation-timeline: scroll()");

  function route() {
    var h = location.hash || U.startRoute();
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/") };
  }

  // ---------- chrome ----------
  function nav(current) {
    var tabs = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="f-nav" aria-label="Main">' + tabs.map(function (t) {
      var on = t[0] === current;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + '><span class="pill">' + icon(t[2]) + "</span><span>" + t[1] + "</span></a>";
    }).join("") + "</nav>";
  }
  // The bar carries two titles: the page's name, and the hero's headline that takes its place once the hero has scrolled away.
  function topbar(title, fold, opts) {
    opts = opts || {};
    var s = C.selected(), many = C.servers().length > 1;
    return '<div class="f-chrome" aria-hidden="true"></div><header class="f-top">' +
      (opts.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (opts.backLabel || "Back") + '">' + icon(opts.backIcon || "arrow-left") + "</button>" : '<span class="f-top-gap"></span>') +
      '<div class="f-top-t"><h1 class="f-t1">' + esc(title) + "</h1>" + (fold ? '<p class="f-t2" aria-hidden="true">' + esc(fold) + "</p>" : "") +
      (opts.server !== false && s ? '<p class="sub f-tsrv">' + esc(s.name) + "</p>" : "") + "</div>" +
      (opts.tools ? (many ? '<button class="iconbtn f-chip" type="button" data-picker aria-label="Switch server" aria-haspopup="menu">' + icon("swap") + "</button>" : "") +
        '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function ptr() { return '<div class="c-ptr f-ptr" id="ptr" aria-hidden="true"><span class="c-ptr-dot">' + icon("arrows-clockwise") + "</span></div>"; }
  function flow() { return '<div class="f-flow" aria-hidden="true"><i class="b1"></i><i class="b2"></i><i class="b3"></i></div>'; }

  // One hero for every page: icon, eyebrow, a figure or a big line, the sentence, quiet figures under it.
  function hero(o) {
    var fig = o.figure != null
      ? '<p class="f-fig"><span class="f-num" data-count="' + o.figure + '">' + o.figure + '</span><span class="f-figl">' + esc(o.figLabel) + "</span></p>"
      : '<h2 class="f-big">' + esc(o.big) + "</h2>";
    return '<section class="f-hero' + (o.small ? " sm" : "") + '"><div class="f-hero-in">' +
      (o.icon ? '<span class="ic f-hic">' + icon(o.icon) + "</span>" : "") +
      (o.eyebrow ? '<p class="eyebrow f-eye">' + o.eyebrow + "</p>" : "") + (o.figure != null ? '<h2 class="sr">' + esc(o.figure + " " + o.figLabel) + "</h2>" : "") + fig +
      (o.lede ? '<p class="lede f-lede">' + esc(o.lede) + "</p>" : "") + (o.extra || "") +
      (o.stats && o.stats.length ? '<dl class="f-stats">' + o.stats.map(function (s) {
        return '<div class="' + (s[2] ? "t-" + s[2] + "-ink" : "") + '"><dt>' + esc(s[1]) + "</dt>" +
          (s[3] != null ? '<span class="meter f-smeter" role="meter" aria-label="' + esc(s[1]) + '" aria-valuenow="' + s[3] + '" aria-valuemin="0" aria-valuemax="100"><b class="' + (s[2] === "degraded" ? "hot" : "") + '" style="width:' + s[3] + '%"></b></span>' : "") +
          "<dd>" + esc(s[0]) + "</dd></div>";
      }).join("") + "</dl>" : "") +
      (o.age ? '<p class="f-age">' + icon("clock") + " " + esc(o.age) + "</p>" : "") + "</div></section>";
  }

  // ---------- small parts ----------
  function pipTone(mark) { return mark === "down" ? "down" : mark === "degraded" ? "degraded" : ""; }
  function svcRow(r) {
    return '<a class="c-svc f-press" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="mono name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id], out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub c-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="c-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub c-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function machineRow(c) {
    var open = !!openMachines[c.id];
    var worst = c.meters.slice().sort(function (a, b) { return b.percent - a.percent; })[0];
    return '<section class="c-mrow f-mrow' + (open ? " open" : "") + '">' +
      '<button class="c-mhead" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      (c.hardware ? '<span class="pip ' + pipTone(c.mark) + '" aria-hidden="true"></span>' : '<span class="c-gicon" aria-hidden="true">' + icon("cloud") + "</span>") +
      '<span class="c-mtext"><span class="mono c-mname">' + esc(c.name) + "</span>" +
      (c.status ? '<span class="sub' + (c.down ? " c-down" : "") + '">' + esc(c.status) + "</span>" : "") +
      '<span class="sub">' + esc(c.counts) + "</span></span>" +
      (worst ? '<span class="f-mfig' + (worst.hot ? " hot" : "") + '" aria-hidden="true"><b>' + worst.percent + "<small>%</small></b><em>" + esc(worst.label) + "</em></span>" : "") +
      icon("caret-down").replace('class="ph', 'class="chev ph') + "</button>" +
      (open ? '<div class="c-mbody f-unfold">' +
        (c.meters.length ? '<div class="c-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
        (c.notice ? '<p class="c-notice t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
        '<div class="c-svcs">' + services(c) + "</div>" +
        (c.hardware ? '<a class="btn soft block f-press" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
        "</div>" : "") +
      "</section>";
  }
  function notice(tone, ic, title, text) {
    return '<div class="panel pad c-notice-box f-rise">' + U.ic(tone, ic) + '<div><p class="h2">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div></div>";
  }
  var NO_SNAP = "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.";
  function freshAge(f) { return f.warn || f.detail ? null : f.text; }
  function banner(f) { return f.warn || f.detail ? '<div class="f-rise">' + U.ageBanner(f) + "</div>" : ""; }

  // ---------- home ----------
  function home() {
    var s = C.selected();
    if (!s) return { full: true };
    var st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) {
      return { tone: "quiet", fold: "No snapshot yet",
        body: hero({ icon: "hourglass-medium", eyebrow: esc(C.greeting()), big: "No snapshot yet", lede: NO_SNAP }) + '<div class="f-body">' + banner(f) + "</div>" };
    }
    var h = C.home(snap), top = h.top;
    var tone = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var icn = { down: "warning-octagon", degraded: "hourglass-medium", soon: "calendar", ok: "check-circle" }[tone];
    var fine = snap.inbox.fine || {};
    var o = { icon: icn, eyebrow: icon("hand-waving") + " " + esc(C.greeting()), age: freshAge(f) };
    if (top.kind === "fine") {
      var hw = h.hardware.length, up = h.hardware.filter(function (c) { return !c.down; }).length;
      o.big = top.headline; o.lede = "Dokkit keeps watching. Nothing needs you right now.";
      o.stats = [[hw ? up + " of " + hw : "–", "machines up", ""], [String(fine.services || 0), "running fine", ""]];
      if (h.snoozedList.length) o.stats.push([String(h.snoozedList.length), "snoozed", ""]);
    } else if (h.needs.length) {
      o.figure = h.needs.length; o.figLabel = h.needs.length === 1 ? "thing needs you" : "things need you";
      o.lede = h.lede.replace(/^[^.]*\.\s*/, "");
      o.stats = [[String(h.soon.length), "coming up", h.soon.length ? "soon" : ""], [String(h.snoozedList.length), "snoozed", ""], [String(fine.services || 0), "running fine", "ok"]];
    } else {
      o.figure = h.soon.length; o.figLabel = h.soon.length === 1 ? "thing coming up" : "things coming up";
      o.lede = "Nothing needs you. Plan for " + (h.soon.length === 1 ? "it" : "them") + " when it suits you.";
      o.stats = [[String(h.snoozedList.length), "snoozed", ""], [String(fine.services || 0), "running fine", "ok"]];
    }
    var fold = top.kind === "fine" ? "Everything is fine" : h.needs.length ? h.needs.length + " need you" : h.soon.length + " coming up";

    var body = '<div class="f-body">' + banner(f);
    var lo = C.leftOut(snap); if (lo) body += '<p class="sub c-left f-rise">' + icon("info") + " " + esc(lo) + "</p>";

    if (top.kind === "attention") {
      var both = h.needs.length && h.soon.length;
      if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";
      var list = issueTab === "needs" ? h.needs : h.soon;
      body += '<section class="c-issues f-issues" aria-label="Issues">' +
        (both ? '<div class="seg f-seg" role="group" aria-label="Show"><span class="f-seg-ink" aria-hidden="true" style="--i:' + (issueTab === "needs" ? 0 : 1) + '"></span><button type="button" data-itab="needs" aria-pressed="' + (issueTab === "needs") + '">Needs you <span class="mono">' + h.needs.length + '</span></button><button type="button" data-itab="soon" aria-pressed="' + (issueTab === "soon") + '">Coming up <span class="mono">' + h.soon.length + "</span></button></div>"
          : '<h2 class="group-h">' + (issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>") +
        '<div class="c-snap f-snap" id="snap" tabindex="0" aria-label="' + esc(issueTab === "needs" ? "Needs you" : "Coming up") + ', swipe for the next one">' +
        list.map(function (i) { return '<div class="c-slide">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>" +
        (list.length > 1 ? '<div class="c-dots"><span class="dots" aria-hidden="true">' + list.map(function (_, n) { return "<i" + (n === 0 ? ' class="on"' : "") + "></i>"; }).join("") + '</span><span class="sub mono" id="pos" aria-live="polite">1 of ' + list.length + "</span></div>" : "") +
        "</section>";
      if (h.snoozed) body += '<p class="c-snoozed sub f-rise">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
      if (h.fineLine) body += '<div class="allgood f-rise">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    } else if (h.snoozed) {
      body += '<p class="c-snoozed sub f-rise">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    }

    var hwd = h.hardware.filter(function (c) { return c.lastDay; });
    if (hwd.length) {
      body += '<section class="panel pad c-day f-rise"><div class="f-sec-h"><h2 class="h2">The last day</h2><span class="sub">Half an hour a block</span></div><div class="c-day-rows">' +
        hwd.map(function (c) { return '<a class="mono" href="#machine/' + esc(c.id) + '">' + esc(c.name) + "</a>" + U.strip(c.id, true); }).join("") + "</div>" +
        '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div><div style="margin-top:10px">' + U.legend() + "</div></section>";
    }
    if (h.hardware.length) body += '<h2 class="group-h f-rise">Machines</h2><div class="panel c-mlist f-rise">' + h.hardware.map(machineRow).join("") + "</div>";
    if (h.groups.length) body += '<h2 class="group-h f-rise">Not on a machine</h2><div class="panel c-mlist f-rise">' + h.groups.map(machineRow).join("") + "</div>";
    body += "</div>";
    return { tone: tone, fold: fold, body: hero(o) + body };
  }

  // ---------- service ----------
  var PHRASE = { down: "It is down", degraded: "Working, but not as it should", ok: "Running fine", quiet: "No signal yet", soon: "Coming up" };
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot;
    var f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", fold: "Service", body: hero({ small: true, icon: "hourglass-medium", big: "No snapshot yet", lede: NO_SNAP }) + '<div class="f-body">' + (f ? banner(f) : "") + "</div>" };
    var v = C.service(snap, id);
    if (!v) return { tone: "quiet", fold: "Service", body: hero({ small: true, icon: "info", big: "Not in this snapshot", lede: "The newest snapshot no longer lists this service." }) };
    var tone = v.level.tone;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var top = hero({
      small: true, icon: v.level.icon,
      eyebrow: U.tag(tone, v.level.word) + ' <span class="mono f-eyename">' + esc(v.name) + "</span>" + (v.machine ? ' <span class="f-on">on</span> <a class="mono c-mlink" href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : ""),
      big: PHRASE[tone] || v.level.word, lede: v.note, extra: line ? '<p class="sub mono c-kind">' + esc(line) + "</p>" : "", age: freshAge(f)
    });
    var b = '<div class="f-body">' + banner(f);
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub c-left f-rise">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var nm = C.names(snap)[i.service];
      var meta = [nm, i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += '<section class="panel c-sec f-rise"><div class="panel-head"><span class="h2">Open issue</span><span class="sub mono">' + esc(i.short_id) + "</span></div>" +
        '<div class="c-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + '</p><h3>' + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="meta mono">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="c-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="c-time">' + v.history.slice().reverse().map(function (e, n) {
          return '<li><span class="dot ' + (n === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub mono">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : "") + "</section>";
    }
    if (v.checks.length) {
      b += '<section class="panel c-sec f-rise"><div class="panel-head"><span class="h2">Checks</span><span class="sub mono">' + v.checks.length + "</span></div>" +
        v.checks.map(function (c) {
          return '<div class="c-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div><p class="mono c-cname">' + esc(c.name) + '</p><p class="c-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</p>" +
            (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>";
        }).join("") + "</section>";
    }
    if (v.job.length) {
      var run = v.jobRaw && v.jobRaw.last_run;
      b += '<section class="panel c-sec f-rise"><div class="panel-head"><span class="h2">Job</span></div><dl class="c-dl">' +
        v.job.map(function (j) { return "<dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd>"; }).join("") + "</dl>" +
        (run && run.result === "running" && run.total ? '<div class="c-prog"><div class="meter" role="progressbar" aria-valuenow="' + run.done + '" aria-valuemax="' + run.total + '"><b class="run" style="width:' + Math.round(run.done / run.total * 100) + '%"></b></div></div>' : "") + "</section>";
    }
    if (v.chart.some(function (x) { return x != null; })) {
      var pres = v.chart.filter(function (x) { return x != null; }), last = pres[pres.length - 1];
      b += '<section class="panel pad c-sec f-rise"><div class="f-sec-h"><span class="h2">Last 24 hours</span>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" +
        '<p class="f-chartfig">' + esc(String(Math.round(last))) + '<small>now</small></p>' + U.chart(v.chart, v.metric) +
        '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></section>';
    }
    if (v.logs.length) b += '<section class="panel c-sec f-rise"><div class="panel-head"><span class="h2">Last log lines</span><span class="sub mono">' + v.logs.length + '</span></div><div class="c-logs">' + U.logLines(v.logs) + "</div></section>";
    b += "</div>";
    return { tone: tone, fold: v.name, body: top + b };
  }

  // ---------- machine ----------
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot;
    var f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", fold: "Machine", body: hero({ small: true, icon: "hourglass-medium", big: "No snapshot yet", lede: NO_SNAP }) + '<div class="f-body">' + (f ? banner(f) : "") + "</div>" };
    var m = C.machineById(snap, id);
    if (!m) return { tone: "quiet", fold: "Machine", body: hero({ small: true, icon: "info", big: "Not in this snapshot", lede: "The newest snapshot no longer lists this machine." }) };
    var c = C.card(m), tone = c.planned ? "quiet" : c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var big = c.planned ? "Resting, as planned" : c.down ? "Stopped reporting" : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look" : "All good";
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it." : c.down ? "It has stopped reporting." : c.counts.charAt(0).toUpperCase() + c.counts.slice(1) + ".";
    var top = hero({
      small: true, icon: c.planned ? "moon" : tone === "ok" ? "check-circle" : tone === "down" ? "warning-octagon" : "hourglass-medium",
      eyebrow: (c.word ? U.tag(tone, c.word) : "") + ' <span class="mono f-eyename">' + esc(c.name) + "</span>" + (m.os ? ' <span class="f-on">' + esc(m.os) + "</span>" : ""),
      big: big, lede: lede, extra: c.status ? '<p class="sub mono c-kind">' + esc(c.status) + "</p>" : "",
      stats: c.meters.map(function (x) { return [x.percent + "%", x.label + (x.subject ? " " + x.subject : ""), x.hot ? "degraded" : "", x.percent]; }), age: freshAge(f)
    });
    var b = '<div class="f-body">' + banner(f);
    if (!c.meters.length && c.hardware) b += '<p class="sub c-line f-rise">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += '<section class="panel pad c-sec f-rise"><div class="f-sec-h"><span class="h2">The last day</span><span class="sub">Half an hour a block</span></div>' + U.strip(c.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div style="margin-top:10px">' + U.legend() + "</div></section>";
    if (mine.length) b += '<h2 class="group-h f-rise">Needs a look</h2><div class="stack">' + mine.map(function (i) { return '<div class="f-rise">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>";
    b += '<h2 class="group-h f-rise">Services</h2><div class="panel c-svcs pad-s f-rise">' + services(c) + "</div></div>";
    return { tone: tone, fold: c.name, body: top + b };
  }

  // ---------- servers, settings, add, lock, first run: the same hero language ----------
  function serversPage() {
    var n = C.servers().length;
    return { tone: "brand", fold: "Servers", body: hero({ icon: "hard-drives", eyebrow: "On this phone", figure: n, figLabel: n === 1 ? "server paired" : "servers paired",
      lede: n ? "Tap one to show it. Removing one deletes its key, token and snapshot from this phone; nothing changes on the server." : "Pair one from the Dokkit web interface: Settings, Phones, Add a phone." }) +
      '<div class="f-body"><div class="f-rise stack">' + U.serversList() + "</div></div>" };
  }
  function settingsPage() {
    var changed = C.SETTINGS.filter(function (s) { return C.isChanged(s.key); }).length;
    return { tone: "brand", fold: "Settings", body: hero({ icon: "sliders-horizontal", eyebrow: "This phone", big: "Your defaults", lede: "Each one starts at today's value. Change it here; Reset puts it back.",
      stats: [[String(C.SETTINGS.length), "settings", ""], [String(changed), "changed", changed ? "brand" : ""]] }) +
      '<div class="f-body"><div class="f-rise stack">' + U.settingsGroups() + "</div>" + '<div class="f-rise">' + U.about() + "</div></div>" };
  }
  function addPage(mode) {
    return { tone: "brand", fold: "Add a server", body: hero({ small: true, icon: "qr-code", eyebrow: "Pair this phone", big: mode === "paste" ? "Paste the code" : "Scan the code" }) +
      '<div class="f-body f-add f-rise">' + U.addServer(mode) + "</div>" };
  }
  function full(inner, tone) { return '<div class="f-page f-full" data-tone="' + tone + '">' + flow() + '<div class="f-full-in">' + inner + "</div></div>"; }

  // ---------- render ----------
  var lastRoute = null;
  function render(keep) {
    var r = route(), app = document.getElementById("app"), out, page = null, tone = "brand";
    if (r.name === "lock") out = U.phone({ body: full(U.lockScreen(), "brand") });
    else if (r.name === "first" || (r.name === "home" && !C.servers().length)) out = U.phone({ body: full(U.firstRun(), "brand") });
    else {
      var title = { service: "Service", machine: "Machine", servers: "Servers", settings: "Settings", add: "Add a server" }[r.name] || "Home";
      page = r.name === "service" ? service(r.id) : r.name === "machine" ? machine(r.id) : r.name === "servers" ? serversPage() : r.name === "settings" ? settingsPage() : r.name === "add" ? addPage(r.id) : home();
      tone = page.tone || "brand";
      var data = r.name === "home" || r.name === "service" || r.name === "machine";
      var tabs = r.name === "add" ? "" : nav(r.name === "home" || r.name === "servers" || r.name === "settings" ? r.name : "");
      out = U.phone({
        top: topbar(title, page.fold, { back: r.name === "service" || r.name === "machine" || r.name === "add", backIcon: r.name === "add" ? "x" : null, backLabel: r.name === "add" ? "Cancel" : null, tools: data, server: data }),
        body: (data ? ptr() : "") + '<div class="f-page' + (keep ? "" : " f-arrive") + '">' + flow() + page.body + "</div>",
        bottom: tabs
      });
    }
    app.innerHTML = out;
    var ph = app.querySelector(".phone");
    ph.dataset.tone = tone;
    if (r.name !== "lock" && r.name !== "first" && !(r.name === "home" && !C.servers().length)) ph.classList.add("f-has-bar");
    after(r, keep);
    lastRoute = r.name + "/" + r.id;
  }

  function after(r, keep) {
    U.wire(function (k) { render(k); });
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = function () { if (history.length > 1) history.back(); else location.hash = "#home"; }; });
    document.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { b.classList.add("f-turn"); setTimeout(function () { b.classList.remove("f-turn"); }, 700); spin(true); U.fakeRefresh(function () { spin(false); }); }; });
    document.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = function () { picker(b); }; });
    document.querySelectorAll("[data-machine]").forEach(function (b) { b.onclick = function () { openMachines[b.dataset.machine] = !openMachines[b.dataset.machine]; keepScroll(); }; });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; keepScroll(); }; });
    document.querySelectorAll("[data-itab]").forEach(function (b) {
      b.onclick = function () {
        if (b.dataset.itab === issueTab) return;
        issueTab = b.dataset.itab;
        var ink = document.querySelector(".f-seg-ink"), row = document.getElementById("snap");
        if (C.reduced || !ink) return keepScroll();
        ink.style.setProperty("--i", issueTab === "needs" ? 0 : 1);
        if (row) row.classList.add("f-leave");
        setTimeout(function () { keepScroll(); var r2 = document.getElementById("snap"); if (r2) r2.classList.add("f-enter"); }, 220);
      };
    });
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
    fold();
    countUp(r);
    pullToRefresh();
  }
  function keepScroll() { var s = document.getElementById("screen"), y = s ? s.scrollTop : 0; render(true); var t = document.getElementById("screen"); if (t) { t.scrollTop = y; fallbackFold(t); } }

  // Where scroll-driven animations are missing, the scroll position is handed to CSS as --y.
  function fallbackFold(sc) { var ph = sc.closest(".phone"); if (ph) ph.style.setProperty("--y", Math.min(400, sc.scrollTop)); }
  function fold() {
    var sc = document.getElementById("screen");
    if (!sc || scrollDriven || C.reduced) return;
    document.documentElement.classList.add("f-nosd");
    var queued = false;
    sc.addEventListener("scroll", function () {
      if (queued) return; queued = true;
      requestAnimationFrame(function () { queued = false; fallbackFold(sc); });
    }, { passive: true });
    fallbackFold(sc);
  }

  // The big figure counts up once, the first time a page shows it.
  function countUp(r) {
    var el = document.querySelector(".f-num[data-count]");
    if (!el || C.reduced) return;
    var key = r.name + (C.selected() ? C.selected().id : "") + el.dataset.count;
    if (counted[key]) return;
    counted[key] = true;
    var to = +el.dataset.count, t0 = performance.now(), d = 700;
    el.textContent = "0";
    (function step(t) {
      var k = Math.min(1, (t - t0) / d), e = 1 - Math.pow(1 - k, 3);
      el.textContent = Math.round(to * e);
      if (k < 1) requestAnimationFrame(step);
    })(t0);
  }

  // The server menu flies out of the button that opened it.
  function picker(btn) {
    var cur = C.selected(), ph = document.querySelector(".phone"), layer = document.getElementById("layer");
    var a = btn.getBoundingClientRect(), p = ph.getBoundingClientRect();
    var right = p.right - a.right + 4, top = a.bottom - p.top + 6;
    layer.innerHTML = '<div class="f-scrim" data-fclose></div><div class="f-pop" role="menu" aria-label="Show a server" style="top:' + top + "px;right:" + right + 'px">' +
      '<p class="f-pop-h">Show a server</p>' +
      C.servers().map(function (s) {
        var on = cur && s.id === cur.id, fr = C.freshness(s.state);
        return '<button class="f-pick" type="button" role="menuitemradio" aria-checked="' + !!on + '" data-pick="' + esc(s.id) + '"><span class="pip ' + (fr.warn ? "degraded" : "") + '" aria-hidden="true"></span><span class="f-pick-t"><span class="srv-name">' + esc(s.name) + '</span><span class="sub">' + esc(fr.text) + "</span></span>" + (on ? icon("check") : "") + "</button>";
      }).join("") + '<a class="f-pick f-pick-link" role="menuitem" href="#servers">' + icon("hard-drives") + "<span>Manage servers</span></a></div>";
    var pop = layer.querySelector(".f-pop");
    requestAnimationFrame(function () { pop.classList.add("show"); });
    function close(after) { pop.classList.remove("show"); pop.classList.add("hide"); setTimeout(function () { layer.innerHTML = ""; if (after) after(); }, C.reduced ? 0 : 200); }
    layer.querySelector("[data-fclose]").onclick = function () { close(); };
    layer.querySelectorAll("[data-pick]").forEach(function (b) { b.onclick = function () { C.select(b.dataset.pick); close(function () { render(); U.toast("Showing " + C.selected().name + "."); }); }; });
    layer.querySelector(".f-pick-link").onclick = function () { layer.innerHTML = ""; };
    var first = layer.querySelector("[aria-checked=true]") || layer.querySelector(".f-pick"); if (first) first.focus({ preventScroll: true });
    document.addEventListener("keydown", function esc(e) { if (e.key === "Escape") { close(); document.removeEventListener("keydown", esc); } });
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
