// Direction I, Ribbon: the hero's light runs down the whole page; sections rise in; the tab bar floats.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var openMachines = {}, openMore = {}, openSecs = {}, issueTab = null;
  var lastRoute = null, thumbs = {};
  var SDA = window.CSS && CSS.supports && CSS.supports("animation-timeline: scroll()");
  if (!SDA) document.documentElement.classList.add("no-sda");

  function route() {
    var h = location.hash || U.startRoute();
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/") };
  }

  // ---------- chrome ----------
  function ribbon() {
    return '<div class="i-ribbon" aria-hidden="true"><svg viewBox="0 0 400 300" preserveAspectRatio="none">' +
      '<path class="band-a" d="M-40 190 C 60 60, 170 250, 270 120 S 420 40, 460 90"/>' +
      '<path class="band-b" d="M-40 90 C 80 170, 190 10, 300 110 S 420 200, 460 150"/></svg></div>';
  }
  function nav(current) {
    var tabs = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="i-nav" aria-label="Main" data-thumb="nav"><span class="i-thumb" aria-hidden="true"></span>' + tabs.map(function (t) {
      var on = t[0] === current;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + ">" + icon(t[2]) + '<span class="lbl">' + t[1] + "</span></a>";
    }).join("") + "</nav>";
  }
  function topbar(title, opts) {
    opts = opts || {};
    var s = C.selected(), many = C.servers().length > 1;
    return '<header class="i-top">' +
      (opts.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (opts.backLabel || "Back") + '">' + icon(opts.backIcon || "arrow-left") + "</button>" : '<span class="i-top-gap"></span>') +
      '<div class="i-top-t"><h1' + (opts.dup ? ' class="dup"' : "") + ">" + esc(title) + "</h1>" + (opts.server !== false && s ? '<p class="sub">' + esc(s.name) + "</p>" : "") + "</div>" +
      (opts.tools ? (many ? '<button class="iconbtn" type="button" data-picker aria-label="Switch server" aria-haspopup="dialog">' + icon("swap") + "</button>" : "") +
        '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function ptr() { return '<div class="i-ptr" id="ptr" aria-hidden="true"><span class="i-ptr-dot">' + icon("arrows-clockwise") + "</span></div>"; }

  // ---------- small parts ----------
  function ring(fraction, label, iconName) {
    var r = 50, c = +(2 * Math.PI * r).toFixed(1), pct = Math.round(fraction * 100);
    var inner = iconName ? '<span class="ic">' + icon(iconName) + "</span>" : "<b data-count=\"" + pct + '">' + pct + "%</b><span>" + esc(label) + "</span>";
    return '<figure class="i-ring" role="img" aria-label="' + (iconName ? esc(label) : pct + " percent " + esc(label)) + '"><svg viewBox="0 0 112 112"><circle class="track" cx="56" cy="56" r="' + r + '"/>' +
      (iconName ? "" : '<circle class="fill" cx="56" cy="56" r="' + r + '" style="--c:' + c + ";stroke-dasharray:" + c + ";stroke-dashoffset:" + (c * (1 - fraction)).toFixed(1) + '"/>') +
      "</svg><figcaption>" + inner + "</figcaption></figure>";
  }
  function fineShare(snap) {
    var total = 0, fine = 0;
    snap.machines.forEach(function (m) { m.services.forEach(function (s) {
      if (s.environment && s.environment !== "production") return;
      if (s.state === "unwatched" || s.state === "unknown" || !s.state) return;
      total++; if (s.state === "ok") fine++;
    }); });
    return { total: total, fine: fine, fraction: total ? fine / total : 1 };
  }
  function age(f) {
    if (f.warn || f.detail) return "";
    return '<p class="i-age"><span class="live" aria-hidden="true"></span>' + esc(f.text) + "</p>";
  }
  function notice(tone, ic, title, text) {
    return '<div class="i-glass i-pad i-notice i-rise">' + U.ic(tone, ic) + '<div><p class="h2">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div></div>";
  }
  function issueCard(i, snap) {
    var st = C.issueState(i), lv = st === "soon" ? C.LEVEL.soon : st === "snoozed" ? C.LEVEL.snoozed : C.level(st);
    var fl = C.flags(i);
    var when = st === "soon" ? "Coming up" : lv.word + " · open " + C.ago(i.since).replace(" ago", "");
    return '<article class="i-card k-' + lv.tone + '"><div class="i-card-top"><span class="ic" aria-hidden="true">' + icon(lv.icon) + "</span>" + esc(when) + "</div>" +
      "<h3>" + esc(i.title) + '</h3><p class="say">' + esc(C.sentence(i, snap)) + "</p>" +
      (fl.length ? '<div class="flags">' + fl.map(function (f) { return U.tag(f.tone, f.text); }).join("") + "</div>" : "") +
      '<div class="i-foot"><span class="i-meta">' + esc([i.machine, i.short_id, i.count > 1 ? i.count + " times" : null].filter(Boolean).join(" · ")) + "</span>" +
      '<a class="i-go" href="#service/' + esc(i.service) + '">' + esc(C.nextStep(i)) + '<span class="arr" aria-hidden="true">' + icon("arrow-right") + "</span></a></div></article>";
  }
  function pipTone(mark) { return mark === "down" ? "down" : mark === "degraded" ? "degraded" : ""; }
  function svcRow(r) {
    return '<a class="i-svc" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id], out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub i-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="i-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub i-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function fold(open, inner) { return '<div class="i-fold"' + (open ? "" : " inert") + "><div>" + inner + "</div></div>"; }
  function machineRow(c) {
    var open = !!openMachines[c.id];
    return '<section class="i-mrow' + (open ? " open" : "") + '">' +
      '<button class="i-mhead" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      (c.hardware ? '<span class="pip ' + pipTone(c.mark) + '" aria-hidden="true"></span>' : '<span class="i-gicon" aria-hidden="true">' + icon("cloud") + "</span>") +
      '<span class="i-mtext"><span class="i-mname">' + esc(c.name) + "</span>" +
      (c.status ? '<span class="sub' + (c.down ? " i-down" : "") + '">' + esc(c.status) + "</span>" : "") +
      '<span class="sub">' + esc(c.counts) + "</span></span>" + '<span class="i-chev" aria-hidden="true">' + icon("caret-down") + "</span></button>" +
      fold(open, '<div class="i-mbody">' +
        (c.meters.length ? '<div class="i-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
        (c.notice ? '<p class="i-mnote t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
        '<div class="i-svcs">' + services(c) + "</div>" +
        (c.hardware ? '<a class="btn soft block" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") + "</div>") +
      "</section>";
  }
  function section(key, ic, tone, title, summary, inner, openByDefault) {
    var open = openSecs[key] !== undefined ? openSecs[key] : !!openByDefault;
    return '<section class="i-glass i-sec i-rise' + (open ? " open" : "") + '"><button class="i-sech" type="button" data-sec="' + key + '" aria-expanded="' + open + '">' +
      U.ic(tone, ic) + '<span class="t"><span class="h">' + esc(title) + "</span>" + (summary ? '<span class="s">' + esc(summary) + "</span>" : "") + "</span>" +
      '<span class="i-chev" aria-hidden="true">' + icon("caret-down") + "</span></button>" + fold(open, '<div class="i-secb">' + inner + "</div>") + "</section>";
  }
  function heroBlock(o) {
    return '<div class="i-hero' + (o.sm ? " sm" : "") + ' settle">' + (o.eye ? '<p class="i-eye">' + o.eye + "</p>" : "") + o.inner + (o.lede ? '<p class="i-lede">' + esc(o.lede) + "</p>" : "") + (o.after || "") + "</div>";
  }

  // ---------- home ----------
  var NOSNAP = "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.";
  function home() {
    var s = C.selected();
    if (!s) return { full: U.firstRun(), tone: "brand" };
    var st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) {
      return { tone: "quiet", body: heroBlock({ eye: icon("hand-waving") + " " + esc(C.greeting()),
        inner: '<div class="i-figrow"><div class="i-fig"><h2 class="i-big">No snapshot yet</h2></div>' + ring(0, "Waiting for the first snapshot", "hourglass-medium") + "</div>", lede: NOSNAP }) +
        '<div class="i-body">' + (f.detail ? '<div class="i-rise">' + U.ageBanner(f) + "</div>" : "") + "</div>" };
    }
    var h = C.home(snap), top = h.top, share = fineShare(snap);
    var tone = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var n = top.kind === "fine" ? share.fine : h.needs.length ? h.needs.length : h.soon.length;
    var unit = top.kind === "fine" ? (share.fine === 1 ? "thing running, all fine" : "things running, all fine")
      : h.needs.length ? (h.needs.length === 1 ? "thing needs you" : "things need you")
      : (h.soon.length === 1 ? "thing is coming up" : "things are coming up");
    var lede = top.kind === "fine" ? (top.detail.indexOf(" · ") > 0 ? top.detail.split(" · ")[0] + ". Dokkit keeps watching." : "Dokkit keeps watching.")
      : h.needs.length ? h.lede.replace(/^[^.]*\.\s*/, "")
      : "Nothing needs you. Plan for " + (h.soon.length === 1 ? "it" : "them") + " when it suits you.";
    var hero = heroBlock({ eye: icon("hand-waving") + " " + esc(C.greeting()),
      inner: '<div class="i-figrow"><div class="i-fig"><span class="i-num" data-count="' + n + '">' + n + '</span><span class="i-unit">' + esc(unit) + "</span></div>" + ring(share.fraction, "fine") + "</div>",
      lede: lede, after: age(f) });

    var b = '<div class="i-body">';
    if (f.warn || f.detail) b += '<div class="i-rise">' + U.ageBanner(f) + "</div>";
    var lo = C.leftOut(snap); if (lo) b += '<p class="i-note">' + icon("info") + " " + esc(lo) + "</p>";

    if (top.kind === "attention") {
      var both = h.needs.length && h.soon.length;
      if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";
      var list = issueTab === "needs" ? h.needs : h.soon;
      b += '<section class="i-issues" aria-label="Issues">' +
        (both ? '<div class="i-seg" role="group" aria-label="Show" data-thumb="seg"><span class="i-thumb" aria-hidden="true"></span><button type="button" data-itab="needs" aria-pressed="' + (issueTab === "needs") + '">Needs you <span class="mono">' + h.needs.length +
          '</span></button><button type="button" data-itab="soon" aria-pressed="' + (issueTab === "soon") + '">Coming up <span class="mono">' + h.soon.length + "</span></button></div>"
          : '<h2 class="i-h">' + (issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>") +
        '<div class="i-snap" id="snap" tabindex="0" aria-label="' + esc(issueTab === "needs" ? "Needs you" : "Coming up") + ', swipe for the next one">' +
        list.map(function (i) { return '<div class="i-slide">' + issueCard(i, snap) + "</div>"; }).join("") + "</div>" +
        (list.length > 1 ? '<div class="i-dots"><span class="dots" aria-hidden="true">' + list.map(function (_, k) { return "<i" + (k === 0 ? ' class="on"' : "") + "></i>"; }).join("") + '</span><span class="sub" id="pos" aria-live="polite">1 of ' + list.length + "</span></div>" : "") +
        "</section>";
      if (h.snoozed) b += '<p class="i-note">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
      if (h.fineLine) b += '<div class="allgood i-rise">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
    } else if (h.snoozed) {
      b += '<p class="i-note">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    }

    var hw = h.hardware.filter(function (c) { return c.lastDay; });
    if (hw.length) {
      b += '<section class="i-glass i-pad i-rise"><h2 class="h2" style="font-size:19px">The last day</h2><p class="i-sub">Each block is half an hour. Now is on the right.</p><div class="i-day-rows">' +
        hw.map(function (c) { return '<a href="#machine/' + esc(c.id) + '">' + esc(c.name) + (c.down ? "<span>down</span>" : c.inTrouble ? "<span>needs a look</span>" : "") + "</a>" + U.strip(c.id, true); }).join("") + "</div>" + U.legend() + "</section>";
    }
    if (h.hardware.length) b += '<h2 class="i-h">Machines <span class="n">' + h.hardware.length + '</span></h2><div class="i-glass i-mlist i-rise">' + h.hardware.map(machineRow).join("") + "</div>";
    if (h.groups.length) b += '<h2 class="i-h">Not on a machine <span class="n">' + h.groups.length + '</span></h2><div class="i-glass i-mlist i-rise">' + h.groups.map(machineRow).join("") + "</div>";
    b += "</div>";
    return { tone: tone, body: hero + b };
  }

  // ---------- service ----------
  function lastValue(values) { for (var k = values.length - 1; k >= 0; k--) if (values[k] != null) return values[k]; return null; }
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", body: '<div class="i-body" style="padding-top:12px">' + (f ? U.ageBanner(f) : "") + notice("quiet", "hourglass-medium", "No snapshot yet", NOSNAP) + "</div>" };
    var v = C.service(snap, id);
    if (!v) return { tone: "quiet", body: '<div class="i-body" style="padding-top:12px">' + notice("quiet", "info", "Not in this snapshot", "The newest snapshot no longer lists this service.") + "</div>" };
    var tone = v.level.tone;
    var headline = tone === "down" ? "Something is wrong" : tone === "degraded" ? "Working, but slow" : tone === "ok" ? "All good" : v.level.word;
    var line = [v.kind, v.version ? "version " + v.version : null, v.environment].filter(Boolean).join(" · ");
    var latest = lastValue(v.chart), fine = v.checks.filter(function (c) { return c.state === "ok"; }).length;
    var figure = latest != null ? '<span class="i-num" style="font-size:64px">' + Math.round(latest).toLocaleString() + '</span><span class="i-unit" style="font-size:16px;color:var(--muted)">' + esc(v.metric || "latest") + ", latest</span>"
      : v.checks.length ? '<span class="i-num" style="font-size:64px">' + fine + "<small>of " + v.checks.length + '</small></span><span class="i-unit" style="font-size:16px;color:var(--muted)">checks fine</span>' : "";
    var hero = heroBlock({ sm: true,
      eye: U.tag(tone, v.level.word) + (v.machine ? ' <a href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : ""),
      inner: '<h2 class="i-big">' + esc(headline) + '</h2><p class="i-name">' + esc(v.name) + "</p>" + (figure ? '<div class="i-fig" style="margin-top:18px">' + figure + "</div>" : ""),
      lede: v.note, after: (line ? '<p class="i-kind">' + esc(line) + "</p>" : "") + age(f) });
    var b = '<div class="i-body">' + (f.warn || f.detail ? '<div class="i-rise">' + U.ageBanner(f) + "</div>" : "");
    var lo = C.leftOut(snap); if (lo) b += '<p class="i-note">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var meta = [C.names(snap)[i.service], i.machine, "Open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += section("issue", lv.icon, lv.tone, "Open issue", i.short_id + " · " + i.title,
        '<div class="i-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + "</p><h3>" + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="i-meta">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="c-flags" style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="i-time">' + v.history.slice().reverse().map(function (e, k) {
          return '<li><span class="dot ' + (k === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : ""), true);
    }
    if (v.checks.length) {
      var bad = v.checks.length - fine;
      b += section("checks", "pulse", bad ? "degraded" : "ok", "Checks", fine + " of " + v.checks.length + " fine",
        v.checks.map(function (c) {
          return '<div class="i-check">' + U.ic(c.level.tone, c.level.icon) + '<div><p class="i-cname">' + esc(c.name) + '</p><p class="i-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</p>" +
            (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + "</div></div>";
        }).join(""), true);
    }
    if (v.job.length) {
      var run = v.jobRaw && v.jobRaw.last_run, lastRun = (v.job.find(function (j) { return j[0] === "Last run"; }) || [])[1];
      b += section("job", "clock", "brand", "Job", lastRun ? "Last run: " + lastRun : null,
        '<dl class="i-dl">' + v.job.map(function (j) { return "<dt>" + esc(j[0]) + "</dt><dd>" + esc(j[1]) + "</dd>"; }).join("") + "</dl>" +
        (run && run.result === "running" && run.total ? '<div class="i-prog"><div class="meter" role="progressbar" aria-valuenow="' + run.done + '" aria-valuemax="' + run.total + '"><b class="run" style="width:' + Math.round(run.done / run.total * 100) + '%"></b></div></div>' : ""), !v.issue);
    }
    if (v.chart.some(function (x) { return x != null; })) {
      b += section("chart", "chart-line", "brand", "Last 24 hours", (v.metric ? v.metric + ", " : "") + "latest " + Math.round(latest).toLocaleString(),
        U.chart(v.chart, v.metric) + '<div class="strip-axis i-axis"><span>24 h ago</span><span>Now</span></div>', false);
    }
    if (v.logs.length) {
      var errs = v.logs.filter(function (l) { return l.error; }).length;
      b += section("logs", "scroll", errs ? "down" : "quiet", "Last log lines", C.plural(v.logs.length, "line", "lines") + (errs ? ", " + C.plural(errs, "error", "errors") : ""), U.logLines(v.logs), false);
    }
    b += "</div>";
    return { tone: tone, body: hero + b };
  }

  // ---------- machine ----------
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", body: '<div class="i-body" style="padding-top:12px">' + (f ? U.ageBanner(f) : "") + notice("quiet", "hourglass-medium", "No snapshot yet", NOSNAP) + "</div>" };
    var m = C.machineById(snap, id);
    if (!m) return { tone: "quiet", body: '<div class="i-body" style="padding-top:12px">' + notice("quiet", "info", "Not in this snapshot", "The newest snapshot no longer lists this machine.") + "</div>" };
    var c = C.card(m), tone = c.planned ? "quiet" : c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok";
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var headline = c.planned ? "Resting, as planned" : c.down ? "Stopped reporting" : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look" : "All good";
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it." : c.down ? "It has stopped reporting." : c.counts + ".";
    var watched = c.trouble.length + c.fine.length + c.moreFine.length;
    var hero = heroBlock({ sm: true, eye: (c.word ? U.tag(tone, c.word) : "") + (m.os ? " " + esc(m.os) : ""),
      inner: '<div class="i-figrow"><div class="i-fig"><h2 class="i-big">' + esc(headline) + '</h2><p class="i-name">' + esc(c.name) + "</p></div>" +
        (watched ? ring((c.fine.length + c.moreFine.length) / watched, "fine") : "") + "</div>",
      lede: lede, after: (c.status ? '<p class="i-kind">' + esc(c.status) + "</p>" : "") + age(f) });
    var b = '<div class="i-body">' + (f.warn || f.detail ? '<div class="i-rise">' + U.ageBanner(f) + "</div>" : "");
    if (c.meters.length) b += '<section class="i-glass i-pad i-vitals i-rise">' + c.meters.map(U.meter).join("") + "</section>";
    else if (c.hardware) b += '<p class="i-note">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += '<section class="i-glass i-pad i-rise"><h2 class="h2" style="font-size:19px">The last day</h2><p class="i-sub" style="margin-bottom:14px">Each block is half an hour.</p>' + U.strip(c.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div style="margin-top:12px">' + U.legend() + "</div></section>";
    if (mine.length) b += '<h2 class="i-h">Needs a look <span class="n">' + mine.length + '</span></h2><div class="stack">' + mine.map(function (i) { return '<div class="i-rise">' + issueCard(i, snap) + "</div>"; }).join("") + "</div>";
    b += '<h2 class="i-h">Services</h2><div class="i-glass i-pad i-svcs i-rise" style="padding:10px">' + services(c) + "</div></div>";
    return { tone: tone, body: hero + b };
  }

  // ---------- pages that carry the brand light ----------
  function plainHero(title, lede) { return heroBlock({ sm: true, inner: '<h2 class="i-big">' + esc(title) + "</h2>", lede: lede }); }
  function serversPage() {
    var list = C.servers(), cur = C.selected();
    var lede = !list.length ? "Nothing is paired yet. Add a server with the code from its web interface."
      : list.length === 1 ? "One server is paired. This phone shows " + list[0].name + "."
      : list.length + " servers are paired. This phone shows " + cur.name + ".";
    return plainHero("Servers", lede) + '<div class="i-body"><div class="pad-screen i-rise">' + U.serversList() + "</div></div>";
  }
  function settingsPage() {
    return plainHero("Settings", "What the app decides on its own. Each starts at today's value and can go back to it.") +
      '<div class="i-body"><div class="pad-screen">' + U.settingsGroups() + U.about() + "</div></div>";
  }

  // ---------- render ----------
  function render() {
    var r = route(), key = r.name + "/" + r.id, still = key === lastRoute;
    lastRoute = key;
    var app = document.getElementById("app"), out, tone = "brand";
    if (r.name === "lock") out = U.phone({ top: ribbon(), body: U.lockScreen() });
    else if (r.name === "first") out = U.phone({ top: ribbon(), body: U.firstRun() });
    else if (r.name === "add") out = U.phone({ top: ribbon() + topbar("Add a server", { back: true, backIcon: "x", backLabel: "Cancel", server: false, dup: true }), body: plainHero("Add a server") + '<div class="i-body">' + U.addServer(r.id) + "</div>" });
    else if (r.name === "servers") out = U.phone({ top: ribbon() + topbar("Servers", { server: false, dup: true }), body: serversPage(), bottom: nav("servers") });
    else if (r.name === "settings") out = U.phone({ top: ribbon() + topbar("Settings", { server: false, dup: true }), body: settingsPage(), bottom: nav("settings") });
    else {
      var page = r.name === "service" ? service(r.id) : r.name === "machine" ? machine(r.id) : home();
      tone = page.tone || "brand";
      if (page.full) out = U.phone({ top: ribbon(), body: page.full });
      else {
        var title = r.name === "service" ? "Service" : r.name === "machine" ? "Machine" : "Home";
        var noServer = !C.servers().length;
        if (noServer) tone = "quiet";
        out = U.phone({
          top: ribbon() + topbar(title, { back: r.name !== "home", tools: !noServer }),
          body: ptr() + (noServer ? '<div class="i-body" style="padding-top:12px">' + notice("quiet", "device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.") + "</div>" : page.body),
          bottom: nav("home")
        });
      }
    }
    app.innerHTML = out;
    var ph = app.querySelector(".phone");
    ph.dataset.tone = tone;
    ph.classList.toggle("i-still", still);
    after(still);
  }

  function after(still) {
    U.wire(render);
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = function () { if (history.length > 1) history.back(); else location.hash = "#home"; }; });
    document.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { spin(true); U.fakeRefresh(function () { spin(false); }); }; });
    document.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = function () { picker(b); }; });
    document.querySelectorAll("[data-machine]").forEach(function (b) {
      b.onclick = function () { var id = b.dataset.machine; openMachines[id] = !openMachines[id]; toggle(b, openMachines[id]); };
    });
    document.querySelectorAll("[data-sec]").forEach(function (b) {
      b.onclick = function () { var open = b.getAttribute("aria-expanded") !== "true"; openSecs[b.dataset.sec] = open; toggle(b, open); };
    });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; keepScroll(render); }; });
    document.querySelectorAll("[data-itab]").forEach(function (b) { b.onclick = function () { if (issueTab !== b.dataset.itab) { issueTab = b.dataset.itab; keepScroll(render); } }; });
    var snap = document.getElementById("snap");
    if (snap) {
      var dots = document.querySelectorAll(".i-dots .dots i"), pos = document.getElementById("pos"), n = snap.children.length;
      snap.addEventListener("scroll", function () {
        var w = snap.children[0].getBoundingClientRect().width + 12;
        var k = Math.max(0, Math.min(n - 1, Math.round(snap.scrollLeft / w)));
        dots.forEach(function (d, j) { d.classList.toggle("on", j === k); });
        if (pos) pos.textContent = (k + 1) + " of " + n;
      }, { passive: true });
    }
    document.querySelectorAll("[data-thumb]").forEach(placeThumb);
    if (!still) countUp();
    scrolling();
    rise();
    pullToRefresh();
  }

  // A fold opens in place; closed folds are inert so nothing inside them takes focus.
  function toggle(btn, open) {
    var box = btn.parentElement;
    box.classList.toggle("open", open);
    btn.setAttribute("aria-expanded", open);
    var f = box.querySelector(":scope > .i-fold");
    if (f) { if (open) f.removeAttribute("inert"); else f.setAttribute("inert", ""); }
  }

  // The thumb starts where it was last time and slides to the chosen tab.
  function placeThumb(group) {
    var name = group.dataset.thumb, th = group.querySelector(".i-thumb");
    var on = group.querySelector('[aria-current="page"], [aria-pressed="true"]');
    if (!th) return;
    if (!on) { th.style.display = "none"; return; }
    function rect() { return { left: on.offsetLeft, top: on.offsetTop, width: on.offsetWidth, height: on.offsetHeight }; }
    function put(r) { th.style.left = r.left + "px"; th.style.top = r.top + "px"; th.style.width = r.width + "px"; th.style.height = r.height + "px"; }
    var prev = thumbs[name];
    if (prev && !C.reduced) {
      th.style.transition = "none"; put(prev); th.offsetWidth; th.style.transition = "";
      requestAnimationFrame(function () { put(rect()); });
    } else put(rect());
    if (window.ResizeObserver) new ResizeObserver(function () { var r = rect(); thumbs[name] = r; put(r); }).observe(on);
    setTimeout(function () { thumbs[name] = rect(); }, 500);
  }

  function countUp() {
    if (C.reduced) return;
    document.querySelectorAll("[data-count]").forEach(function (el) {
      var to = +el.dataset.count, pct = /%$/.test(el.textContent), t0 = performance.now(), dur = 900;
      (function step(t) {
        var k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
        el.textContent = Math.round(to * e) + (pct ? "%" : "");
        if (k < 1) requestAnimationFrame(step);
      })(t0);
    });
  }

  // Scroll: the light and the top bar follow the page (CSS where it can, this where it cannot); the tab bar tucks in going down.
  function scrolling() {
    var sc = document.getElementById("screen"), ph = document.querySelector(".phone");
    if (!sc || !ph) return;
    var last = 0, timer, ticking = false;
    sc.addEventListener("scroll", function () {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(function () {
        ticking = false;
        var y = sc.scrollTop;
        if (!SDA && !C.reduced) { ph.style.setProperty("--p", Math.min(1, y / 420).toFixed(3)); ph.style.setProperty("--hp", Math.min(1, y / 320).toFixed(3)); }
        if (y > last + 4 && y > 60) ph.classList.add("i-compact");
        else if (y < last - 4) ph.classList.remove("i-compact");
        last = y;
        clearTimeout(timer);
        timer = setTimeout(function () { ph.classList.remove("i-compact"); }, 900);
      });
    }, { passive: true });
  }

  // Where scroll-driven animations are missing, sections still rise in once as they arrive.
  function rise() {
    if (SDA || C.reduced || !window.IntersectionObserver) { document.querySelectorAll(".i-rise").forEach(function (e) { e.classList.add("in"); }); return; }
    var io = new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } }); }, { threshold: .08 });
    document.querySelectorAll(".i-rise").forEach(function (e) { io.observe(e); });
  }

  function keepScroll(fn) { var s = document.getElementById("screen"), y = s ? s.scrollTop : 0; fn(); var t = document.getElementById("screen"); if (t) t.scrollTop = y; }

  // The picker drops out of the top bar as a rounded panel.
  function picker(from) {
    var cur = C.selected(), layer = document.getElementById("layer");
    layer.innerHTML = '<div class="scrim i-light" data-close></div><section class="i-drop" role="dialog" aria-modal="true" aria-label="Show a server"><p class="h">Show a server</p>' +
      C.servers().map(function (s) {
        var on = cur && s.id === cur.id, fr = C.freshness(s.state);
        return '<button class="i-pick" type="button" data-pick="' + esc(s.id) + '"' + (on ? ' aria-current="true"' : "") + '><span><span class="nm">' + esc(s.name) + '</span><span class="sub mono">' + esc(C.host(s.relay)) + '</span><span class="sub">' + esc(fr.text) + "</span></span>" +
          (on ? '<span class="ck" aria-hidden="true">' + icon("check") + "</span>" : "") + "</button>";
      }).join("") + "</section>";
    var top = document.querySelector(".i-top"), drop = layer.querySelector(".i-drop");
    if (top) drop.style.top = (top.offsetTop + top.offsetHeight + 4) + "px";
    requestAnimationFrame(function () { layer.querySelectorAll(".scrim, .i-drop").forEach(function (e) { e.classList.add("show"); }); });
    var first = layer.querySelector("[aria-current]") || layer.querySelector(".i-pick");
    if (first) first.focus({ preventScroll: true });
    layer.querySelectorAll("[data-pick]").forEach(function (b) {
      b.onclick = function () { C.select(b.dataset.pick); U.closeLayer(); lastRoute = null; setTimeout(render, C.reduced ? 0 : 230); };
    });
    function esc_(e) { if (e.key === "Escape") { U.closeLayer(); document.removeEventListener("keydown", esc_); if (from) from.focus(); } }
    document.addEventListener("keydown", esc_);
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
      p.style.removeProperty("--pull"); p.removeAttribute("style"); p.classList.remove("ready");
      if (dy > 70) { spin(true); U.fakeRefresh(function () { spin(false); }); }
      y0 = null; dy = 0;
    }
    sc.addEventListener("touchstart", function (e) { start(e.touches[0].clientY); }, { passive: true });
    sc.addEventListener("touchmove", function (e) { move(e.touches[0].clientY); }, { passive: true });
    sc.addEventListener("touchend", end);
    sc.addEventListener("mousedown", function (e) { if (!e.target.closest("a,button,input,select,textarea,.i-snap")) start(e.clientY); });
    window.onmousemove = function (e) { move(e.clientY); };
    window.onmouseup = end;
  }

  window.addEventListener("hashchange", function () { render(); var s = document.getElementById("screen"); if (s) { s.scrollTop = 0; s.focus({ preventScroll: true }); } });
  render();
})();
