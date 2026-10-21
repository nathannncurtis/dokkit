(function () {
  var D = window.DOKKIT, view = document.getElementById("view");
  var TABS = [["needs", "Needs you"], ["soon", "Soon"], ["unwatched", "Not watched"], ["snoozed", "Snoozed"]];
  var ICON = { down: "warning-octagon", degraded: "hourglass-medium", soon: "calendar", found: "binoculars", snoozed: "moon", ok: "check-circle", away: "coffee" };
  var WORD = { down: "Down", degraded: "Slow", soon: "Coming up", found: "Not watched", snoozed: "Snoozed", ok: "Fine", away: "Away" };
  var logLevel = "all", logText = "", everyText = "", acked = {};

  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function byTab(t) { return D.issues.filter(function (i) { return i.tab === t; }); }
  function machine(id) { return D.machines.find(function (m) { return m.id === id; }); }
  function issueState(i) { return i.tab === "snoozed" ? "snoozed" : i.state; }
  function ic(state, cls) { return '<span class="ic ' + (cls || "") + " t-" + state + '" aria-hidden="true"><i class="ph ph-' + (ICON[state] || "circle") + '"></i></span>'; }
  function tag(state, text) { return '<span class="tag t-' + state + '">' + esc(text || WORD[state] || state) + "</span>"; }
  function clock(iso) { return new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }); }

  function nextAction(i) {
    if (i.tab === "snoozed") return ["wake", "Wake it up", "bell"];
    if (i.tab === "unwatched") return ["watch", "Watch it", "eye"];
    if (i.kind === "Job") return ["open", "See the last run", "arrow-right"];
    if (/deploy/i.test(i.note)) return ["open", "Compare with the deploy", "arrow-right"];
    if (i.kind === "Threshold") return ["open", "Look at the disk", "arrow-right"];
    if (i.kind === "Expiry") return ["open", "Plan the renewal", "arrow-right"];
    return ["open", "Look into it", "arrow-right"];
  }

  function sentence(i) {
    var where = i.service === "disk" ? "on " + i.machine : i.service + " on " + i.machine;
    if (i.tab === "unwatched") return "Found on " + i.machine + " by a scan. Dokkit is not watching it yet.";
    if (i.tab === "snoozed") return "Snoozed. It will come back at 17:00 if it is still slow.";
    if (i.state === "down") return "Something is wrong with " + where + " since " + D.ago(i.since) + ".";
    if (i.state === "degraded") return "Working, but not as it should: " + where + ", since " + D.ago(i.since) + ".";
    return "Nothing is broken. Plan for it when it suits you.";
  }

  function row(i, selectable) {
    var st = issueState(i), a = nextAction(i);
    var action = a[0] === "open"
      ? '<a class="btn soft" href="#issue/' + i.id + '">' + esc(a[1]) + ' <i class="ph ph-' + a[2] + '" aria-hidden="true"></i></a>'
      : '<button class="btn soft" type="button" data-do="' + a[0] + '" data-id="' + i.id + '"><i class="ph ph-' + a[2] + '" aria-hidden="true"></i> ' + esc(a[1]) + "</button>";
    return '<li class="issue ' + st + '" data-row="' + i.id + '">' +
      (selectable ? '<input type="checkbox" data-pick="' + i.id + '" aria-label="Select ' + esc(i.title) + '">' : "") +
      ic(st) +
      '<div class="body"><h3><a href="#issue/' + i.id + '">' + esc(i.title) + "</a></h3>" +
      '<p class="say">' + esc(sentence(i)) + "</p>" +
      '<p class="meta"><span><i class="ph ph-hard-drives" aria-hidden="true"></i><span class="mono">' + esc(i.machine) + "</span></span>" +
      "<span>" + esc(i.kind) + "</span>" + (i.env ? "<span>" + esc(i.env) + "</span>" : "") +
      '<span class="mono">' + esc(i.id) + "</span></p></div>" +
      '<div class="act">' + action + "</div></li>";
  }

  function head(eyebrow, title, lede, extra) {
    return '<header class="head">' + (eyebrow ? '<p class="eyebrow">' + eyebrow + "</p>" : "") +
      "<h1>" + esc(title) + "</h1>" + (lede ? '<p class="lede">' + lede + "</p>" : "") + (extra || "") + "</header>";
  }

  function greeting() {
    var h = new Date().getHours();
    return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
  }

  function fineLine() {
    return '<div class="allgood">' + ic("ok") + "<div><p>Everything else is fine: " + D.fine.services + " services on " + D.fine.machines + " machines.</p>" +
      '<p class="sub">Nothing to do there. Dokkit keeps watching.</p></div></div>';
  }

  function strip(m, small) {
    return '<div class="strip' + (small ? " sm" : "") + '" role="img" aria-label="' + esc(m) + ', the last 24 hours">' +
      D.lastDay(m).map(function (c) { return '<i class="' + c + '"></i>'; }).join("") + "</div>";
  }

  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }

  function inbox(tab) {
    tab = tab || "needs";
    var list = byTab(tab), prod = list.filter(function (i) { return !i.env; }), dev = list.filter(function (i) { return i.env; });
    var nNeeds = byTab("needs").length;
    var lede = nNeeds ? plural(nNeeds, "thing needs", "things need") + " you today. " + plural(byTab("soon").length, "is", "are") + " coming up, and nothing else is wrong."
      : "Nothing needs you right now. Enjoy your coffee.";
    var tabs = '<nav class="tabs" aria-label="Inbox">' + TABS.map(function (t) {
      return '<a href="#inbox/' + t[0] + '"' + (t[0] === tab ? ' aria-current="page"' : "") + ">" + t[1] + ' <span class="n">' + byTab(t[0]).length + "</span></a>";
    }).join("") + "</nav>";
    var selectable = tab !== "snoozed";
    var bar = selectable && list.length ? '<div class="toolbar"><label class="check"><input type="checkbox" id="pick-all"> Select all</label><span class="spacer"></span>' +
      '<select class="select" id="snooze-for" aria-label="Snooze for"><option>for 1 hour</option><option>until tomorrow</option><option selected>for 1 day</option><option>for 1 week</option></select>' +
      '<button class="btn" type="button" id="snooze" disabled><i class="ph ph-moon" aria-hidden="true"></i> Snooze selected</button></div>' : "";
    var body = list.length
      ? '<ul class="issues">' + prod.map(function (i) { return row(i, selectable); }).join("") + "</ul>" +
        (dev.length ? '<h2 class="group-h"><i class="ph ph-flask" aria-hidden="true"></i> In dev, so nobody gets woken up</h2><ul class="issues">' + dev.map(function (i) { return row(i, selectable); }).join("") + "</ul>" : "")
      : '<div class="panel empty">' + ic("ok", "lg") + "<p><strong>All clear here.</strong></p><p class=\"sub\">Nothing in this tab.</p></div>";
    var day = '<section class="panel panel-pad" style="margin-top:28px" aria-labelledby="day-h"><h2 class="panel-h" id="day-h">Your machines, the last day</h2><p class="sub">Each block is half an hour. Now is on the right.</p>' +
      '<div class="day-rows">' + D.machines.map(function (m) { return '<a href="#machine/' + m.id + '">' + m.id + "</a>" + strip(m.id, true); }).join("") + "</div>" +
      '<div class="legend"><span><b></b>Fine</span><span><b class="warn"></b>Slow</span><span><b class="bad"></b>Down</span><span><b class="off"></b>Not expected</span></div></section>';
    return head('<i class="ph ph-hand-waving" aria-hidden="true"></i> ' + greeting(), "Inbox", esc(lede)) + tabs + bar + body + (tab === "needs" ? fineLine() + day : "");
  }

  function issue(id) {
    var i = D.issues.find(function (x) { return x.id === id; });
    if (!i) return notFound();
    var st = issueState(i), m = machine(i.machine);
    var noteTint = { down: "t-down", degraded: "t-degraded", soon: "t-soon", found: "t-found", snoozed: "t-snoozed" }[st];
    var tl = i.timeline.length ? '<ol class="timeline">' + i.timeline.map(function (t, k) {
      return '<li><span class="dot ' + (k === 0 ? "t-" + st : "t-ok") + '" aria-hidden="true"><i class="ph ph-' + (k === 0 ? "circle" : "check") + '"></i></span><div><div>' + esc(t[1]) + '</div><div class="when">' + D.ago(t[0]) + " · " + clock(t[0]) + "</div></div></li>";
    }).join("") + "</ol>" : '<p class="sub">Nothing has happened yet. Watch it to start a history.</p>';
    var watching = i.tab !== "unwatched";
    return '<a class="back" href="#inbox/' + i.tab + '"><i class="ph ph-arrow-left" aria-hidden="true"></i> Back to the inbox</a>' +
      '<header class="head hero">' + ic(st, "lg") + "<div><p class=\"eyebrow\">" + tag(st) + ' <span class="mono">' + esc(i.id) + "</span></p><h1>" + esc(i.title) + '</h1><p class="lede">' + esc(sentence(i)) + "</p></div></header>" +
      '<div class="grid-2"><div class="stack">' +
      '<p class="note ' + noteTint + '">' + esc(i.note) + "</p>" +
      '<section class="panel panel-pad"><h2 class="panel-h">What you can do</h2><p class="sub" style="margin-bottom:14px">' + (acked[i.id] ? "You acknowledged this " + acked[i.id] + ". Nobody else will be paged." : "Acknowledge it so nobody else gets paged, or snooze it for later.") + "</p>" +
      '<div class="actions"><button class="btn primary" type="button" data-do="ack" data-id="' + i.id + '"' + (acked[i.id] ? " disabled" : "") + '><i class="ph ph-check" aria-hidden="true"></i> ' + (acked[i.id] ? "Acknowledged" : "Acknowledge") + "</button>" +
      '<select class="select" id="snooze-for" aria-label="Snooze for"><option>for 1 hour</option><option>until tomorrow</option><option selected>for 1 day</option></select>' +
      '<button class="btn" type="button" data-do="snooze1" data-id="' + i.id + '"' + (i.tab === "snoozed" ? " disabled" : "") + '><i class="ph ph-moon" aria-hidden="true"></i> Snooze</button>' +
      '<button class="btn" type="button" data-do="' + (watching ? "unwatch" : "watch") + '" data-id="' + i.id + '"><i class="ph ph-' + (watching ? "eye-slash" : "eye") + '" aria-hidden="true"></i> ' + (watching ? "Stop watching" : "Watch it") + "</button></div></section>" +
      '<section class="panel panel-pad"><h2 class="panel-h" style="margin-bottom:16px">What happened</h2>' + tl + "</section></div>" +
      '<aside class="panel panel-pad"><h2 class="panel-h" style="margin-bottom:14px">Details</h2><dl class="facts">' +
      '<dt>Machine</dt><dd><a class="mono" href="#machine/' + i.machine + '">' + esc(i.machine) + "</a></dd>" +
      '<dt>Service</dt><dd class="mono">' + esc(i.service) + "</dd>" +
      "<dt>Check</dt><dd>" + esc(i.kind) + "</dd>" +
      "<dt>Since</dt><dd>" + D.ago(i.since) + "</dd>" +
      "<dt>Times</dt><dd>" + i.count + "</dd>" +
      (i.env ? "<dt>Where</dt><dd>" + esc(i.env) + "</dd>" : "") +
      (m && m.os ? "<dt>System</dt><dd>" + esc(m.os) + "</dd>" : "") + "</dl></aside></div>";
  }

  function everything() {
    var nSvc = D.services.length;
    return head("", "Everything", "All " + nSvc + " services on " + (D.machines.length) + " machines, in one place. Trouble shows first.") +
      '<div class="toolbar"><label class="field"><i class="ph ph-magnifying-glass" aria-hidden="true"></i><input id="every-q" type="search" placeholder="Filter by machine or service" aria-label="Filter by machine or service" value="' + esc(everyText) + '"></label></div>' +
      '<div class="stack" id="every-list">' + everyList() + "</div>";
  }
  function everyList() {
    var q = everyText.trim().toLowerCase(), order = { down: 0, degraded: 1, soon: 2, snoozed: 3, ok: 4 };
    var html = D.machines.map(function (m) {
      var svc = D.services.filter(function (s) { return s.machine === m.id && (!q || m.id.indexOf(q) > -1 || s.id.toLowerCase().indexOf(q) > -1); })
        .sort(function (a, b) { return order[a.state] - order[b.state]; });
      if (q && !svc.length && m.id.indexOf(q) < 0) return "";
      var bad = svc.filter(function (s) { return s.state !== "ok"; }).length;
      return '<section class="panel machine-card"><div class="mc-head"><span class="pip ' + m.state + '" aria-hidden="true"></span><h2><a href="#machine/' + m.id + '">' + m.id + "</a></h2>" +
        tag(m.state === "ok" ? "ok" : m.state, WORD[m.state]) + '<p class="sub">' + (m.state === "away" ? "Asleep outside office hours" : plural(svc.length, "service", "services") + (bad ? ", " + bad + " with something to say" : ", all fine")) + "</p></div>" +
        (svc.length ? '<ul class="svc-grid">' + svc.map(function (s) {
          return '<li class="svc ' + s.state + '"><span class="pip ' + (s.state === "ok" ? "" : s.state) + '" aria-hidden="true"></span><span class="name">' + esc(s.id) + '</span><span class="what">' + (s.state === "ok" ? s.kind : WORD[s.state]) + "</span></li>";
        }).join("") + "</ul>" : "") + "</section>";
    }).join("");
    return html || '<div class="panel empty">' + ic("found", "lg") + "<p><strong>Nothing matches.</strong></p><p class=\"sub\">Try part of a machine or service name.</p></div>";
  }

  // Every value below is today's built-in value, kept as the default and changeable.
  var CFG = {}, DEFS = {};
  function num(key, def, min, max) { return { key: key, def: def, html: function (v) { return '<input type="number" data-cfg="' + key + '" value="' + v + '" min="' + (min || 0) + '"' + (max ? ' max="' + max + '"' : "") + ">"; } }; }
  function pick(key, def, choices) { return { key: key, def: def, html: function (v) { return '<select data-cfg="' + key + '">' + choices.map(function (c) { return "<option" + (c === v ? " selected" : "") + ">" + c + "</option>"; }).join("") + "</select>"; } }; }
  function flag(key, def) { return { key: key, def: def }; }
  function val(f) { return CFG[f.key] !== undefined ? CFG[f.key] : f.def; }
  function remember(fields) { fields.forEach(function (f) { DEFS[f.key] = f.def; }); }
  function cfgRow(title, sub, fields, words, toggle) {
    var all = fields.concat(toggle ? [toggle] : []);
    remember(all);
    var on = toggle ? val(toggle) : true;
    var changed = all.some(function (f) { return String(val(f)) !== String(f.def); });
    var ctl = (toggle ? '<input type="checkbox" class="switch" data-cfg="' + toggle.key + '"' + (on ? " checked" : "") + ' aria-label="' + esc(title) + '">' : "") +
      words.map(function (w, i) { return (w ? "<span>" + w + "</span>" : "") + (fields[i] ? fields[i].html(val(fields[i])) : ""); }).join(" ");
    var def = words.map(function (w, i) { return (w ? w + " " : "") + (fields[i] ? fields[i].def + " " : ""); }).join("").trim();
    if (toggle) def = (toggle.def ? "On" : "Off") + (fields.length && toggle.def ? ", " + def.charAt(0).toLowerCase() + def.slice(1) : "");
    var keys = all.map(function (f) { return f.key; }).join(" ");
    return '<div class="cfg-row' + (changed ? " changed" : "") + (on ? "" : " off") + '" data-keys="' + keys + '"><div><h3>' + title + '</h3><p class="sub">' + sub + "</p></div>" +
      '<div class="ctl">' + ctl + '</div><span class="def">Default: ' + esc(def) + (changed ? '<button type="button" data-reset="' + keys + '">Reset</button>' : "") + "</span></div>";
  }
  function fold(id, icon, title, sub, rows, open) {
    return '<details class="panel fold fold-group" id="' + id + '"' + (open ? " open" : "") + '><summary><span class="ic" aria-hidden="true"><i class="ph ph-' + icon + '"></i></span><div><h2>' + title + '</h2><p class="sub">' + sub + '</p></div><i class="ph ph-caret-down chev" aria-hidden="true"></i></summary>' +
      '<div class="fold-body"><div class="cfg">' + rows + '</div><div class="save-row"><p class="sub">Changes apply as soon as you save.</p><button class="btn primary" type="button" data-save="' + id + '"><i class="ph ph-check" aria-hidden="true"></i> Save</button></div></div></details>';
  }
  var WHO = ["The default routing", "Page", "Push", "Email", "Only the digest", "Nobody", "Whoever is on call in PagerDuty"];
  function machineRows(p) {
    return cfgRow("Disk space", "Tell me when a disk fills up.", [num(p + "disk", 90, 1, 100), num(p + "disk-n", 3, 1, 100), num(p + "disk-down", 98, 1, 100)], ["Slow at", "% for", "readings in a row, down at", "%"], flag(p + "disk-on", true)) +
      cfgRow("Memory", "Tell me when memory runs short.", [num(p + "mem", 95, 1, 100), num(p + "mem-n", 3, 1, 100), num(p + "mem-down", 98, 1, 100)], ["Slow at", "% for", "readings in a row, down at", "%"], flag(p + "mem-on", true)) +
      cfgRow("Processor", "Tell me when the processor stays busy. New: off until you turn it on.", [num(p + "cpu", 90, 1, 100), num(p + "cpu-min", 10, 1)], ["Slow at", "% for", "minutes"], flag(p + "cpu-on", false)) +
      cfgRow("Gone quiet", "A machine that stops reporting counts as down after this long.", [num(p + "silent", 3, 1)], ["After", "minutes"]) +
      cfgRow("Disk forecast", "Warn ahead of time when a disk is on course to fill.", [num(p + "forecast", 14, 1)], ["When full within", "days"]) +
      cfgRow("Reporting", "How often the program on the machine sends its readings.", [num(p + "every", 1, 1)], ["Every", "minutes"]) +
      cfgRow("Scanning", "How often the machine looks for new services, ports and jobs.", [num(p + "scan", 24, 1)], ["Every", "hours"]) +
      cfgRow("Who hears about it", "Where alerts about this machine go.", [pick(p + "who", WHO[0], WHO)], [""]);
  }
  function jobRows(p) {
    return cfgRow("Late", "How long after its start time a run can begin before it counts as missed.", [num(p + "grace", 30, 0)], ["Grace of", "minutes"]) +
      cfgRow("Too long", "A run going past this is flagged.", [num(p + "max", 60, 1)], ["After", "minutes"]) +
      cfgRow("Missed runs", "Tell me when a run does not happen.", [num(p + "fail", 1, 1, 100)], ["After", "missed in a row"], flag(p + "miss-on", true)) +
      cfgRow("History", "How long the runs and their output are kept.", [num(p + "keep", 90, 1)], ["Keep", "days"]) +
      cfgRow("Who hears about it", "Where alerts about this job go.", [pick(p + "who", WHO[0], WHO)], [""]);
  }

  function machinePage(id) {
    var m = machine(id);
    if (!m) return notFound();
    var mine = D.issues.filter(function (i) { return i.machine === id && i.tab !== "unwatched"; });
    var svc = D.services.filter(function (s) { return s.machine === id; });
    var lede = m.state === "away" ? "This PC sleeps outside office hours. That is expected, so Dokkit does not worry about it."
      : m.state === "ok" ? "All good. " + plural(svc.length, "service", "services") + ", up " + m.uptime + "."
      : plural(mine.length, "thing needs", "things need") + " a look here. Up " + m.uptime + ", running Dokkit " + m.program + ".";
    function vital(key, label, icon, v) {
      if (v == null) return '<div class="panel vital"><div class="vital-top"><span class="ic t-away" aria-hidden="true"><i class="ph ph-' + icon + '"></i></span><span class="label">' + label + '</span></div><p class="sub">Not reporting while away.</p></div>';
      var lvl = v >= 90 ? "bad" : v >= 75 ? "warn" : "";
      var t = lvl === "bad" ? "t-down" : lvl === "warn" ? "t-warn" : "t-ok";
      var words = lvl === "bad" ? "Nearly full, take a look" : lvl === "warn" ? "Busy, still fine" : "Plenty of room";
      return '<div class="panel vital"><div class="vital-top"><span class="ic ' + t + '" aria-hidden="true"><i class="ph ph-' + icon + '"></i></span><span class="label">' + label + '</span><span class="big">' + v + "<small>%</small></span></div>" +
        '<div class="meter" role="meter" aria-label="' + label + '" aria-valuenow="' + v + '" aria-valuemin="0" aria-valuemax="100"><b class="' + lvl + '" style="width:' + v + '%"></b></div><p class="sub">' + words + "</p></div>";
    }
    return '<a class="back" href="#everything"><i class="ph ph-arrow-left" aria-hidden="true"></i> Everything</a>' +
      '<header class="head hero">' + ic(m.state, "lg") + '<div><p class="eyebrow">' + tag(m.state, WORD[m.state]) + " " + esc(m.os) + '</p><h1 class="mono" style="font-weight:500">' + esc(m.id) + '</h1><p class="lede">' + esc(lede) + "</p></div></header>" +
      '<div class="stack"><div class="vitals">' + vital("cpu", "Processor", "cpu", m.cpu) + vital("mem", "Memory", "memory", m.mem) + vital("disk", "Disk", "hard-drive", m.disk) + "</div>" +
      '<section class="panel panel-pad"><h2 class="panel-h">The last day</h2><p class="sub" style="margin-bottom:16px">Each block is half an hour.</p>' + strip(m.id) +
      '<div class="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div></section>' +
      (mine.length ? '<section><h2 class="panel-h" style="margin:4px 4px 12px">Needs a look</h2><ul class="issues">' + mine.map(function (i) { return row(i, false); }).join("") + "</ul></section>" : "") +
      '<section class="panel panel-pad"><h2 class="panel-h" style="margin-bottom:14px">Services</h2>' +
      (svc.length ? '<ul class="svc-grid">' + svc.map(function (s) {
        return '<li class="svc ' + s.state + '"><span class="pip ' + (s.state === "ok" ? "" : s.state) + '" aria-hidden="true"></span><span class="name">' + esc(s.id) + '</span><span class="what">' + (s.state === "ok" ? s.kind : WORD[s.state]) + "</span></li>";
      }).join("") + "</ul>" : '<p class="sub">No services are watched here.</p>') + "</section>" +
      fold("cfg-" + m.id, "sliders-horizontal", "Settings for " + m.id, "When and how this machine alerts you. Each starts at the default for every machine.", machineRows(m.id + ":")) + "</div>";
  }

  function jobs() {
    var running = D.jobs.filter(function (j) { return j.last === "running"; }).length;
    return head("", "Jobs", "Three jobs on a schedule. " + running + " is running now, and one missed its start last night.") +
      '<div class="jobs">' + D.jobs.map(function (j) {
        var st = j.last === "ok" ? "ok" : j.last === "missed" ? "down" : "soon";
        var icon = { ok: "check-circle", down: "warning-octagon", soon: "spinner-gap" }[st];
        var say = j.last === "ok" ? "Last ran " + D.ago(j.lastRun) + " and took " + j.took + "."
          : j.last === "missed" ? "Did not start at its last time. The run before took " + j.took + "."
          : "Started " + D.ago(j.lastRun) + ".";
        var prog = j.progress ? '<div class="progress"><div class="meter" role="progressbar" aria-label="' + j.id + ' progress" aria-valuenow="' + j.progress[0] + '" aria-valuemin="0" aria-valuemax="' + j.progress[1] + '"><b class="run" style="width:' + Math.round(j.progress[0] / j.progress[1] * 100) + '%"></b></div>' +
          '<p class="sub">' + j.progress[0].toLocaleString() + " of " + j.progress[1].toLocaleString() + " steps, about " + Math.round(j.progress[0] / j.progress[1] * 100) + "% done</p></div>" : "";
        return '<section class="panel job"><span class="ic lg t-' + st + '" aria-hidden="true"><i class="ph ph-' + icon + '"></i></span>' +
          "<div><h2>" + j.id + '</h2><p class="say">' + say + '</p><p class="sub">On <a class="mono" href="#machine/' + j.machine + '">' + j.machine + "</a> · " + j.schedule + "</p>" + prog + "</div>" +
          '<div><p class="sub" style="margin-bottom:6px;font-size:13px">Recent runs</p><div class="runs" role="img" aria-label="Recent runs: ' + j.runs.join(", ") + '">' + j.runs.map(function (r) { return '<i class="' + r + '"></i>'; }).join("") + "</div></div></section>" +
          fold("job-" + j.id, "sliders-horizontal", "Settings for " + j.id, "When it counts as late, too long or missing.", jobRows(j.id + ":"));
      }).join("") + "</div>";
  }

  var LOG_COLS = [["at", "Time"], ["level", "Level"], ["machine", "Machine"], ["service", "Service"], ["msg", "Message"]];
  var logSort = { col: "at", dir: -1 }, logMachine = "", logService = "", logSince = 0;
  var RANK = { error: 0, warn: 1, info: 2 };
  function logs() {
    var errs = D.logs.filter(function (l) { return l.level === "error"; }).length;
    function opts(key, label) {
      return '<select class="select" data-logf="' + key + '" aria-label="' + label + '"><option value="">' + label + ": all</option>" +
        uniq(D.logs.map(function (l) { return l[key]; })).map(function (v) { return '<option' + ((key === "machine" ? logMachine : logService) === v ? " selected" : "") + ">" + esc(v) + "</option>"; }).join("") + "</select>";
    }
    return head("", "Logs", "The last two hours from your apps. " + plural(errs, "line is an error", "lines are errors") + ", all from the same resize step.") +
      '<div class="filters"><div class="seg" role="group" aria-label="Level">' + ["all", "info", "warn", "error"].map(function (l) {
        return '<button type="button" data-level="' + l + '" aria-pressed="' + (l === logLevel) + '">' + { all: "All", info: "Info", warn: "Warnings", error: "Errors" }[l] + "</button>";
      }).join("") + "</div>" + opts("machine", "Machine") + opts("service", "Service") +
      '<select class="select" data-logf="since" aria-label="Time"><option value="0">Any time</option><option value="15">Last 15 min</option><option value="60">Last hour</option><option value="120">Last 2 hours</option></select>' +
      '<label class="field"><i class="ph ph-magnifying-glass" aria-hidden="true"></i><input id="log-q" type="search" placeholder="Filter the text" aria-label="Filter the log text" value="' + esc(logText) + '"></label>' +
      '</div><div class="filters"><p class="count-line" id="log-count" style="margin:0"></p><span class="spacer"></span><button class="btn" type="button" id="log-csv"><i class="ph ph-download-simple" aria-hidden="true"></i> Export CSV</button></div>' +
      '<section class="panel"><div class="log-wrap" id="log-list">' + logList() + "</div></section>";
  }
  function uniq(a) { return a.filter(function (v, i) { return a.indexOf(v) === i; }).sort(); }
  function logRows() {
    var q = logText.trim().toLowerCase(), cut = logSince ? D.now - logSince * 60000 : 0;
    return D.logs.filter(function (l) {
      return (logLevel === "all" || l.level === logLevel) && (!logMachine || l.machine === logMachine) && (!logService || l.service === logService) &&
        (!cut || new Date(l.at) >= cut) && (!q || (l.msg + " " + l.service + " " + l.machine).toLowerCase().indexOf(q) > -1);
    }).sort(function (a, b) {
      var c = logSort.col, x = c === "level" ? RANK[a.level] : a[c], y = c === "level" ? RANK[b.level] : b[c];
      return (x < y ? -1 : x > y ? 1 : 0) * logSort.dir;
    });
  }
  function logList() {
    var rows = logRows();
    var count = document.getElementById("log-count");
    if (count) count.textContent = "Showing " + rows.length + " of " + D.logs.length + " lines";
    if (!rows.length) return '<div class="empty" style="padding:28px"><p><strong>No lines match.</strong></p><p class="sub">Try another word, level or machine.</p></div>';
    return '<table class="log-table"><thead><tr>' + LOG_COLS.map(function (c) {
      var on = logSort.col === c[0];
      return "<th" + (on ? ' aria-sort="' + (logSort.dir > 0 ? "ascending" : "descending") + '"' : "") + '><button type="button" data-sort="' + c[0] + '">' + c[1] +
        ' <i class="ph ph-' + (on ? (logSort.dir > 0 ? "caret-up" : "caret-down") : "caret-up-down") + '" aria-hidden="true"></i></button></th>';
    }).join("") + "</tr></thead><tbody>" + rows.map(function (l) {
      return '<tr class="' + l.level + '"><td class="at">' + clock(l.at) + "</td><td>" + tag(l.level === "error" ? "error" : l.level === "warn" ? "warn" : "info", { info: "Info", warn: "Warning", error: "Error" }[l.level]) +
        '</td><td class="m">' + esc(l.machine) + '</td><td class="s">' + esc(l.service) + '</td><td class="msg">' + esc(l.msg) + "</td></tr>";
    }).join("") + "</tbody></table>";
  }
  function refreshLogs() { document.getElementById("log-list").innerHTML = logList(); }
  function exportCsv() {
    var cell = function (v) { v = String(v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
    var csv = ["time,level,machine,service,message"].concat(logRows().map(function (l) { return [l.at, l.level, l.machine, l.service, l.msg].map(cell).join(","); })).join("\r\n");
    var a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    a.download = "dokkit-logs.csv"; document.body.appendChild(a); a.click(); a.remove();
    toast("Exported " + plural(logRows().length, "line", "lines") + " to dokkit-logs.csv.");
  }

  function settings() {
    return head("", "Settings", "Everything Dokkit decides on its own, and how to change it. Each starts at a sensible default.") +
      '<div class="stack">' +
      fold("set-look", "palette", "Look", "Light or dark.", '<div class="cfg-row" data-keys=""><div><h3>Theme</h3><p class="sub">Light is calm for daytime; dark is easy at night.</p></div><div class="ctl"><button class="btn" type="button" data-do="theme"><i class="ph ph-moon-stars" aria-hidden="true"></i> Switch look</button></div><span class="def">Default: dark</span></div>') +
      fold("set-alerts", "bell-ringing", "Alerts", "Who hears about what, and when.",
        cfgRow("Who gets told", "Where alerts go unless a machine, service or job says otherwise.", [pick("who", "You, by push and email", ["You, by push and email", "You, by page", "Everyone on call", "Only the digest", "Whoever is on call in PagerDuty"])], [""]) +
        '<div class="cfg-row who-extra" data-show="Whoever is on call in PagerDuty" data-keys="pd-schedule"><div><h3>PagerDuty schedule</h3><p class="sub">On call now: <b>Sam</b>, until Monday 09:00. Read from PagerDuty.</p></div>' +
        '<div class="ctl"><span>Use</span>' + pick("pd-schedule", "Primary on-call", ["Primary on-call", "Secondary on-call", "Database team"]).html(val({ key: "pd-schedule", def: "Primary on-call" })) + '</div><span class="def">The schedules come from your PagerDuty account.</span></div>' +
        cfgRow("Night hours", "Between these times only things that are down reach your phone.", [pick("night-from", "22:00", ["20:00", "21:00", "22:00", "23:00"]), pick("night-to", "07:00", ["06:00", "07:00", "08:00"])], ["From", "to", ""], flag("night-on", true)) +
        cfgRow("Morning digest", "One message with everything that can wait.", [pick("digest", "07:00", ["06:00", "07:00", "08:00", "09:00"])], ["At", ""]) +
        cfgRow("Remind me", "Alert again while an issue stays open and nobody has acknowledged it.", [num("repeat", 30, 5)], ["Every", "minutes"], flag("repeat-on", false)) +
        cfgRow("Snooze choices", "The lengths offered when you snooze.", [pick("snooze", "1 h, 4 h, 1 day, 1 week", ["1 h, 4 h, 1 day, 1 week", "30 min, 2 h, 1 day", "1 day, 1 week, 1 month"])], [""]) +
        cfgRow("Too noisy?", "Suggest moving a check to the digest when it keeps opening.", [num("sugg", 6, 1), num("sugg-days", 30, 1)], ["After", "times in", "days"]) +
        cfgRow("Sending", "How many times a failed send is retried.", [num("retries", 5, 0, 20)], ["Retry", "times"]), true) +
      fold("set-machines", "hard-drives", "Defaults for every machine", "Each machine can change these on its own page.", machineRows("all:")) +
      fold("set-checks", "pulse", "Checks", "How services are checked unless a dokkit.toml says otherwise.",
        cfgRow("Down after", "How many failures in a row before a check counts as down.", [num("fail", 3, 1, 100)], ["", "failures in a row"]) +
        cfgRow("How often", "Time between checks.", [num("every", 30, 5)], ["Every", "seconds"]) +
        cfgRow("Give up after", "How long one check may take.", [num("timeout", 5, 1)], ["", "seconds"]) +
        cfgRow("Certificates", "Warn ahead of a certificate running out.", [num("expiry", 30, 1)], ["", "days before"]) +
        cfgRow("Restarts", "Shortest gap between automatic restarts of a service.", [num("restart", 10, 1)], ["At least", "minutes apart"]) +
        cfgRow("Same issue", "A problem that comes back this soon reopens the old issue instead of a new one.", [num("reopen", 30, 0)], ["Within", "minutes"]) +
        cfgRow("After Dokkit restarts", "Give machines time to report before judging them.", [num("warmup", 3, 0)], ["Wait", "minutes"])) +
      fold("set-logs", "scroll", "Logs", "How long lines are kept.",
        cfgRow("Keep", "Lines older than this leave the database.", [num("months", 12, 1, 120), pick("after", "archive them", ["archive them", "delete them"])], ["", "months, then", ""]) +
        cfgRow("Restored archives", "How long a restored month stays searchable.", [num("restored", 7, 1)], ["", "days"]) +
        cfgRow("Longest line", "Longer lines are cut.", [num("longest", 64, 1, 1024)], ["", "KB"])) +
      fold("set-errors", "bug", "Errors and deploys", "What is kept, and when a burst of errors alerts.",
        cfgRow("Error alerts", "Open an issue when errors burst. New: off until you turn it on.", [num("err-n", 10, 1), num("err-min", 15, 1)], ["When", "errors arrive within", "minutes"], flag("err-alert", false)) +
        cfgRow("Stored", "How many occurrences of one error are kept in full.", [num("store", 100, 1)], ["First", ", then every 100th"]) +
        cfgRow("Message text", "Keep the full text of error messages.", [], [""], flag("keep-msg", false)) +
        cfgRow("After a deploy", "Compare errors before and after a deploy over this window.", [num("dep-win", 60, 5)], ["", "minutes"])) +
      fold("set-server", "gear-six", "Server", "Housekeeping and sign-in.",
        cfgRow("Stay signed in", "How long a sign-in lasts.", [num("session", 14, 1)], ["", "days"]) +
        cfgRow("Readings", "How long machine readings are kept.", [num("metrics", 30, 1)], ["", "days"]) +
        cfgRow("Process lists", "How long the top-processes snapshots are kept.", [num("procs", 24, 1)], ["", "hours"]) +
        cfgRow("Unknown machines", "Machines that reported once and never enrolled are forgotten after.", [num("forget", 30, 1)], ["", "days"]) +
        cfgRow("Own certificate", "Warn before this server's certificate runs out.", [num("cert-warn", 21, 1)], ["", "days before"]) +
        cfgRow("Nothing reporting", "Alarm when no machine has reported for this long.", [num("self-min", 10, 1)], ["", "minutes"]) +
        cfgRow("Add-a-machine codes", "How long a new enrolment code works.", [num("enrol", 4, 1, 72)], ["", "hours"]) +
        cfgRow("Sign-in attempts", "Wrong tries allowed before a ten-minute wait.", [num("logins", 10, 1)], ["", "tries"])) +
      "</div>";
  }

  function notFound() { return head("", "Not here", "That page does not exist. The <a href=\"#inbox\">inbox</a> is a good place to start."); }

  function side() {
    document.getElementById("nav-count").textContent = byTab("needs").length || "";
    document.getElementById("side-machines").innerHTML = D.machines.map(function (m) {
      var hint = m.attention ? m.attention + " to look at" : m.soon ? m.soon + " soon" : m.state === "away" ? "away" : "";
      return '<li><a href="#machine/' + m.id + '"><span class="pip ' + m.state + '" aria-hidden="true"></span>' + m.id + '<span class="hint">' + hint + "</span></a></li>";
    }).join("");
  }

  function route() {
    var parts = (location.hash.slice(1) || "inbox").split("/"), r = parts[0];
    var pages = { inbox: function () { return inbox(parts[1]); }, issue: function () { return issue(parts[1]); }, everything: everything,
      machine: function () { return machinePage(parts[1]); }, jobs: jobs, logs: logs, settings: settings };
    view.innerHTML = (pages[r] || notFound)();
    if (r === "logs") refreshLogs();
    if (r === "settings") whoExtras();
    side();
    var navKey = r === "issue" ? "inbox" : r === "machine" ? "everything" : r;
    document.querySelectorAll(".nav a").forEach(function (a) { a.toggleAttribute("aria-current", a.dataset.r === navKey); if (a.dataset.r === navKey) a.setAttribute("aria-current", "page"); });
    document.querySelectorAll(".side-machines a").forEach(function (a) { if (a.getAttribute("href") === "#machine/" + parts[1] && r === "machine") a.setAttribute("aria-current", "page"); });
    document.title = (view.querySelector("h1") ? view.querySelector("h1").textContent + " · " : "") + "Dokkit";
  }

  var toastTimer;
  function toast(msg) {
    var t = document.getElementById("toast");
    t.textContent = msg; t.classList.add("show");
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.classList.remove("show"); }, 2600);
  }

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function leave(ids, after) {
    ids.forEach(function (id) { var el = view.querySelector('[data-row="' + id + '"]'); if (el) el.classList.add("leaving"); });
    setTimeout(after, reduce ? 0 : 260);
  }
  function moveTo(ids, tab, msg) {
    leave(ids, function () {
      ids.forEach(function (id) { var i = D.issues.find(function (x) { return x.id === id; }); i.tab = tab; });
      route(); toast(msg);
    });
  }
  function snoozeFor() { var s = document.getElementById("snooze-for"); return s ? s.value : "for 1 day"; }

  function setTheme(dark) {
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    var b = document.getElementById("theme");
    b.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
    b.innerHTML = '<i class="ph ph-' + (dark ? "sun" : "moon-stars") + '" aria-hidden="true"></i>';
    try { localStorage.setItem("d6-theme", dark ? "dark" : "light"); } catch (e) {}
  }
  var saved = null;
  try { saved = localStorage.getItem("d6-theme"); } catch (e) {}
  setTheme(saved !== "light");
  document.getElementById("theme").addEventListener("click", function () { setTheme(document.documentElement.dataset.theme !== "dark"); });

  DEFS["pd-schedule"] = "Primary on-call";
  function whoExtras() {
    var who = CFG.who || "You, by push and email";
    view.querySelectorAll(".who-extra").forEach(function (r) { r.hidden = r.dataset.show !== who; });
  }
  function markRow(row) {
    var keys = row.dataset.keys ? row.dataset.keys.split(" ") : [];
    var changed = keys.some(function (k) { return CFG[k] !== undefined && String(CFG[k]) !== String(DEFS[k]); });
    row.classList.toggle("changed", changed);
    var sw = row.querySelector(".switch");
    if (sw) row.classList.toggle("off", !sw.checked);
    var def = row.querySelector(".def"), btn = def.querySelector("button");
    if (changed && !btn) def.insertAdjacentHTML("beforeend", '<button type="button" data-reset="' + keys.join(" ") + '">Reset</button>');
    if (!changed && btn) btn.remove();
  }
  view.addEventListener("change", function (e) {
    var t = e.target;
    if (t.dataset.cfg) { CFG[t.dataset.cfg] = t.type === "checkbox" ? t.checked : t.type === "number" ? +t.value : t.value; markRow(t.closest(".cfg-row")); }
    if (t.dataset.cfg === "who") whoExtras();

    if (t.dataset.logf) {
      if (t.dataset.logf === "machine") logMachine = t.value;
      if (t.dataset.logf === "service") logService = t.value;
      if (t.dataset.logf === "since") logSince = +t.value;
      refreshLogs();
    }
    if (t.id === "pick-all") view.querySelectorAll("[data-pick]").forEach(function (c) { c.checked = t.checked; });
    if (t.id === "pick-all" || t.dataset.pick) {
      var n = view.querySelectorAll("[data-pick]:checked").length, b = document.getElementById("snooze");
      b.disabled = !n; b.innerHTML = '<i class="ph ph-moon" aria-hidden="true"></i> ' + (n ? "Snooze " + n : "Snooze selected");
    }
  });

  view.addEventListener("input", function (e) {
    if (e.target.id === "log-q") { logText = e.target.value; refreshLogs(); }
    if (e.target.id === "every-q") { everyText = e.target.value; document.getElementById("every-list").innerHTML = everyList(); }
  });

  view.addEventListener("click", function (e) {
    var b = e.target.closest("button");
    if (!b) return;
    if (b.id === "snooze") {
      var ids = Array.prototype.map.call(view.querySelectorAll("[data-pick]:checked"), function (c) { return c.dataset.pick; });
      moveTo(ids, "snoozed", "Snoozed " + plural(ids.length, "issue", "issues") + " " + snoozeFor() + ".");
    }
    if (b.dataset.level) { logLevel = b.dataset.level; view.querySelectorAll("[data-level]").forEach(function (x) { x.setAttribute("aria-pressed", x === b); }); refreshLogs(); }
    if (b.dataset.sort) { logSort = { col: b.dataset.sort, dir: logSort.col === b.dataset.sort ? -logSort.dir : (b.dataset.sort === "at" ? -1 : 1) }; refreshLogs(); }
    if (b.id === "log-csv") exportCsv();
    if (b.dataset.reset) {
      var row = b.closest(".cfg-row");
      b.dataset.reset.split(" ").forEach(function (k) {
        delete CFG[k];
        var el = row.querySelector('[data-cfg="' + k + '"]');
        if (el.type === "checkbox") el.checked = DEFS[k]; else el.value = DEFS[k];
      });
      markRow(row);
      toast("Back to the default.");
    }
    if (b.dataset.save) {
      var n = b.closest("details").querySelectorAll(".cfg-row.changed").length;
      toast(n ? "Saved. " + plural(n, "setting differs", "settings differ") + " from the default." : "Saved. Everything is on its default.");
    }

    var id = b.dataset.id, d = b.dataset.do;
    if (d === "watch") moveTo([id], "watched", "Now watching it. You will hear if it stops.");
    if (d === "wake") moveTo([id], "needs", "Woken up. It is back in Needs you.");
    if (d === "snooze1") { D.issues.find(function (x) { return x.id === id; }).tab = "snoozed"; route(); toast("Snoozed " + snoozeFor() + "."); }
    if (d === "unwatch") { D.issues.find(function (x) { return x.id === id; }).tab = "unwatched"; route(); toast("Stopped watching. It is under Not watched now."); }
    if (d === "ack") { acked[id] = "just now"; route(); toast("Acknowledged. Nobody else will be paged."); }
    if (d === "theme") setTheme(document.documentElement.dataset.theme !== "dark");
  });

  window.addEventListener("hashchange", function () { route(); view.focus({ preventScroll: true }); window.scrollTo(0, 0); });
  route();
})();
