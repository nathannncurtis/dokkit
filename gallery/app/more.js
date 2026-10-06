var HOST = "dokkit.brightwater.example", PC = "desk-";
var CHANNELS = ["Page", "Push", "Email", "Text", "Digest", "Webhook"];
// what a rule watches for, and how its name ends
var WHEN = { Stops: "down", Degrades: "degraded", "Runs late": "late", "Passes a threshold": "over its limit" };

// frames are innermost last; the fourth value says the frame is the app's own code.
var ERRS = [
  { id: "e1", type: "OperationalError", s: "a-rush", rel: "2.1.0", state: "warn", bad: 10, n: 14, first: "Sep 26 08:12", last: "Oct 5 15:22", pcs: ["desk-53"], handled: true, dep: "2.1.0 went out Sep 26", tags: [["step", "poll"], ["database", "sql"]],
    frames: [["threading.py", "run", 1012, 0], ["tracker/runner.py", "loop", 61, 1], ["tracker/poll.py", "poll_cycle", 88, 1], ["tracker/db.py", "open_rows", 34, 1], ["site-packages/sqlalchemy/engine/base.py", "connect", 3276, 0], ["site-packages/sqlalchemy/pool/impl.py", "checkout", 177, 0]] },
  { id: "e2", type: "KeyError", s: "a-proof", rel: "4.1.3", state: "warn", bad: 5, n: 9, first: "Oct 1 10:02", last: "Oct 5 12:14", pcs: ["desk-23"], handled: true, dep: "4.1.3 went out Oct 1", tags: [["step", "ingest"]],
    frames: [["concurrent/futures/thread.py", "run", 58, 0], ["engine/queue.py", "next_file", 73, 1], ["engine/ingest.py", "read_proof", 141, 1], ["site-packages/PIL/Image.py", "open", 3431, 0]] },
  { id: "e3", type: "PermissionError", s: "a-finder", rel: "3.08", state: "warn", bad: 2, n: 3, first: "Oct 3 09:40", last: "Oct 4 14:05", pcs: ["desk-35", "desk-44"], handled: false, dep: "", tags: [["step", "open"]],
    frames: [["tray/app.py", "on_click", 118, 1], ["tray/open_result.py", "open_folder", 52, 1], ["subprocess.py", "Popen", 1026, 0], ["subprocess.py", "_execute_child", 1538, 0]] }
];

var HOW = { offsite: "Scheduled task", "page-count-alert": "Running service", "daily-report": "Running service", p7300: "Listening port" };
var TASKS = [
  { id: "restart-infer", name: "Restart infer", m: "gpu01", cmd: "systemctl restart infer", acct: "root", ok: true, dur: 9, out: "Stopping infer.service\nStarted infer.service\nhealth 200 on :8610" },
  { id: "rebuild-job-index", name: "Rebuild job index", m: "press01", cmd: "python -m job_finder.rebuild --full", acct: "LocalService", ok: true, dur: 412, out: "reading the share\nindexed 39,406 folders\nswapped the index in" },
  { id: "restart-loghouse", name: "Restart loghouse", m: "vault", cmd: "docker restart loghouse", acct: "admin", ok: false, dur: 6, out: "loghouse\nhealth 200 on :5380" },
  { id: "clear-intake-scratch", name: "Clear intake scratch", m: "intake", cmd: "/usr/local/bin/intake-clean --older-than 7d", acct: "intake", ok: false, dur: 3, out: "removed 14 files, 2.1 GB" }
];
var RUNS = [
  { t: "restart-infer", at: "Oct 5 06:12", code: 0, dur: 9 },
  { t: "restart-infer", at: "Oct 4 23:40", code: 1, dur: 31, out: "Stopping infer.service\nStarted infer.service\nno answer on :8610 after 30 s\nstopped with exit code 1" },
  { t: "rebuild-job-index", at: "Sep 28 10:02", code: 0, dur: 398 },
  { t: "rebuild-job-index", at: "Sep 14 09:15", code: 0, dur: 405 }
];

var DAYS = ["Oct 5", "Oct 4", "Oct 3", "Oct 2", "Oct 1", "Sep 30"];
function daily(t, skip) { return DAYS.slice(skip || 0, (skip || 0) + 5).map(function (d) { return d + " " + t; }); }
// notes: a run's log line when it says more than how long it took, in the order of at
var JOBS = {
  "mail-links": { sch: "Every day at 01:10", next: "Oct 6 01:10", dur: 4, at: daily("01:10"), tail: "linked 187 messages\n0 skipped\ndone" },
  offsite: { sch: "Every day at 03:30", next: "Oct 6 03:30", dur: 0, at: [], tail: "" },
  proofs: { sch: "Every hour", next: "Oct 5 17:52", dur: 41, fail: 0, at: ["Oct 5 16:52", "Oct 5 15:52", "Oct 5 14:52", "Oct 5 13:52", "Oct 5 12:52"], tail: "staged 6 folders\nnothing to retry\ndone" },
  morning: { sch: "Every day at 07:15", next: "Oct 6 07:15", dur: 12, at: daily("07:15"), tail: "1 message built\nsent\ndone" },
  sweeper: { sch: "Every day at 19:30", next: "Oct 5 19:30", dur: 95, at: daily("19:30", 1), fail: 3, tail: "scanned the work folders\nremoved 284 files\ndone" },
  finder: { sch: "Every day at 22:05", next: "Oct 5 22:05", dur: 380, at: daily("22:05", 1), tail: "reading the share\nindexed 39,406 folders\nswapped the index in" },
  rates: { sch: "Every day at 02:40", next: "Oct 6 02:40", dur: 71, at: daily("02:40"), tail: "pulled the table\nwrote 962 rows\ndone" },
  "infer-watch": { sch: "Every 5 minutes", next: "Oct 5 17:50", dur: 1, at: ["Oct 5 17:45", "Oct 5 17:40", "Oct 5 17:35", "Oct 5 17:30", "Oct 5 17:25"], tail: "infer answered 200 on :8610\nnothing to do" },
  "sorter-restart": { sch: "Every day at 03:45", next: "Oct 6 03:45", dur: 22, at: daily("03:45"), tail: "Stopping sorter.service\nStarted sorter.service\nhealth 200 on :8450" },
  "night-backup": { sch: "Every day at 02:20", next: "Oct 6 02:20", dur: 48, at: daily("02:20"), notes: ["Finished in 59 s, 61 MB"], tail: "dumped the database\npacked the pages folder\nNight backup finished, 61 MB" },
  updater: { sch: "Every day at 02:05", next: "Oct 6 02:05", dur: 17, at: daily("02:05"), notes: ["Finished in 21 s, no restart needed"], tail: "checked for a newer image\nImage updater ran, no restart needed" },
  "site-scan": { sch: "Every quarter", days: [19], next: "Jan 1 03:00", dur: 1260, at: ["Oct 1 03:00", "Jul 1 03:00", "Apr 1 03:00"], tail: "scanned 4 public addresses\n0 new findings\nreport saved" }
};

// machine id, service id, from, to, where it landed, when, how it was seen, failed
var DEPLOYS = [
  ["press01", "finishing", "r405", "r412", "press01", "Oct 5 09:12", "auto"],
  ["outside", "relay", "3.4.0", "3.4.1", "Outside", "Oct 3 14:20", "ci"],
  ["pcs", "a-proof", "4.1.2", "4.1.3", "5 PCs", "Oct 1 08:55", "auto"],
  ["web01", "wiki", "Sep 22", "Sep 29", "web01", "Sep 29 02:05", "auto"],
  ["pcs", "a-rush", "1.4.2", "2.1.0", "desk-53", "Sep 26 08:05", "auto"],
  ["vault", "helpdesk", "Jun 3", "Aug 27", "vault", "Aug 27 14:31", "ci", 1],
  ["vault", "helpdesk", "Jun 3", "Jul 16", "vault", "Jul 16 10:47", "ci", 1],
  ["vault", "helpdesk", "May 20", "Jun 3", "vault", "Jun 3 16:08", "ci"]
];

var SELFV = { newest: "0.1.0", on: { vault: "0.1.0", press01: "0.1.0", press02: "0.1.0", gpu01: "0.1.0", web01: "0.0.9", intake: "0.1.0" } };
var PCN = [11, 12, 14, 15, 17, 18, 19, 21, 22, 23, 25, 26, 28, 29, 31, 32, 34, 35, 36, 38, 39, 41, 42, 44, 45, 47, 48, 51, 52, 53, 55, 56, 58];
var QUIET = { 14: "Oct 2", 18: "Oct 4", 21: "Oct 1", 25: "Oct 3", 28: "Oct 4", 31: "Oct 2", 38: "Oct 3", 42: "Oct 1", 48: "Oct 4" };
var ON = {
  "a-proof": { 23: "4.1.3", 12: "4.1.3", 17: "4.1.3", 29: "4.1.3", 39: "4.1.3", 47: "4.1.2" },
  "a-finder": { 53: "3.08", 35: "3.08", 44: "3.08", 15: "3.08" },
  "a-clerk": { 19: "2.6.1", 32: "2.6.1", 45: "2.6.1" },
  "a-quote": { 26: "1.14", 41: "1.14" },
  "a-rush": { 53: "2.1.0", 36: "1.4.2" },
  "a-plate": { 34: "1.2.2" },
  "a-scan": { 11: "1.3.7" }
};
var HELD = { "a-rush": { 36: 1 } };

var RULES = WAKE.map(function (w) { return { name: w[0], ch: w[1] ? "Page" : "Digest", who: "Me", after: /job|deploy|desktop/.test(w[0]) ? "First failure" : "3 failed checks", on: true }; });
RULES.push({ name: "Memory on vault above 90%", ch: "Page", who: "Me", after: "5 minutes", on: true });
var SUGG = [
  { text: "Memory on vault spiked past 90% 6 times in September and each page was snoozed. Raise the limit to 92%?", go: function () { METERS.vault[0][2] = 92; RULES[8].name = "Memory on vault above 92%"; Object.assign(SOON[0], { limit: "92%", days: 18, say: "At this rate it crosses 92% in about 18 days." }); } },
  { text: "The rule for one person's desktop app failing went into 9 digests and none was opened. Send it by Push?", go: function () { RULES[7].ch = "Push"; } }
];

var STATS = {
  relay: {
    top: [["Requests a minute", "43"], ["Refused or rate limited", "3.7%"], ["p95 response", "50 ms"], ["Abandoned", "0"]],
    upstream: [["Routewise API", 206, 0, "25 ms", "50 ms", 0, 0], ["Schedules", 16, 0, "10 ms", "25 ms", 0, 0], ["Database server", 47, 0, "5 ms", "10 ms", "", 0], ["Session check", 214, 0, "5 ms", "5 ms", "", ""]],
    failing: [["Van phone 12", "3f9a1c", "C112", 14, 3, 3, 0, "17:44"], ["Van phone 31", "b07d42", "C087", 31, 5, 0, 5, "17:41"]]
  },
  "intake-portal": {
    top: [["Uploads in progress", "3"], ["Waiting for a scan", "4"], ["Scanning now", "1"], ["Oldest waiting", "38 s"]],
    queue: [["Scan a file", 4], ["Finish an order", 1], ["Send an email", 0], ["Render a quarantined file", 0]],
    fail: [["Files failed", "0"], ["Quarantined", "1"], ["Notes failed", "0"], ["Renders failed", "0"]],
    disk: [["System disk", "39 GB of 228 GB used"], ["Upload folder", "6.4 GB in 212 files"]]
  }
};

var KINDS = [["Enrolment token", "dke_"], ["Machine key", "dkm_"], ["App key", "dka_"], ["User token", "dku_"]];
var KEYS = [
  { kind: "Enrolment token", key: "dke_9fk2", use: "Puts Dokkit on one new machine, then it is spent.", last: "Never" },
  { kind: "Machine key", key: "dkm_m8rw", use: "vault reports with it.", last: "Oct 5 17:46" },
  { kind: "Machine key", key: "dkm_c3hn", use: "press01 reports with it.", last: "Oct 5 17:46" },
  { kind: "Machine key", key: "dkm_x7pd", use: "press02 reports with it.", last: "Oct 5 17:46" },
  { kind: "Machine key", key: "dkm_4tqx", use: "gpu01 reports with it.", last: "Oct 5 17:46" },
  { kind: "Machine key", key: "dkm_j2vs", use: "web01 reports with it.", last: "Oct 5 17:46" },
  { kind: "Machine key", key: "dkm_n6ka", use: "intake reports with it.", last: "Oct 5 17:46" },
  { kind: "App key", key: "dka_3b8e", use: "Rush Tracker sends errors with it.", last: "Oct 5 15:22" },
  { kind: "App key", key: "dka_a41d", use: "Proof Viewer sends errors with it.", last: "Oct 5 12:14" },
  { kind: "App key", key: "dka_6f07", use: "Job Finder Tray sends errors with it.", last: "Oct 4 14:05" },
  { kind: "App key", key: "dka_7c2f", use: "Courier app relay sends errors with it.", last: "Never" },
  { kind: "App key", key: "dka_e05b", use: "Client intake sends errors with it.", last: "Never" },
  { kind: "User token", key: "dku_b81e", use: "Scripts and AI tools.", last: "Oct 5 16:02" }
];
var SELF = [["Taking reports", "Yes, the last one came at 17:46"], ["Database size", "1.4 GB"], ["Archives waiting to upload", '<span class="mute">None</span>'], ["Outside heartbeat", '<span class="mono">https://heartbeat.example/ping/dokkit</span>'], ["Last heartbeat sent", "17:45, answered 200"]];
