// Direction G, Wallet: the state reads like a balance on a floating card; issues are a deck that fans out.
(function () {
  var C = window.CORE, U = window.UI, esc = C.esc, icon = U.icon;
  var openMachines = {}, openMore = {}, issueTab = null, deckOpen = false, lastRoute = null;
  var WORD = { ok: "Fine", degraded: "Slow", down: "Down", quiet: "No signal", soon: "Soon" };

  function route() {
    var h = location.hash || U.startRoute();
    var parts = h.slice(1).split("/");
    return { name: parts[0] || "home", id: parts.slice(1).join("/") };
  }

  // ---------- chrome ----------
  function nav(current) {
    var tabs = [["home", "Home", "house"], ["servers", "Servers", "hard-drives"], ["settings", "Settings", "gear"]];
    return '<nav class="g-nav" aria-label="Main">' + tabs.map(function (t) {
      var on = t[0] === current;
      return '<a href="#' + t[0] + '"' + (on ? ' aria-current="page"' : "") + '><span class="pill">' + icon(t[2]) + "</span><span>" + t[1] + "</span></a>";
    }).join("") + "</nav>";
  }
  function topbar(title, opts) {
    opts = opts || {};
    var s = C.selected(), many = C.servers().length > 1;
    return '<header class="g-top">' +
      (opts.back ? '<button class="iconbtn" type="button" data-back aria-label="' + (opts.backLabel || "Back") + '">' + icon(opts.backIcon || "arrow-left") + "</button>" : '<span class="g-top-gap"></span>') +
      '<div class="g-top-t"><h1>' + esc(title) + "</h1>" + (opts.server !== false && s ? '<p class="sub">' + esc(s.name) + "</p>" : "") + "</div>" +
      (opts.mini ? '<span class="g-mini" aria-hidden="true">' + esc(opts.mini) + "</span>" : "") +
      (opts.tools ? (many ? '<button class="iconbtn" type="button" data-picker aria-label="Switch server">' + icon("swap") + "</button>" : "") +
        '<button class="iconbtn" type="button" data-refresh aria-label="Refresh">' + icon("arrows-clockwise") + "</button>" : "") +
      "</header>";
  }
  function ptr() { return '<div class="g-ptr" id="ptr" aria-hidden="true"><span class="g-ptr-dot">' + icon("arrows-clockwise") + "</span></div>"; }

  // The balance card every page opens with.
  function card(o) {
    return '<section class="g-card' + (o.hero ? " hero" : "") + (o.small ? " small" : "") + '" aria-label="' + esc(o.label || "Summary") + '">' +
      '<div class="g-card-top">' + (o.eyebrow || "") + (o.icon ? '<span class="ic sm g-cic">' + icon(o.icon) + "</span>" : "") + "</div>" +
      '<p class="g-fig' + (o.figClass ? " " + o.figClass : "") + '"' + (o.count != null ? ' data-count="' + o.count + '"' : "") + ">" + o.fig + "</p>" +
      (o.caption ? '<p class="g-cap">' + o.caption + "</p>" : "") +
      (o.pills && o.pills.length ? '<div class="g-pills">' + o.pills.map(function (p) {
        return (p.href ? '<a class="g-pill" href="' + p.href + '">' : '<span class="g-pill">') + '<b class="' + (p.mono ? "mono" : p.w ? "w" : "") + '">' + esc(p.v) + "</b><span>" + esc(p.k) + "</span>" + (p.href ? "</a>" : "</span>");
      }).join("") + "</div>" : "") +
      (o.foot || "") + "</section>";
  }
  function age(f) { return f && !f.warn && !f.detail ? '<p class="g-age mono">' + icon("clock") + " " + esc(f.text) + "</p>" : ""; }
  function notice(tone, ic, title, text) {
    return '<div class="g-sec g-notice">' + U.ic(tone, ic) + '<div><p class="h2">' + esc(title) + '</p><p class="sub">' + esc(text) + "</p></div></div>";
  }
  var NO_SNAP = "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.";

  // ---------- accounts (machines) ----------
  function svcRow(r) {
    return '<a class="g-svc" href="#service/' + esc(r.id) + '"><span class="pip ' + (r.level.tone === "ok" ? "" : r.level.tone) + '" aria-hidden="true"></span><span class="mono name">' + esc(r.name) + '</span><span class="what t-' + r.level.tone + '">' + esc(r.level.word) + "</span></a>";
  }
  function services(c) {
    var more = openMore[c.id], out = "";
    if (!c.trouble.length && !c.fine.length && !c.moreFine.length && !c.quietLine) out += '<p class="sub g-line">Nothing is watched on it.</p>';
    out += c.trouble.map(svcRow).join("") + c.fine.map(svcRow).join("") + (more ? c.moreFine.map(svcRow).join("") : "");
    if (c.moreFine.length) out += '<button class="g-more" type="button" data-more="' + esc(c.id) + '">' + (more ? "Show fewer" : "and " + c.moreFine.length + " more that are fine") + "</button>";
    if (c.quietLine) out += '<p class="sub g-line">' + icon("circle-dashed") + " " + esc(c.quietLine) + "</p>";
    return out;
  }
  function figure(c) {
    if (c.down) return { v: "Down", k: c.planned ? "planned" : "not reporting" };
    if (c.meters.length) {
      var top = c.meters.slice().sort(function (a, b) { return b.percent - a.percent; })[0];
      return { v: top.percent + "%", k: top.label === "Disk" ? "disk " + (top.subject || "") : top.label.toLowerCase(), hot: top.hot };
    }
    var n = c.fine.length + c.moreFine.length;
    return { v: String(n), k: n === 1 ? "fine" : "fine" };
  }
  function tone(c) { return c.planned ? "quiet" : c.mark === "down" ? "down" : c.mark === "degraded" ? "degraded" : "ok"; }
  function acct(c) {
    var open = !!openMachines[c.id], t = tone(c), fg = figure(c);
    var ic = !c.hardware ? "cloud" : c.planned ? "moon" : t === "down" ? "warning-octagon" : t === "degraded" ? "hourglass-medium" : "check";
    return '<section class="g-acct t-' + t + (open ? " open" : "") + '">' +
      '<button class="g-acct-head" type="button" data-machine="' + esc(c.id) + '" aria-expanded="' + open + '">' +
      U.ic(c.hardware ? t : "quiet", ic, "sm") +
      '<span class="g-acct-t"><span class="g-acct-name mono">' + esc(c.name) + '</span><span class="sub' + (c.down && !c.planned ? " g-down" : "") + '">' + esc(c.status || c.counts) + "</span></span>" +
      '<span class="g-acct-fig"><b class="' + (fg.hot ? "hot" : "") + '">' + esc(fg.v) + '</b><span>' + esc(fg.k) + "</span></span></button>" +
      (c.lastDay ? '<div class="g-acct-line">' + U.strip(c.id, true) + "</div>" : "") +
      '<div class="g-acct-body"><div class="g-acct-inner">' +
        (c.meters.length ? '<div class="g-meters">' + c.meters.map(U.meter).join("") + "</div>" : "") +
        '<p class="sub g-counts">' + esc(c.counts) + "</p>" +
        (c.notice ? '<p class="g-notice-line t-quiet">' + icon("moon") + " " + esc(c.notice) + "</p>" : "") +
        '<div class="g-svcs">' + services(c) + "</div>" +
        (c.hardware ? '<a class="btn soft block" href="#machine/' + esc(c.id) + '">Open ' + esc(c.name) + " " + icon("arrow-right") + "</a>" : "") +
      "</div></div></section>";
  }

  // ---------- home ----------
  function deck(list, snap) {
    var n = list.length;
    return '<div class="g-deck ' + (deckOpen || n < 2 ? "open" : "closed") + '" id="deck" data-n="' + n + '">' +
      list.map(function (i, k) { return '<div class="g-dcard" style="--i:' + k + ';--k:' + Math.min(k, 2) + '" data-href="#service/' + esc(i.service) + '">' + U.issueCard(i, snap, "#service/" + i.service) + "</div>"; }).join("") + "</div>" +
      (n > 1 ? '<button class="g-fan" type="button" id="fan" aria-controls="deck" aria-expanded="' + deckOpen + '">' + (deckOpen ? icon("stack") + " Stack them" : icon("cards") + " See all " + n) + "</button>" : "");
  }
  function home() {
    var s = C.selected();
    if (!s) return { full: true, body: firstRun() };
    var st = s.state, f = C.freshness(st), snap = st.snapshot;
    if (!snap) {
      return { tone: "quiet", mini: "No snapshot", body: '<div class="g-page settle">' + card({ hero: true, label: "No snapshot yet", eyebrow: greet(), icon: "hourglass-medium", fig: "No snapshot yet", figClass: "words", caption: esc(NO_SNAP) }) +
        (f.detail ? U.ageBanner(f) : "") + "</div>" };
    }
    var h = C.home(snap), top = h.top;
    var t = top.kind === "fine" ? "ok" : top.urgent ? (h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded") : "soon";
    var hw = snap.machines.filter(function (m) { return m.kind === "enrolled"; }), up = hw.filter(function (m) { return !m.down; }).length;
    var pills = [
      { v: String(h.soon.length), k: "coming up" },
      { v: String(h.snoozedList.length), k: "snoozed" },
      { v: up + " of " + hw.length, k: "machines up" }
    ];
    var hero;
    if (top.kind === "fine") {
      hero = card({ hero: true, label: "Everything is fine", eyebrow: greet(), icon: "check-circle", fig: "All clear", figClass: "words", caption: esc(top.detail), pills: pills, foot: age(f) });
    } else {
      var n = h.needs.length || h.soon.length;
      var cap = h.needs.length ? (h.needs.length === 1 ? "thing needs you" : "things need you") : (h.soon.length === 1 ? "thing is coming up" : "things are coming up");
      hero = card({ hero: true, label: n + " " + cap, eyebrow: greet(), icon: t === "down" ? "warning-octagon" : t === "soon" ? "calendar" : "hourglass-medium", fig: String(n), count: n, caption: esc(cap), pills: pills, foot: age(f) });
    }

    var b = '<div class="g-page settle">' + hero;
    if (f.warn || f.detail) b += U.ageBanner(f);
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub g-left">' + icon("info") + " " + esc(lo) + "</p>";

    if (top.kind === "attention") {
      if (!issueTab || (issueTab === "needs" && !h.needs.length) || (issueTab === "soon" && !h.soon.length)) issueTab = h.needs.length ? "needs" : "soon";
      var list = issueTab === "needs" ? h.needs : h.soon, both = h.needs.length && h.soon.length;
      b += '<section class="g-issues" aria-label="Issues"><div class="g-sec-h"><h2 class="g-h">' + (both ? "Open issues" : issueTab === "needs" ? "Needs you" : "Coming up") + "</h2>" +
        (both ? '<div class="g-switch" role="group" aria-label="Show"><button type="button" data-itab="needs" aria-pressed="' + (issueTab === "needs") + '">Needs you</button><button type="button" data-itab="soon" aria-pressed="' + (issueTab === "soon") + '">Coming up</button></div>' : "") +
        "</div>" + deck(list, snap) + "</section>";
    }
    if (h.snoozed) b += '<p class="g-snoozed sub">' + icon("moon") + " " + esc(h.snoozed) + "</p>";
    if (top.kind === "attention" && h.fineLine) b += '<div class="allgood g-fine">' + U.ic("ok", "check-circle") + "<div><p>" + esc(h.fineLine) + '</p><p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';

    if (h.hardware.length) {
      b += '<section class="g-accts"><div class="g-sec-h"><h2 class="g-h">Machines</h2><span class="sub">' + up + " of " + hw.length + " up</span></div>" +
        '<p class="sub g-hint">Each line is the last day, half an hour a block. Now is on the right.</p><div class="g-legend">' + U.legend() + "</div>" +
        '<div class="g-list">' + h.hardware.map(acct).join("") + "</div></section>";
    }
    if (h.groups.length) b += '<section class="g-accts"><div class="g-sec-h"><h2 class="g-h">Not on a machine</h2></div><div class="g-list">' + h.groups.map(acct).join("") + "</div></section>";
    b += "</div>";
    var mini = top.kind === "fine" ? "All clear" : h.needs.length ? h.needs.length + " need you" : h.soon.length + " coming up";
    return { tone: t, mini: mini, body: b };
  }
  function greet() { return '<p class="g-eyebrow">' + icon("hand-waving") + " " + esc(C.greeting()) + "</p>"; }

  // ---------- service ----------
  function service(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", body: '<div class="g-page settle">' + card({ label: "No snapshot yet", icon: "hourglass-medium", fig: "No snapshot yet", figClass: "words", caption: esc(NO_SNAP) }) + (f && f.detail ? U.ageBanner(f) : "") + "</div>" };
    var v = C.service(snap, id);
    if (!v) return { tone: "quiet", body: '<div class="g-page settle">' + card({ label: "Not in this snapshot", icon: "info", fig: "Not here", figClass: "words", caption: "The newest snapshot no longer lists this service." }) + "</div>" };
    var t = v.level.tone;
    var pills = [v.kind && { v: v.kind, k: "kind", w: true }, v.version && { v: v.version, k: "version", mono: true }, v.environment && { v: v.environment, k: "where", w: true }].filter(Boolean);
    var hero = card({ label: v.name, eyebrow: '<p class="g-eyebrow mono">' + esc(v.name) + (v.machine ? ' <span class="g-dot">·</span> <a href="#machine/' + esc(v.machine) + '">' + esc(v.machine) + "</a>" : "") + "</p>",
      icon: v.level.icon, fig: esc(WORD[t] || v.level.word), figClass: "words", caption: v.note ? esc(v.note) : "", pills: pills, foot: age(f) });
    var b = '<div class="g-page settle">' + hero + (f.warn || f.detail ? U.ageBanner(f) : "");
    var lo = C.leftOut(snap); if (lo) b += '<p class="sub g-left">' + icon("info") + " " + esc(lo) + "</p>";
    if (v.issue) {
      var i = v.issue, ist = C.issueState(i), lv = ist === "soon" ? C.LEVEL.soon : ist === "snoozed" ? C.LEVEL.snoozed : C.level(i.state);
      var meta = [C.names(snap)[i.service], i.machine, "open since " + C.ago(i.since).replace(" ago", ""), i.count > 1 ? i.count + " times" : null].filter(Boolean);
      var fl = C.flags(i);
      b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Open issue</h2><span class="sub mono">' + esc(i.short_id) + "</span></div>" +
        '<div class="g-issue t-' + lv.tone + '"><p>' + U.tag(lv.tone, lv.word) + "</p><h3>" + esc(i.title) + "</h3>" + (i.note ? '<p class="say">' + esc(i.note) + "</p>" : "") +
        '<p class="meta mono">' + meta.map(esc).join(" · ") + "</p>" + (fl.length ? '<div class="g-flags">' + fl.map(function (x) { return U.tag(x.tone, x.text); }).join("") + "</div>" : "") + "</div>" +
        (v.history.length ? '<ol class="g-time">' + v.history.slice().reverse().map(function (e, n) {
          return '<li><span class="dot ' + (n === 0 ? "t-" + lv.tone : "t-quiet") + '" aria-hidden="true"></span><div><p>' + esc(e.text) + '</p><p class="sub mono">' + esc([e.ago, e.when].filter(Boolean).join(" · ")) + "</p></div></li>";
        }).join("") + "</ol>" : "") + "</section>";
    }
    if (v.checks.length) {
      b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Checks</h2><span class="sub mono">' + v.checks.length + "</span></div>" +
        v.checks.map(function (c) {
          return '<div class="g-check">' + U.ic(c.level.tone, c.level.icon, "sm") + '<div class="g-check-t"><p class="g-cname mono">' + esc(c.name) + "</p>" +
            (c.note ? '<p class="sub">' + esc(c.note) + "</p>" : "") + (c.checked ? '<p class="sub mono">Checked ' + esc(c.checked) + "</p>" : "") + '</div><span class="g-cstate t-' + c.level.tone + '">' + esc(c.level.word) + "</span></div>";
        }).join("") + "</section>";
    }
    if (v.job.length) {
      var run = v.jobRaw && v.jobRaw.last_run;
      b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Job</h2></div><dl class="g-dl">' +
        v.job.map(function (j) { return "<div><dt>" + esc(j[0]) + '</dt><dd class="mono">' + esc(j[1]) + "</dd></div>"; }).join("") + "</dl>" +
        (run && run.result === "running" && run.total ? '<div class="g-prog"><div class="meter" role="progressbar" aria-valuenow="' + run.done + '" aria-valuemax="' + run.total + '"><b class="run" style="width:' + Math.round(run.done / run.total * 100) + '%"></b></div></div>' : "") + "</section>";
    }
    if (v.chart.some(function (x) { return x != null; })) {
      var last = v.chart.filter(function (x) { return x != null; }).pop();
      b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Last 24 hours</h2>' + (v.metric ? '<span class="sub">' + esc(v.metric) + "</span>" : "") + "</div>" +
        '<p class="g-chart-fig">' + Math.round(last).toLocaleString() + '<span>now</span></p>' + U.chart(v.chart, v.metric) +
        '<div class="strip-axis"><span>24 h ago</span><span>Now</span></div></section>';
    }
    if (v.logs.length) b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Last log lines</h2><span class="sub mono">' + v.logs.length + '</span></div><div class="g-logs">' + U.logLines(v.logs) + "</div></section>";
    b += "</div>";
    return { tone: t, mini: WORD[t] || v.level.word, body: b };
  }

  // ---------- machine ----------
  function machine(id) {
    var s = C.selected(), snap = s && s.state.snapshot, f = s ? C.freshness(s.state) : null;
    if (!snap) return { tone: "quiet", body: '<div class="g-page settle">' + card({ label: "No snapshot yet", icon: "hourglass-medium", fig: "No snapshot yet", figClass: "words", caption: esc(NO_SNAP) }) + (f && f.detail ? U.ageBanner(f) : "") + "</div>" };
    var m = C.machineById(snap, id);
    if (!m) return { tone: "quiet", body: '<div class="g-page settle">' + card({ label: "Not in this snapshot", icon: "info", fig: "Not here", figClass: "words", caption: "The newest snapshot no longer lists this machine." }) + "</div>" };
    var c = C.card(m), t = tone(c), fg = figure(c);
    var mine = [].concat(snap.inbox.needs_you || [], snap.inbox.soon || [], snap.inbox.snoozed || []).filter(function (i) { return i.machine === id; });
    var lede = c.planned ? c.notice + ". That is expected, so Dokkit does not worry about it."
      : c.down ? "It has stopped reporting." : mine.length ? C.plural(mine.length, "thing needs", "things need") + " a look here." : "All good. " + c.counts + ".";
    var pills = [c.word && { v: c.word, k: c.down ? "last report " + (m.last_seen_at ? C.ago(m.last_seen_at).replace(" ago", "") : "") : "reporting" }, m.os && { v: m.os, k: "system" }, { v: String(c.fine.length + c.moreFine.length), k: "fine" }].filter(Boolean);
    var hero = card({ label: c.name, eyebrow: '<p class="g-eyebrow mono">' + esc(c.name) + "</p>", icon: c.planned ? "moon" : t === "ok" ? "check-circle" : t === "down" ? "warning-octagon" : "hourglass-medium",
      fig: esc(fg.v), figClass: /^\d/.test(fg.v) ? "" : "words", caption: esc(fg.k ? (/^\d/.test(fg.v) ? fg.k + ", the busiest now. " : "") : "") + esc(lede), pills: pills, foot: age(f) });
    var b = '<div class="g-page settle">' + hero + (f.warn || f.detail ? U.ageBanner(f) : "");
    if (c.meters.length) b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Right now</h2></div><div class="g-vitals">' + c.meters.map(U.meter).join("") + "</div></section>";
    else if (c.hardware) b += '<p class="sub g-line">' + (c.down ? "Not reporting, so no readings." : "No readings in this snapshot.") + "</p>";
    if (c.lastDay) b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">The last day</h2><span class="sub">half an hour a block</span></div>' + U.strip(c.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div><div class="g-legend">' + U.legend() + "</div></section>";
    if (mine.length) b += '<section class="g-issues"><div class="g-sec-h"><h2 class="g-h">Needs a look</h2></div><div class="g-stack">' + mine.map(function (i) { return U.issueCard(i, snap, "#service/" + i.service); }).join("") + "</div></section>";
    b += '<section class="g-sec"><div class="g-sec-h"><h2 class="g-h">Services</h2><span class="sub">' + esc(c.counts) + '</span></div><div class="g-svcs">' + services(c) + "</div></section></div>";
    return { tone: c.planned ? "quiet" : t, mini: fg.v, body: b };
  }

  // ---------- servers, settings, lock, first run ----------
  function serverTone(s) {
    var snap = s.state.snapshot;
    if (!snap) return { t: "quiet", v: "—", k: "no snapshot yet" };
    var h = C.home(snap);
    if (h.needs.length) return { t: h.needs.some(function (i) { return i.state === "down"; }) ? "down" : "degraded", v: String(h.needs.length), k: h.needs.length === 1 ? "needs you" : "need you" };
    if (h.soon.length) return { t: "soon", v: String(h.soon.length), k: "coming up" };
    return { t: "ok", v: "All clear", k: "nothing needs you" };
  }
  function servers() {
    var list = C.servers(), cur = C.selected();
    var b = '<div class="g-page settle"><header class="g-intro"><p class="g-eyebrow">' + icon("hard-drives") + " Paired with this phone</p><h2 class=\"g-title\">" +
      (list.length ? C.plural(list.length, "server", "servers") : "No server yet") + '</h2><p class="lede">Each keeps its own key, token and snapshot on this phone. Nothing here changes a server.</p></header>';
    if (!list.length) {
      b += notice("quiet", "device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.");
    } else {
      b += '<div class="g-srvs">' + list.map(function (s) {
        var f = C.freshness(s.state), tt = serverTone(s), on = cur && s.id === cur.id;
        return '<article class="g-srv t-' + tt.t + (on ? " current" : "") + '">' +
          '<button class="g-srv-main" type="button" data-show="' + esc(s.id) + '"><span class="g-srv-top"><span class="g-srv-name">' + esc(s.name) + "</span>" + (on ? '<span class="tag g-showing">' + icon("check") + " Showing</span>" : "") + "</span>" +
          '<span class="g-srv-fig"><b>' + esc(tt.v) + "</b><span>" + esc(tt.k) + "</span></span>" +
          '<span class="sub mono">' + esc(C.host(s.relay)) + '</span><span class="sub' + (f.warn ? " warn" : "") + '">' + esc(f.text) + "</span>" + (f.detail ? '<span class="sub warn">' + esc(f.detail) + "</span>" : "") + "</button>" +
          '<button class="iconbtn danger g-srv-x" type="button" data-remove="' + esc(s.id) + '" aria-label="Remove ' + esc(s.name) + '">' + icon("trash") + "</button></article>";
      }).join("") + "</div>";
    }
    return b + '<a class="btn primary block g-cta" href="#add">' + icon("plus") + " Add a server</a></div>";
  }
  function settings() {
    var n = C.SETTINGS.filter(function (s) { return C.isChanged(s.key); }).length;
    return '<div class="g-page settle"><header class="g-intro"><p class="g-eyebrow">' + icon("sliders-horizontal") + " On this phone</p><h2 class=\"g-title\">" + (n ? C.plural(n, "setting changed", "settings changed") : "All on default") +
      '</h2><p class="lede">Everything the app decides on its own. Each starts at today\'s value and can go back to it.</p></header><div class="g-settings">' + U.settingsGroups() + U.about() + "</div></div>";
  }
  function lock() {
    var msg = C.scenario === "nolock" ? "Set a screen lock on this phone to use Dokkit." : C.scenario === "stayed" ? "Dokkit stayed locked." : "Unlock with your fingerprint, face or screen lock.";
    return '<div class="g-center settle">' + card({ hero: true, label: "Dokkit is locked", eyebrow: '<span class="g-brand">' + U.mark(40) + "<b>Dokkit</b></span>", icon: "lock-simple", fig: "Locked", figClass: "words", caption: esc(msg),
      foot: '<button class="btn primary block g-cta" type="button" data-go="#home">' + icon("fingerprint") + " Unlock</button>" }) + "</div>";
  }
  function firstRun() {
    return '<div class="g-center settle">' + card({ hero: true, label: "Welcome to Dokkit", eyebrow: '<span class="g-brand">' + U.mark(40) + "<b>Dokkit</b></span>", fig: "Your servers, at a glance", figClass: "words",
      caption: "A read-only view of your Dokkit server. Alerts still reach you the usual way. Nothing here can change anything.",
      foot: '<p class="sub g-where">The code is in the Dokkit web interface: Settings, Phones, Add a phone.</p><a class="btn primary block g-cta" href="#add">' + icon("qr-code") + ' Scan the code</a><a class="btn ghost block" href="#add/paste">Paste the code instead</a>' }) + "</div>";
  }

  // ---------- render ----------
  function render() {
    var r = route(), app = document.getElementById("app"), page = null, top = "", bottom = "", body;
    if (r.name === "lock") body = lock();
    else if (r.name === "first") body = firstRun();
    else if (r.name === "add") { top = topbar("Add a server", { back: true, backIcon: "x", backLabel: "Cancel", server: false }); body = '<div class="g-add">' + U.addServer(r.id) + "</div>"; }
    else if (r.name === "servers") { top = topbar("Servers", { server: false }); body = servers(); bottom = nav("servers"); }
    else if (r.name === "settings") { top = topbar("Settings", { server: false }); body = settings(); bottom = nav("settings"); }
    else {
      page = r.name === "service" ? service(r.id) : r.name === "machine" ? machine(r.id) : home();
      if (page.full) body = page.body;
      else {
        var noServer = !C.servers().length;
        top = topbar(r.name === "service" ? "Service" : r.name === "machine" ? "Machine" : "Home", { back: r.name !== "home", tools: !noServer, mini: page.mini });
        body = ptr() + (noServer ? '<div class="g-page settle">' + notice("quiet", "device-mobile", "No server paired", "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.") + "</div>" : page.body);
        bottom = nav(r.name === "home" ? "home" : "");
      }
    }
    app.innerHTML = U.phone({ top: top, body: body, bottom: bottom });
    app.querySelector(".phone").dataset.tone = (page && page.tone) || "brand";
    var key = r.name + "/" + r.id;
    after(key !== lastRoute && r.name === "home");
    lastRoute = key;
  }

  function after(arrived) {
    U.wire(render);
    document.querySelectorAll("[data-back]").forEach(function (b) { b.onclick = function () { if (history.length > 1) history.back(); else location.hash = "#home"; }; });
    document.querySelectorAll("[data-refresh]").forEach(function (b) { b.onclick = function () { spin(true); U.fakeRefresh(function () { spin(false); }); }; });
    document.querySelectorAll("[data-picker]").forEach(function (b) { b.onclick = picker; });
    document.querySelectorAll("[data-machine]").forEach(function (b) {
      b.onclick = function () {
        var sec = b.closest(".g-acct"), open = !openMachines[b.dataset.machine];
        openMachines[b.dataset.machine] = open;
        sec.classList.toggle("open", open); b.setAttribute("aria-expanded", open);
      };
    });
    document.querySelectorAll("[data-more]").forEach(function (b) { b.onclick = function () { openMore[b.dataset.more] = !openMore[b.dataset.more]; keepScroll(render); }; });
    document.querySelectorAll("[data-itab]").forEach(function (b) { b.onclick = function () { issueTab = b.dataset.itab; deckOpen = false; keepScroll(render); }; });
    wireDeck();
    if (arrived) countUp();
    scrollVar();
    pullToRefresh();
  }
  function keepScroll(fn) { var s = document.getElementById("screen"), y = s ? s.scrollTop : 0; fn(); var t = document.getElementById("screen"); if (t) t.scrollTop = y; }

  // The balance counts up once when Home arrives.
  function countUp() {
    var el = document.querySelector(".g-fig[data-count]");
    if (!el || C.reduced) return;
    var to = +el.dataset.count, t0 = null, dur = 700;
    el.textContent = "0";
    function step(t) {
      if (t0 == null) t0 = t;
      var p = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - p, 3);
      el.textContent = String(Math.round(to * e));
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }

  // The deck fans out into a list and stacks back, each card gliding from where it was.
  function wireDeck() {
    var d = document.getElementById("deck"), fan = document.getElementById("fan");
    if (!d) return;
    inertBack(d);
    function toggle() {
      var cards = Array.prototype.slice.call(d.children), first = cards.map(function (c) { return c.getBoundingClientRect(); });
      deckOpen = !deckOpen;
      d.classList.toggle("open", deckOpen); d.classList.toggle("closed", !deckOpen);
      if (fan) { fan.setAttribute("aria-expanded", deckOpen); fan.innerHTML = deckOpen ? icon("stack") + " Stack them" : icon("cards") + " See all " + cards.length; }
      inertBack(d);
      if (C.reduced || !Element.prototype.animate) return;
      cards.forEach(function (c, k) {
        var last = c.getBoundingClientRect(), m = getComputedStyle(c).transform;
        var dx = first[k].left - last.left, dy = first[k].top - last.top;
        var from = "translate(" + dx + "px," + dy + "px)" + (m === "none" ? " scale(" + (first[k].width / last.width) + ")" : " " + m);
        var hidden = !deckOpen && k > 2;
        c.animate([{ transform: from, opacity: deckOpen && k > 2 ? 0 : 1 }, { transform: m === "none" ? "none" : m, opacity: hidden ? 0 : 1 }],
          { duration: 460, delay: deckOpen ? k * 45 : (cards.length - 1 - k) * 30, easing: "cubic-bezier(.2,.8,.2,1)", fill: "backwards" });
      });
    }
    if (fan) fan.onclick = toggle;
    d.addEventListener("click", function (e) {
      if (e.target.closest("a, button")) return;
      if (d.classList.contains("closed")) { toggle(); return; }
      var c = e.target.closest(".g-dcard"); if (c) location.hash = c.dataset.href;
    });
  }
  function inertBack(d) {
    Array.prototype.forEach.call(d.children, function (c, k) { if (d.classList.contains("closed") && k > 0) c.setAttribute("inert", ""); else c.removeAttribute("inert"); });
  }

  // Sets --p (0 to 1) from the page scroll for the top bar, and for the card where CSS scroll timelines are missing.
  function scrollVar() {
    var sc = document.getElementById("screen"), ph = document.querySelector(".phone");
    if (!sc || !ph) return;
    if (C.reduced) { ph.style.setProperty("--p", 0); return; }
    var queued = false;
    function set() { queued = false; ph.style.setProperty("--p", Math.min(1, Math.max(0, sc.scrollTop / 220)).toFixed(3)); }
    sc.addEventListener("scroll", function () { if (!queued) { queued = true; requestAnimationFrame(set); } }, { passive: true });
    set();
  }

  function picker() {
    var cur = C.selected();
    U.openLayer('<h2 class="h2" style="margin:0 4px 12px">Show a server</h2>' + C.servers().map(function (s, k) {
      var on = cur && s.id === cur.id, tt = serverTone(s);
      return '<button class="g-pick t-' + tt.t + '" style="--k:' + k + '" type="button" data-pick="' + esc(s.id) + '"' + (on ? ' aria-current="true"' : "") + '><span class="g-pick-t"><span class="srv-name">' + esc(s.name) + '</span><span class="sub">' + esc(tt.v + " " + tt.k) + '</span></span>' + (on ? icon("check-circle") : "") + "</button>";
    }).join(""), "sheet");
    setTimeout(function () {
      document.querySelectorAll("[data-pick]").forEach(function (b) {
        b.onclick = function () { C.select(b.dataset.pick); deckOpen = false; lastRoute = null; U.closeLayer(); setTimeout(render, C.reduced ? 0 : 230); };
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
    sc.addEventListener("mousedown", function (e) { if (!e.target.closest("a,button,input,select,textarea,.g-deck")) start(e.clientY); });
    window.onmousemove = function (e) { move(e.clientY); };
    window.onmouseup = end;
  }

  // Pages cross-fade, and the balance card glides into the next page's card.
  window.addEventListener("hashchange", function () {
    function go() { render(); var s = document.getElementById("screen"); if (s) { s.scrollTop = 0; s.focus({ preventScroll: true }); } }
    if (!document.startViewTransition || C.reduced) { go(); return; }
    var t = document.startViewTransition(go);
    [t.ready, t.finished, t.updateCallbackDone].forEach(function (pr) { pr.catch(function () {}); });
  });
  render();
})();
