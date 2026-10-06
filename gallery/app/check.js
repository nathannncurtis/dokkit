// node check.js: renders every route against a stub DOM; fails on a throw or on "undefined" in the output.
var fs = require("fs"), vm = require("vm"), path = require("path");
var els, ctx;
function boot(search, hash) {
  els = {};
  ctx = {
  location: { hash: hash || "", search: search || "" },
  document: { documentElement: { className: "" }, getElementById: function (id) { return els[id] || (els[id] = { innerHTML: "" }); } },
  window: { addEventListener: function () {}, scrollTo: function () {} }, localStorage: { setItem: function () {}, getItem: function () { return null; } }, console: console
  };
  vm.createContext(ctx);
  ["data.js", "more.js", "app.js"].forEach(function (f) { vm.runInContext(fs.readFileSync(path.join(__dirname, f), "utf8"), ctx); });
}
boot();
var routes = ["", "#/inbox", "#/all", "#/jobs", "#/logs", "#/errors", "#/alerts", "#/settings", "#/found", "#/versions", "#/deploys", "#/tasks"], n = 0;
vm.runInContext("ERRS", ctx).forEach(function (e) { routes.push("#/e/" + e.id); });
function run(js) { return vm.runInContext(js, ctx); }
function has(r, text, want) { if ((show(r).indexOf(text) >= 0) !== (want !== false)) throw new Error(r + (want === false ? " still shows " : " does not show ") + text); }
vm.runInContext("MACHINES", ctx).forEach(function (m) { routes.push("#/m/" + m.id); m.services.forEach(function (s) { routes.push("#/s/" + m.id + "/" + s.id); }); });
// Spelled in halves so this file passes the same grep it enforces.
var banned = new RegExp("[" + String.fromCharCode(8212, 8211, 183) + "]|" + ["ron sin", "dav ik", "doc ket", "dav it", "tri star", "win copy", "share file", "ncu rtis", "nas- prod", "rw eb", "27 7", "spec ials", "ag ent"].join("|").replace(/ /g, ""), "i");
function show(r) {
  ctx.location.hash = r; vm.runInContext("render()", ctx);
  var html = els.side.innerHTML + els.page.innerHTML;
  var bad = html.match(/.{30}(undefined|NaN|\[object).{30}/);
  if (bad) throw new Error("bad output on " + r + ": " + bad[0]);
  var old = html.match(banned);
  if (old) throw new Error("banned dash, dot or old name on " + r + ": " + old[0]);
  n++; return html;
}
routes.forEach(show);
var need = run("MACHINES.reduce(function (a, m) { return a + cnt(m, 'warn'); }, 0)");
if (run("live().length") !== need) throw new Error("Needs you is " + run("live().length") + ", the sidebar adds up to " + need);
has("#/inbox", "Needs you<span class=\"cnt\">" + need + "<"); has("#/inbox", "placeholder=\"Filter issues, services and machines\""); has("#/inbox", "2 times"); has("#/inbox", "since Oct 5"); has("#/inbox", "<span class=\"r\">Count</span>"); has("#/inbox", "Select all"); has("#/inbox", "disabled onclick=\"snooze()\""); has("#/inbox", "data-some", false); has("#/inbox", "<span class=\"msg\">Rush Tracker: poll cycle failed, database connection timed out</span><span class=\"meta\"><span>desk-53</span><span>2 times</span>"); has("#/inbox", "<a href=\"#/logs\">Errors today</a><span class=\"cnt\">3</span>"); has("#/inbox", "<span class=\"st warn\">2 need a look</span>"); has("#/inbox", "Proof staging: run stopped with exit code 1"); has("#/inbox", "1<small>failed run</small>"); has("#/inbox", "51 watched, 9 not"); has("#/inbox", "things<", false);
if (show("#/inbox").indexOf("DOK-1</span><span>since Jul 16") < 0 || show("#/inbox").indexOf("DOK-6</span><span>since Oct 5") < 0) throw new Error("the inbox does not run oldest first");
if (run("found().length") + "" !== (show("#/inbox").match(/Found<span class="n">(\d+)/) || [])[1]) throw new Error("the Found badge and the Not watched tab disagree");
run("NOW.forEach(function (n) { if (n.title.length > 36 || n.sub.length > 80 || n.sub.length < 60) throw new Error('title or second line too long: ' + n.title); })");
run("tickOne(1)"); has("#/inbox", "disabled onclick=\"snooze()\"", false); has("#/inbox", "data-some onchange=\"tickAll"); run("tickOne(1)");
run("setTab('soon')"); has("#/inbox", "At this rate it crosses 90% in about 9 days."); has("#/inbox", "of 90% limit"); has("#/inbox", "Threshold", false); has("#/inbox", "<span class=\"\">Trend</span>"); has("#/inbox", "Open press02</a>"); has("#/inbox", "class=\"chk\"", false); has("#/inbox", "Snooze selected", false);
run("setTab('found')"); has("#/inbox", "<span class=\"\">How it was found</span>"); has("#/inbox", "Listening port <span class=\"mono\">:7300</span>"); has("#/inbox", "No run seen yet."); has("#/inbox", "Named in Courier app relay's config"); has("#/inbox", "Used by 2 services."); has("#/inbox", "Used by Courier app relay."); has("#/inbox", "Unclaimed port"); has("#/inbox", "class=\"chk\"", false);
run("setTab('now')");
has("#/s/depends/db", "No checks yet. Add one to start a history."); has("#/s/depends/db", "Add a check to choose who hears about it."); has("#/s/depends/db", "Recent deploys", false); has("#/s/depends/db", "<dt>Used by</dt><dd><span><a href=\"#/s/outside/relay\">Courier app relay</a></span></dd>"); has("#/s/depends/db", "<dt>Calls</dt><dd>47 from Courier app relay in the last 5 minutes, none failed</dd>"); has("#/s/depends/routewise", "206 from Courier app relay in the last 5 minutes, none failed"); has("#/s/depends/db", "Seen, not checked", false); has("#/s/depends/db", "<dt>Host</dt><dd><span class=\"mono\">db01.brightwater.example</span></dd><dt>Port</dt><dd><span class=\"mono\">5432</span>"); has("#/s/depends/db", "Listens on", false); has("#/s/depends/db", ">Dependency</span>"); has("#/s/depends/smtp", "What Dokkit knows", false); has("#/s/depends/db", "Latest logs", false); has("#/s/depends/db", "#/logs?s=db", false); has("#/s/depends/db", "<span class=\"mute\">Never</span>");
has("#/s/vault/loghouse", "<svg viewBox=\"0 0 760"); has("#/s/vault/keyring", "Not reported"); has("#/s/vault/keyring", ">Snooze<", false); has("#/s/vault/helpdesk", ">Snooze<"); has("#/s/vault/helpdesk", "Went out"); has("#/s/vault/helpdesk", "build Jun 3"); has("#/s/vault/helpdesk", "Recent deploys<span class=\"cnt\">3</span>"); has("#/s/vault/helpdesk", " on vault", false); has("#/s/vault/loghouse", "Every check failed, last 24 days"); has("#/s/vault/keyring", "<span class=\"mute\">Not reported</span>");
has("#/s/vault/mail-links", "At each run"); has("#/s/vault/mail-links", "<dt>Version</dt>", false); has("#/s/vault/mail-links", "Restart first", false); has("#/s/vault/mail-links", "Recent deploys", false); has("#/s/vault/mail-links", "Listens on", false); has("#/s/vault/mail-links", "If it runs late"); has("#/s/vault/offsite", "Newest first", false); has("#/s/vault/offsite", "No run seen yet."); has("#/s/vault/offsite", "Every day at 03:30"); has("#/s/vault/offsite", "<span class=\"mono\">Oct 6 03:30</span>"); has("#/s/vault/offsite", "No log lines from this job yet."); has("#/s/vault/offsite", "<span class=\"mute\">None yet</span>"); has("#/s/vault/mail-links", "Oct 5 01:10  <em>info </em>  Finished in 5 s"); has("#/s/vault/mail-links", "Oct 5 01:10</span><span class=\"tag \">Finished</span><span class=\"mono r\">5 s<"); has("#/s/vault/mail-links", "<span>Started</span><span>Result</span><span class=\"r\">Took</span><span class=\"r\">Exit code</span>"); has("#/s/vault/mail-links", "class=\"run\" open", false); has("#/s/vault/offsite", "No run seen yet</span>");
has("#/s/press01/proofs", "Open the failed run</button>"); has("#/s/press01/proofs", "since Oct 5", false); has("#/s/vault/loghouse", "<span class=\"st\">Health check failing since Aug 8</span>"); has("#/all", "<span class=\"tag warn\">Health check failing since Aug 8</span>"); has("#/s/vault/loghouse", "Aug 8 08:10  <b>error</b>  Health check failed"); has("#/s/vault/loghouse", "167,040 failures in a row"); has("#/inbox", "167,040<small>failed checks</small>");
if (count(show("#/s/vault/loghouse"), "height=\"60.0\"") !== 48) throw new Error("Loghouse's failed checks should draw 48 short bars of one height"); has("#/s/press01/proofs", "Oct 5 16:52  <b>error</b>  Run stopped with exit code 1</span>\n<span style=\"--hang:20ch\">Oct 5 15:52  <em>info </em>  Finished in "); has("#/s/press01/sweeper", "Oct 1 19:30  <b>error</b>  Run stopped with exit code 1"); has("#/s/press01/sweeper", "class=\"run\" open", false); has("#/s/vault/helpdesk", "<span class=\"mono\">build Jun 3</span>, healthy"); has("#/logs", "Run stopped with exit code 1");
if ((show("#/s/press01/proofs").match(/class="run" open/g) || []).length !== 1 || show("#/s/press01/proofs").indexOf("class=\"run\" open") > show("#/s/press01/proofs").indexOf("Oct 5 15:52")) throw new Error("the failed run should be the one open row");
if ((show("#/s/outside/site-scan").split("Latest logs")[1].match(/Finished in/g) || []).length !== 3 || (show("#/s/gpu01/infer-watch").split("Latest logs")[1].match(/Finished in/g) || []).length !== 5) throw new Error("Latest logs should have one line for each run");
has("#/s/pcs/a-notifier", "Listens on", false); has("#/s/pcs/a-notifier", "If it goes quiet"); has("#/s/pcs/a-notifier", "Recent deploys", false); has("#/s/pcs/a-notifier", "Reports today", false); has("#/s/pcs/a-notifier", "PCs reporting, last 24 days, 16 to 24<"); has("#/s/pcs/a-proof", "PCs reporting, last 24 days, 4 to 6<"); has("#/s/pcs/a-scan", "PCs reporting, last 24 days, 1<"); has("#/s/pcs/a-notifier", "When a PC reports"); has("#/s/pcs/a-notifier", "No log lines from this app yet."); has("#/s/pcs/a-proof", "On 6 PCs, one behind, 2 reports today"); has("#/s/pcs/a-rush", "On 2 PCs, one held, 2 reports today"); has("#/s/pcs/a-notifier", ">24 PCs<"); has("#/s/pcs/a-rush", "Reports today"); has("#/s/pcs/a-rush", ">2 reports<"); has("#/s/pcs/a-proof", "desk-47"); has("#/s/pcs/a-proof", "desk-53", false); has("#/s/pcs/a-rush", "Poll cycle failed"); has("#/s/vault/keyring", "No deploy seen yet."); has("#/s/vault/keyring", "No log lines from this service yet.");
has("#/s/vault/helpdesk", "Aug 27 14:31  <b>error</b>"); has("#/s/vault/helpdesk", "Needs a look"); has("#/s/vault/helpdesk", "Reported by CI"); has("#/logs", "Aug 27", false); has("#/inbox", "still running", false); has("#/s/pcs/a-notifier", "On 24 PCs");
has("#/all", ">Dependency<"); has("#/all", ">Desktop app<"); has("#/all", ">Job<"); has("#/all", "Depends on", false); has("#/all", "1 needs a look"); has("#/all", "2 need a look"); has("#/all", "illustrative", false); has("#/all", ">cron<", false); has("#/all", "0 fine", false); has("#/all", "GB free", false); has("#/all", "Filter by name, version or port"); has("#/m/vault", "Filter by name, version or port"); has("#/m/pcs", "Filter by name or version\""); has("#/m/depends", "Filter by name or address");
has("#/m/press01", "<span class=\"tag bad\">Failed 16:52, tries again 17:52"); has("#/m/press01", "<span class=\"tag warn\">Future-dated row<"); has("#/m/pcs", ">Kind<", false); has("#/m/pcs", ">Desktop app<", false); has("#/m/depends", "<span>Address</span><span>Used by</span>"); has("#/m/vault", "<span>Listens</span>"); has("#/m/depends", "<span class=\"mute\">Morning emailer, Client intake</span>"); has("#/m/depends", ">Kind<", false); has("#/m/pcs", "<span class=\"tag warn\"><i class=\"ph ph-clock-countdown\"");
has("#/m/vault", "hard-drives\" aria-hidden=\"true\"></i>vault "); has("#/m/pcs", "held</span>"); has("#/m/pcs", "4.1.2</span> behind</span>"); has("#/m/pcs", "33 seen this week, 24 reporting now"); has("#/m/pcs", "lvl away"); has("#/m/vault", "<dt>Enrolled</dt>"); has("#/m/vault", "DSM"); has("#/m/depends", "db01.brightwater.example:5432"); has("#/m/depends", "Add a check</button>"); has("#/all", "db01.", false); has("#/m/pcs", ">None<", false);
has("#/s/outside/relay", "Right now"); has("#/s/intake/intake-portal", "Right now"); has("#/s/outside/relay", "n/a"); has("#/s/outside/relay", "~", false); has("#/s/outside/relay", "<b>43</b>"); has("#/s/outside/relay", "Routewise calls", false); has("#/s/outside/relay", "Routewise API</span><span class=\"mono r\">206<"); has("#/s/outside/relay", "214 requests, 206 of them"); has("#/s/outside/relay", "<span class=\"\">Service</span>"); has("#/s/outside/relay", "<b>3.7%</b><span>Refused or rate limited<"); has("#/s/outside/relay", "Phones hung up", false);
if (!/Right now<\/h2><div class="stats">.*?<\/div><\/div><\/div><div class="card"><h2>What Dokkit knows/.test(show("#/s/outside/relay"))) throw new Error("What Dokkit knows should follow Right now");
if (!/Response time, last 24 days, \d+ to \d+ ms</.test(show("#/s/outside/relay"))) throw new Error("the checks card does not state its range"); has("#/s/intake/intake-portal", "Upload folder"); has("#/s/intake/intake-portal", "Working set", false); has("#/s/intake/intake-portal", "39 GB of 228 GB used");
has("#/jobs", "Not watched"); has("#/jobs", "Oct 5 16:52</span><span class=\"tag bad\"><i class=\"ph ph-warning\" aria-hidden=\"true\"></i>Failed"); has("#/jobs", "<span class=\"mono\">Oct 5 15:52</span>"); has("#/jobs", "<span class=\"mono\">Oct 5 17:40</span>", false); has("#/jobs", "height=\"14\"");
if ((show("#/jobs").split("Site scan")[1].split("</svg>")[0].match(/<rect/g) || []).length !== 1) throw new Error("Site scan should draw one bar");
if ((show("#/jobs").split(">Sweeper<")[1].split("</svg>")[0].match(/<rect/g) || []).length !== 23) throw new Error("Sweeper last ran Oct 4 and should draw no bar for Oct 5");
if (!/"w""w""z"$/.test(show("#/errors").split(">PermissionError<")[1].split("</svg>")[0].match(/"[wz]"/g).join(""))) throw new Error("PermissionError was last seen Oct 4, so its last bar is empty");
has("#/logs", ">Service</span>"); has("#/logs", ">Error</span>"); has("#/logs?s=helpdesk", "Aug 27 14:31"); has("#/logs?s=helpdesk", "value=\"", false); has("#/logs?s=helpdesk", "<a class=\"btn\" href=\"#/logs\" aria-label=\"Clear the service filter\">Helpdesk <i class=\"ph ph-x\""); has("#/logs", "Clear the service filter", false); has("#/logs?s=proofs", "<div class=\"foot\">The last 5 runs.</div>"); has("#/logs?s=site-scan", "The last 3 runs."); has("#/logs?s=helpdesk", "The last ", false); has("#/logs?s=offsite", "The last ", false); has("#/logs", "The last ", false); has("#/logs?s=helpdesk", ">Mail links</a>", false); has("#/logs", "n/a", false); has("#/s/vault/helpdesk", "<rect class=\"w\"", false);
if (show("#/inbox").split("Helpdesk deploy")[1].split("</svg>")[0].indexOf("<rect class=\"w\"") >= 0) throw new Error("the helpdesk failures are older than its sparkline");
if ((show("#/inbox").split("Proof staging failed")[1].split("</svg>")[0].match(/<rect class="b"/g) || []).length !== 1) throw new Error("the proof staging sparkline should mark one failed run"); has("#/logs", "Oct 5 17:46"); has("#/logs", "Today"); has("#/deploys", "All time"); has("#/deploys", "Aug 27 14:31"); has("#/deploys", "ph-warning"); has("#/deploys", "build Sep 22<i"); has("#/deploys", ">5 PCs<"); has("#/errors", "<div class=\"ti\"><i class=\"ph ph-bug\""); has("#/errors", "lvl warn", false); has("#/e/e1", "<h1 tabindex=\"-1\"><i class=\"ph ph-bug\"");
has("#/errors", "are not sending errors yet."); has("#/errors", "Show addresses"); has("#/errors", "Caught by the app"); has("#/e/e1", "<dt>Caught</dt>"); has("#/found", "aria-label=\"Open\""); has("#/found", "until you say so."); has("#/found", ">Dismiss selected</button>"); has("#/e/e1", "<span class=\"tag \">14 reports</span>"); has("#/s/vault/keyring", "<span class=\"mute\">Nobody</span>"); has("#/settings", "<span class=\"mute\">None</span>");
has("#/versions", "Empty: not installed there"); has("#/versions", "<tr class=\"flat\"><th scope=\"row\">Dokkit<"); has("#/alerts", "A notification on your phone"); has("#/alerts", "Everything that can wait, in one mail."); has("#/alerts", "inp sm", false); has("#/alerts", ">Page, all owners<", false); has("#/alerts", "First failure"); has("#/alerts", "type=\"time\"", false); has("#/alerts", "<option selected>07:00"); has("#/alerts", "Memory on vault above 90%"); has("#/alerts", ">Who<", false); has("#/alerts", "gpu01 down"); has("#/alerts", "Database unreachable", false); has("#/alerts", "ops@brightwater.example"); has("#/alerts", "555-0142"); has("#/alerts", "spiked past 90% 6 times"); has("#/alerts", "Suggestions<span class=\"cnt\">2</span>"); has("#/tasks", "Recent runs<span class=\"cnt\">4</span>"); has("#/tasks", "class=\"run\" open", false); has("#/tasks", "<span>Started</span><span>Result</span><span class=\"r\">Took</span><span class=\"r\">Exit code</span>"); has("#/settings", "People<span class=\"cnt\">1</span>"); has("#/settings", "Client intake sends errors with it."); has("#/versions", ">PCs</span>"); has("#/settings", "The mark", false); has("#/settings", "Appearance"); has("#/settings", "dka_e05b"); has("#/settings", "intake reports with it"); has("#/settings", "Last heartbeat sent"); has("#/settings", "Add person"); has("#/settings", "smudge", false); has("#/settings", "sw t-dark d-slate");
if ((show("#/e/e1").match(/<rect class="w"/g) || []).length !== 10) throw new Error("the error chart and its sparkline disagree");
for (var i = run("NOW.length"); i--;) run("snooze(" + i + ")");
if (show("#/inbox").indexOf("Nothing needs you") < 0) throw new Error("snooze did not empty the inbox");
if (!/<h1[^>]*><span class="lvl "/.test(show("#/s/vault/helpdesk"))) throw new Error("a snoozed service still has a warning marker in its title");
has("#/inbox", "class=\"q\"", false); has("#/inbox", "need a look", false); has("#/all", ">Snoozed<");
vm.runInContext("watch('offsite')", ctx);
if (show("#/s/vault/offsite").indexOf("Add a check") >= 0) throw new Error("watch did not take");
vm.runInContext("setTheme('dark')", ctx);
if (!/\bt-dark\b/.test(ctx.document.documentElement.className)) throw new Error("theme did not switch");
vm.runInContext("setLook('base', 'plum'); setLook('accent', 'orange')", ctx);
if (ctx.document.documentElement.className !== "t-dark d-plum a-orange") throw new Error("look classes wrong: " + ctx.document.documentElement.className);
if (show("#/inbox").indexOf("viewBox=\"0 0 100 100\"") < 0) throw new Error("logo missing from the sidebar");
has("#/inbox", 'href="#/found"'); has("#/s/web01/night-backup", "61 MB"); has("#/s/web01/night-backup", "Next expected"); has("#/jobs", "Last good run");
has("#/m/pcs", "desk-36"); has("#/versions", "desk-36 1.4.2 held"); has("#/versions", "desk-47 4.1.2 behind"); has("#/versions", "build Jun 3"); has("#/tasks", "Oct 4 23:40"); has("#/tasks", "no answer on :8610"); has("#/s/outside/relay", "Devices with errors"); has("#/s/intake/intake-portal", "Work queue"); has("#/s/vault/helpdesk", "build</span>", false);
has("#/errors", "dka_", false); run("flip('addr')"); has("#/errors", "dka_"); has("#/errors", "Hide addresses"); has("#/errors", ">Copy</button>", false); has("#/errors", "https://dka_7c2f…@<wbr>dokkit.brightwater.example<wbr>/relay<"); has("#/errors", "dka_e05b…@"); has("#/errors", "The key was shown once, when it was made."); if (/dka_[a-z0-9]{5}/.test(show("#/errors"))) throw new Error("Errors prints more of a key than Settings does");
has("#/e/e1", "sqlalchemy", false); run("toggleLib('e1')"); has("#/e/e1", "sqlalchemy"); has("#/e/e1", "2.1.0 went out Sep 26"); has("#/e/e1", "<dt>Machine</dt>"); has("#/e/e3", "<dt>Machines</dt>"); has("#/e/e1", ">App</span>"); has("#/e/e1", "<a href=\"#/m/pcs\">desk-53</a>"); has("#/e/e1", "#/logs?s=a-rush");
if ((show("#/e/e1").match(/<text text-anchor="middle"[^>]*>\d+</g) || []).reduce(function (a, t) { return a + +t.match(/>(\d+)</)[1]; }, 0) !== 14) throw new Error("the counts over the bars do not add up to the reports");
run("snooze('e1')"); has("#/e/e1", ">Snoozed<"); has("#/e/e2", ">Snoozed<", false);
run("pick('p7300'); sweep(watched); pick('daily-report'); sweep(dismissed)");
has("#/found", "Nothing claims it", false); has("#/found", "No repo and no log", false); has("#/found", "Page count alert"); has("#/found", "Select all"); has("#/found", "data-some", false); run("pick('page-count-alert')"); has("#/found", "data-some onchange=\"pickAll"); run("pickAll(true)"); has("#/found", "Watch selected</button>"); has("#/found", " disabled", false); has("#/found", "data-some", false); run("pickAll(false)");
run("acceptTask('restart-loghouse'); dismissTask('clear-intake-scratch')");
has("#/found", "No task is waiting"); has("#/tasks", "docker restart loghouse"); has("#/tasks", "intake-clean", false);
run("runTask('restart-loghouse')"); has("#/tasks", "Just now");
has("#/alerts", "Close", false); run("flip('edit')"); has("#/alerts", "Save rule"); has("#/alerts", ">Close<", false); has("#/alerts", ">Cancel<"); has("#/alerts", "Alerts after"); has("#/alerts", "New rule</button>", false); run("draft.what = 'Loghouse'; draft.ch = 'Text'; draft.who = 'All owners'; saveRule()"); has("#/alerts", "Loghouse down"); has("#/alerts", ">Text, all owners<"); has("#/alerts", "Save rule", false);
run("settle(1, 1)"); if (run("RULES[7].ch") !== "Push") throw new Error("accepting a suggestion changed nothing");
run("settle(0)"); has("#/alerts", "No suggestions right now"); if (run("METERS['vault'][0][2]") !== 90) throw new Error("a dismissed suggestion changed a limit");
has("#/settings", "Shown once", false); run("keyKind = 'User token'; makeKey()"); has("#/settings", "Shown once"); if (!/>dku_[a-z0-9]{20}</.test(show("#/settings"))) throw new Error("no full key shown"); if (!/class="once">.*?>Copy<\/button><\/div>/.test(show("#/settings"))) throw new Error("the new key has no Copy button");
has("#/inbox", "Dokkit"); has("#/settings", "Shown once", false);
run("revokeKey(0)"); has("#/settings", "New, not used yet", false);
run("rt('loghouse').down = 'Email'; rt('loghouse').restart = true"); has("#/s/vault/loghouse", "<option selected>Email"); has("#/s/vault/loghouse", 'type="checkbox" checked onchange="rt(');
// states opened from the address
boot("?ui=sel,picked,frames,run,newkey,snoozed,allowner,sx", "#/settings");
if (run("ui.sx") !== true) throw new Error("ui=sx was not read from the address");
has("#/settings", "Shown once"); has("#/inbox", "disabled onclick=\"snooze()\"", false); has("#/alerts", ">Page, all owners<");
if ((show("#/inbox").match(/checked onchange="tickOne/g) || []).length !== 2) throw new Error("ui=sel should tick two rows");
if ((show("#/found").match(/checked onchange="pick\(/g) || []).length !== 2) throw new Error("ui=picked should tick two rows"); has("#/found", " disabled", false);
has("#/e/e1", "sqlalchemy"); has("#/e/e1", ">Snoozed<"); has("#/s/vault/helpdesk", ">Snoozed<"); has("#/s/vault/keyring", ">Snoozed<", false);
if ((show("#/tasks").match(/class="run" open/g) || []).length !== 1) throw new Error("ui=run should open the first run");
boot("?ui=selall", "#/inbox");
if ((show("#/inbox").match(/checked onchange="tickOne/g) || []).length !== 6) throw new Error("ui=selall should tick every row"); has("#/inbox", "checked onchange=\"tickAll"); has("#/inbox", "data-some", false); has("#/inbox", "disabled onclick=\"snooze()\"", false);
boot("?ui=empty,watched,accepted,q", "#/inbox");
routes.forEach(show);
has("#/inbox", "Nothing needs you, and Dokkit will tell you when something does."); has("#/inbox", "<span class=\"n\">", false); has("#/inbox", "class=\"q\"", false); has("#/inbox", "Needs you</button>"); has("#/inbox", "Select all", false); has("#/inbox", "60 watched, 0 not"); has("#/inbox", "value=\"relay\"", false);
run("setTab('found')"); has("#/inbox", "Everything Dokkit has found is being watched."); has("#/inbox", "Not watched</button>"); has("#/inbox", "Review what was found", false); run("setTab('now')");
has("#/found", "Everything found is either watched or dismissed."); has("#/found", "No task is waiting to be accepted."); has("#/found", "class=\"cnt\"", false); has("#/found", "Watch selected", false); has("#/tasks", "docker restart loghouse"); has("#/tasks", "waiting to be accepted", false);
has("#/alerts", "No suggestions right now."); has("#/alerts", "Suggestions</h2>"); has("#/alerts", "Memory on vault above 92%"); has("#/alerts", "above 90%", false); has("#/alerts", ">Push, ntfy<");
has("#/all", "value=\"relay\""); has("#/all", "<span>Courier app relay</span>"); has("#/all", "<span>Mail relay</span>"); has("#/all", "Loghouse", false); has("#/all", "1 fine"); has("#/all", "3 fine", false); has("#/all", "need a look", false); has("#/m/vault", "Nothing here matches."); has("#/m/depends", "Mail relay"); has("#/m/depends", "Filedrop", false);
has("#/logs", "value=\"relay\""); has("#/logs", "No log lines match."); has("#/logs?s=helpdesk", "value=\"", false); has("#/logs?s=helpdesk", "Clear the service filter"); has("#/logs?s=helpdesk", "Aug 27 14:31"); has("#/jobs", "value=\"relay\"", false);
has("#/inbox", "Snooze selected", false); has("#/found", "<h1 tabindex=\"-1\">Found</h1>"); has("#/found", "until you say so", false);
if (!/class="grp bare">.*class="vit.*Nothing here matches\./.test(show("#/m/vault"))) throw new Error("a machine filtered to nothing should keep its meters");
run("setTab('soon')"); has("#/inbox", "At this rate it crosses 92% in about 18 days."); has("#/inbox", "of 92% limit"); has("#/inbox", "90%", false); run("setTab('now')");
// a band's marker follows the rows the filter leaves
boot("?ui=q", "#/all");
var band = "<a href=\"#/m/outside\" style=\"display:flex; align-items:center; gap:8px\"><span class=\"lvl ";
has("#/all", band + "\" role"); has("#/all", band + "warn", false); has("#/all", "<span class=\"lvl warn\"", false); has("#/all", band.replace("outside", "depends") + "none");
// Logs and the job pages print the same runs
boot();
function count(html, text) { return html.split(text).length - 1; }
var logs = show("#/logs"), today = 0;
run("Object.keys(JOBS)").forEach(function (id) {
  var p = run("svc('" + id + "')"), box = show("#/s/" + p[0].id + "/" + id).split("Latest logs")[1], mine = show("#/logs?s=" + id), got = 0;
  (box.match(/[A-Z][a-z]{2} \d+ \d\d:\d\d  <(b|em)>.*/g) || []).forEach(function (l) {
    var at = l.split("  ")[0], msg = l.split("  ")[2].replace(/<\/span>.*/, ""), row = at + "</span><span class=\"tag " + (/<b>/.test(l) ? "bad\">Error" : "\">Info") + "</span><span class=\"tag \">" + p[0].name + "</span><a href=\"#/s/" + p[0].id + "/" + id + "\">" + p[1].name + "</a><span>" + msg + "</span>";
    if (count(mine, row) !== 1) throw new Error("Logs for " + id + " should show its " + at + " run once");
    // today, a job's latest finished run and each failed one
    var want = /^Oct 5 /.test(at) && (/<b>/.test(l) || !got++) ? 1 : 0;
    if (count(logs, row) !== want) throw new Error("Logs should show " + id + " " + at + " " + want + " times");
    today += want;
  });
  if (count(mine, "class=\"li slim cols-logs\"") !== run("JOBS['" + id + "'].at.length")) throw new Error("Logs for " + id + " should have one row for each run");
});
if (today !== 9 || count(logs, "class=\"li slim cols-logs\"") !== 18) throw new Error("Logs should have 18 rows today, 9 of them runs");
var times = logs.match(/Oct 5 \d\d:\d\d<\/span><span class="tag/g);
if (times.length !== 18 || times.join() !== times.slice().sort().reverse().join()) throw new Error("Logs should run newest first");
if (count(logs, "Oct 5 16:52") !== 1 || count(logs, "Finished in 1 s") !== 1) throw new Error("Logs should show the 16:52 failure once and one line for the watchdog");
// a run's note agrees with how long the run took
[["web01/night-backup", "Oct 5 02:20", "59 s", ", 61 MB"], ["web01/updater", "Oct 5 02:05", "21 s", ", no restart needed"]].forEach(function (x) {
  has("#/s/" + x[0], x[1] + "</span><span class=\"tag \">Finished</span><span class=\"mono r\">" + x[2] + "<"); has("#/s/" + x[0], x[1] + "  <em>info </em>  Finished in " + x[2] + x[3] + "</span>");
  if (count(logs, "<span>Finished in " + x[2] + x[3] + "</span>") !== 1) throw new Error("Logs should carry the note for " + x[0]);
});
has("#/m/pcs", ">2 reports<"); has("#/s/pcs/a-proof", ">2 reports<");
has("#/inbox", "<a href=\"#/logs\">Errors today</a><span class=\"cnt\">3</span>"); if (count(show("#/inbox"), "class=\"msg\"") !== 3) throw new Error("Errors today should have three entries");
has("#/s/pcs/a-rush", "Oct 5 15:22  <b>error</b>  Poll cycle failed"); has("#/s/press02/ocr", "Oct 5 10:05  <em>info </em>  Started");
// under 1100 px the inbox filter is named shortly while Snooze selected shares its row
ctx.matchMedia = function () { return { matches: true }; };
has("#/inbox", "placeholder=\"Filter issues\""); run("setTab('soon')"); has("#/inbox", "placeholder=\"Filter issues, services and machines\""); run("setTab('now')");
delete ctx.matchMedia;
console.log("ok: " + n + " renders across " + routes.length + " routes, actions pass");
