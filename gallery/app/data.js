// An invented company's estate, for the demo. state: ok | warn | none (found, nothing watching it yet)
var ORG = "Brightwater", ME = "sysop";
var S = function (id, name, state, note, ver, extra) { return Object.assign({ id: id, name: name, state: state, note: note || "", ver: ver || "" }, extra || {}); };

var MACHINES = [
  { id: "vault", name: "vault", kind: "DSM", addr: "10.20.0.5", since: "Jul 8",
    services: [
      S("loghouse", "Loghouse", "warn", "Health check failing since Aug 8", "4.2", { bad: 24, where: ":5380", lead: "Loghouse is answering. Its health check calls wget, which is not in the image, so the check has failed since Aug 8.", facts: [["Answering", "200 on :5380", "ok"], ["Health check", "167,040 failures in a row", "warn"], ["Container", "Up 8 weeks"], ["Stored", "2.3 GB"]], act: "Replace the check" }),
      S("helpdesk", "Helpdesk", "warn", "Deploy failing since Jul 16", "Jun 3", { ms: 55, where: ":9440", lead: "Nothing is down. The container that is running is an older build, so anything merged since June has not shipped.", facts: [["Last good deploy", "Jun 3"], ["Failed deploys", "Jul 16 and Aug 27"], ["Running now", '<span><span class="mono">build Jun 3</span>, healthy</span>', "ok"], ["Health", "200 on /healthz", "ok"]], act: "Open the failed deploy" }),
      S("pushhub", "Push hub", "ok", "24 PCs reporting", "latest", { ms: 6, where: ":8790" }),
      S("keyring", "Keyring", "ok", "App and database up", "", { ms: 14, where: ":9020" }),
      S("mail-links", "Mail links", "ok", "Ran 01:10", "cron"),
      S("offsite", "Offsite backup", "none", "No run seen yet", "cron")
    ] },
  { id: "press01", name: "press01", kind: "Windows", addr: "10.20.0.21", since: "Jul 8",
    services: [
      S("finishing", "Finishing", "warn", "Future-dated rows", "r412", { ms: 38, bad: 1, where: ":7150", lead: "The page is up and ingesting. Rows dated 2028 and 3104 pin its last-seen fields, so it cannot show when it goes stale.", facts: [["Ingest", "Ticking every 5 minutes", "ok"], ["Last credit", "2028-03-11", "warn"], ["Last note", "3104-06-02", "warn"]], act: "See the rows" }),
      S("carrier-feeds", "Carrier feeds", "warn", "Future-dated row", "", { bad: 6, where: ":7140", lead: "The page is up. A row dated 2031 pins its last-sent field.", facts: [["Ingest", "Ticking every 10 minutes", "ok"], ["Last sent", "2031-01-17", "warn"]], act: "See the rows" }),
      S("claims", "Job ticket claims", "ok", "17 workers attached", "", { where: ":7077" }),
      S("ledger", "Postage ledger", "ok", "", "", { where: ":7090" }),
      S("proofs", "Proof staging", "warn", "Failed 16:52, tries again 17:52", "", { lead: "The 16:52 run stopped with exit code 1. The four runs before it finished, and the next one is due at 17:52.", act: "Open the failed run" }),
      S("labels", "Sheet labels", "ok", "", "", { where: ":7120" }),
      S("orders", "Orders web", "ok", "", "", { where: ":7130" }),
      S("frontdoor", "Front door", "ok", "", "", { where: ":80" }),
      S("inserter", "Insert mailer", "ok"), S("preflight", "Preflight", "ok"), S("zebra", "Zebra labels", "ok"), S("brother", "Brother labels", "ok"), S("disc", "Disc labels", "ok"),
      S("morning", "Morning emailer", "ok", "Ran 07:15"), S("sweeper", "Sweeper", "ok", "Ran Oct 4 19:30"), S("finder", "Job Finder", "ok", "Ran Oct 4 22:05"), S("rush", "Rush runner", "ok"), S("courier", "Courier drop", "ok", "Shadow mode"),
      S("page-count-alert", "Page count alert", "none", "No repo. Last log Aug 21"), S("daily-report", "Daily report", "none", "No repo and no log"), S("p7300", "Unclaimed port", "none", "Answers 200. Nothing claims it", "", { where: ":7300", kind: "Port" })
    ] },
  { id: "press02", name: "press02", kind: "Windows", addr: "10.20.0.22", since: "Jul 9",
    services: [S("render", "Render workers", "ok", "17 running"), S("ocr", "OCR reader", "ok", "", "", { where: ":7078" }), S("rates", "Rate table", "ok", "Ran 02:40", "task"), S("shelf", "Shelf watcher", "ok", "", "", { where: ":7484" })] },
  { id: "gpu01", name: "gpu01", kind: "Linux", addr: "10.20.0.31", since: "Jul 14",
    services: [S("infer", "Infer", "ok", "Crash looped Oct 4, back since Oct 5", "", { ms: 140, where: ":8610", bad: 1 }), S("sorter", "Sorter", "ok", "", "", { where: ":8450" }), S("date-reader", "Date reader", "ok", "", "", { where: ":8452" }), S("infer-watch", "Infer watchdog", "ok", "Ran 17:45", "timer"), S("sorter-restart", "Sorter restart", "ok", "Ran 03:45", "timer")] },
  { id: "web01", name: "web01", kind: "Linux", addr: "10.20.0.41", since: "Jul 21",
    services: [S("wiki", "Staff wiki", "ok", "2 replicas", "Sep 29", { ms: 31 }), S("gateway", "Gateway", "ok"), S("uptime", "Uptime ping", "ok"), S("night-backup", "Night backup", "ok", "Ran 02:20", "timer"), S("updater", "Image updater", "ok", "Ran 02:05", "timer")] },
  { id: "intake", name: "intake", kind: "macOS", addr: "10.20.0.51", since: "Sep 29",
    services: [S("intake-portal", "Client intake", "ok", "Checked on the LAN address", "", { ms: 12, where: ":443" }), S("local-model", "Local model", "ok")] },
  { id: "outside", name: "Outside", kind: "Hosted elsewhere",
    services: [
      S("relay", "Courier app relay", "ok", "Health 200", "3.4.1", { where: ":443", lead: "Sits between the couriers' phones and the Routewise API. The numbers are from a test burst of 214 requests, 206 of them passed on to Routewise.", facts: [["Certificate", "Renews Oct 19"]] }),
      S("intake-dns", "Intake public address", "warn", "Does not resolve on office DNS", "", { bad: 1, where: "intake.brightwater.example", lead: "The intake page answers on its LAN address. The public name does not resolve from the office, and no release tag has been cut yet.", facts: [["Office DNS", "No such name", "warn"], ["LAN address", "200", "ok"]], act: "Open the intake page" }),
      S("site-scan", "Site scan", "ok", "Ran Oct 1 03:00", "quarterly"), S("licence-seeder", "Licence seeder", "ok")
    ] },
  { id: "depends", name: "Dependencies", kind: "Things your services call",
    services: [
      S("db", "Database server", "none", "", "", { where: ":5432", addr: "db01.brightwater.example:5432", by: ["relay"], facts: [["Calls", "47 from Courier app relay in the last 5 minutes, none failed"]] }),
      S("routewise", "Routewise API", "none", "", "", { where: ":443", addr: "api.routewise.example:443", by: ["relay"], facts: [["Calls", "206 from Courier app relay in the last 5 minutes, none failed"]] }),
      S("smtp", "Mail relay", "none", "", "", { where: ":587", addr: "mail.brightwater.example:587", by: ["morning", "intake-portal"] }),
      S("filedrop", "Filedrop", "none", "", "", { where: ":443", addr: "filedrop.example:443", by: ["courier"] }),
      S("power", "Power backup", "none", "", "", { where: ":3493", addr: "ups.brightwater.example:3493", by: ["pushhub"] })
    ] },
  { id: "pcs", name: "Staff PCs", kind: "Desktop apps",
    services: [S("a-notifier", "Brightwater Notifier", "ok", "On 24 PCs", "1.9.0"), S("a-proof", "Proof Viewer", "ok", "On 6 PCs, one behind, 2 reports today", "4.1.3"), S("a-finder", "Job Finder Tray", "ok", "On 4 PCs", "3.08"), S("a-clerk", "Desk Clerk", "ok", "On 3 PCs", "2.6.1"), S("a-quote", "Quote Puller", "ok", "On 2 PCs", "1.14"), S("a-rush", "Rush Tracker", "ok", "On 2 PCs, one held, 2 reports today", "2.1.0"), S("a-plate", "Plate Decoder", "ok", "On 1 PC", "1.2.2"), S("a-scan", "Flatbed Scanner", "ok", "On 1 PC", "1.3.7")] }
];

var NOW = [
  { m: "vault", s: "helpdesk", kind: "Deploy", title: "Helpdesk deploy has failed twice", sub: "An older build is running, so nothing merged since June has shipped.", since: "since Jul 16" },
  { m: "vault", s: "loghouse", kind: "Check", title: "Loghouse answers but its check fails", sub: "It answers on :5380, but the health check calls a tool the image lacks.", since: "since Aug 8" },
  { m: "press01", s: "carrier-feeds", kind: "Data", title: "Carrier feeds cannot flag stale data", sub: "A row dated 2031 pins its last-sent field, so nothing can look stale.", since: "since Sep 30" },
  { m: "outside", s: "intake-dns", kind: "DNS", title: "Intake address fails on office DNS", sub: "The public name does not resolve from the office, but the LAN address answers.", since: "since Oct 5" },
  { m: "press01", s: "finishing", kind: "Data", title: "Finishing cannot flag stale data", sub: "Rows dated 2028 and 3104 pin its last-seen fields, so nothing can look stale.", since: "since Oct 5" },
  { m: "press01", s: "proofs", kind: "Job", title: "Proof staging failed its last run", sub: "The 16:52 run stopped with exit code 1, and the next one is due at 17:52.", since: "since Oct 5" }
];
var SOON = [
  { what: "Memory on vault", now: "88%", limit: "90%", m: "vault", days: 9, say: "At this rate it crosses 90% in about 9 days." },
  { what: "Disk on press02", now: "78%", limit: "85%", m: "press02", days: 21, say: "At this rate it crosses 85% in about 3 weeks." },
  { what: "Data volume on vault", now: "71%", limit: "85%", m: "vault", days: 42, say: "At this rate it crosses 85% in about 6 weeks." }
];

// time, level, machine, message, service id, day when it is not today. A job's lines come from its runs in JOBS.
var LOGS = [
  ["17:46", "info", "vault", "Every health address answered", ""],
  ["16:41", "info", "desk-53", "Search finished", "a-finder"],
  ["15:22", "error", "desk-53", "Poll cycle failed, database connection timed out", "a-rush"],
  ["14:02", "info", "desk-53", "Poll cycle finished", "a-rush"],
  ["13:08", "error", "desk-53", "Poll cycle failed, database connection timed out", "a-rush"],
  ["12:14", "error", "desk-23", "Engine reported a file with no proof id", "a-proof"],
  ["11:50", "info", "desk-23", "Opened 12 proofs", "a-proof"],
  ["11:37", "error", "desk-23", "Engine reported a file with no proof id", "a-proof"],
  ["10:05", "info", "press02", "Started", "ocr"],
  ["14:31", "error", "vault", "Deploy of the Aug 27 build failed, the Jun 3 build is still running", "helpdesk", "Aug 27"],
  ["08:10", "error", "vault", "Health check failed, wget is not in the image", "loghouse", "Aug 8"],
  ["10:47", "error", "vault", "Deploy of the Jul 16 build failed, the Jun 3 build is still running", "helpdesk", "Jul 16"]
];
var WAKE = [["Client intake down", 1], ["Courier app relay down", 1], ["press01 or press02 down", 1], ["vault down", 1], ["gpu01 down", 1], ["A night job failed", 1], ["A deploy failed", 0], ["One person's desktop app keeps failing", 0]];
