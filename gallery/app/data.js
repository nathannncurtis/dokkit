// An invented company's estate, for the demo. state: ok | warn | none (found, nothing watching it yet)
var ORG = "Brightwater", ME = "sysop";
var S = function (id, name, state, note, ver, extra) { return Object.assign({ id: id, name: name, state: state, note: note || "", ver: ver || "" }, extra || {}); };

var MACHINES = [
  { id: "vault", name: "vault", kind: "Synology", chips: [["Memory 88%", 1], ["Data 71%"], ["Up 52 days"]], lines: [["Memory", 90, "%"], ["Data volume", 85, "%"]],
    services: [
      S("loghouse", "loghouse", "warn", "Its health check is wrong", "4.2", { bad: 24, where: ":5380", lead: "Loghouse is answering. Its health check calls wget, which is not in the image, so the check has failed since Aug 8.", facts: [["Answering", "200 on :5380", "ok"], ["Health check", "88,204 failures in a row", "warn"], ["Container", "Up 7 weeks"], ["Stored", "2.3 GB"]], act: "Replace the check" }),
      S("helpdesk", "helpdesk", "warn", "Deploy failing since Jul 16", "Jun 3", { bad: 1, where: ":9440", lead: "Nothing is down. The container that is running is an older build, so anything merged since June has not shipped.", facts: [["Last good deploy", "Jun 3"], ["Failed runs", "Jul 16 and Aug 27"], ["Running now", "Jun 3 build, healthy", "ok"], ["Health", "200 on /healthz", "ok"]], act: "Open the failed run" }),
      S("pushhub", "pushhub", "ok", "24 agents reporting", "latest", { where: ":8790" }),
      S("keyring", "keyring", "ok", "App and database up", "", { where: ":9020" }),
      S("mail-links", "Mail links", "ok", "Ran 01:10", "cron"),
      S("offsite", "Offsite backup", "none", "No signal yet", "cron")
    ] },
  { id: "press01", name: "press01", kind: "Windows", chips: [["512 GB free"]], lines: [["Disk", 85, "%"]],
    services: [
      S("finishing", "finishing", "warn", "Future-dated rows", "r412", { bad: 3, where: ":7150", lead: "The page is up and ingesting. Rows dated 2028 and 3104 pin its last-seen fields, so it cannot show when it goes stale.", facts: [["Ingest", "Ticking every 5 minutes", "ok"], ["Last credit", "2028-03-11", "warn"], ["Last note", "3104-06-02", "warn"]], act: "See the rows" }),
      S("carrier-feeds", "carrier-feeds", "warn", "Future-dated rows", "", { bad: 3, where: ":7140", lead: "The page is up. A row dated 2031 pins its last-sent field.", facts: [["Ingest", "Ticking every 10 minutes", "ok"], ["Last sent", "2031-01-17", "warn"]], act: "See the rows" }),
      S("claims", "Job ticket claims", "ok", "17 workers attached", "", { where: ":7077" }),
      S("ledger", "postage-ledger", "ok", "", "", { where: ":7090" }),
      S("proofs", "Proof staging", "ok", "Last ran 16:52", "", { where: ":7110" }),
      S("labels", "sheet-labels", "ok", "", "", { where: ":7120" }),
      S("orders", "orders-web", "ok", "", "", { where: ":7130" }),
      S("frontdoor", "frontdoor", "ok", "", "", { where: ":80" }),
      S("inserter", "Insert mailer", "ok", "Insurer mailing"), S("preflight", "Preflight", "ok"), S("zebra", "Zebra labels", "ok"), S("brother", "Brother labels", "ok"), S("disc", "Disc labels", "ok"),
      S("morning", "Morning emailer", "ok", "Ran 07:15"), S("sweeper", "Sweeper", "ok", "Ran Oct 4 19:30"), S("finder", "Job Finder", "ok", "Rebuilt Oct 4 22:05"), S("rush", "Rush runner", "ok"), S("courier", "Courier drop", "ok", "Shadow mode"),
      S("page-count-alert", "page-count-alert", "none", "No repo. Last log Aug 21"), S("daily-report", "daily-report", "none", "No repo and no log"), S("p7300", "press01 :7300", "none", "Answers 200. Nothing claims it")
    ] },
  { id: "press02", name: "press02", kind: "Windows", chips: [["72 GB free"]], lines: [["Disk", 85, "%"]],
    services: [S("render", "Render workers", "ok", "17 running"), S("ocr", "ocr-llm", "ok", "", "", { where: ":7078" }), S("rates", "Rate table", "ok", "Ran 02:40", "task"), S("shelf", "Shelf agent", "ok", "", "", { where: ":7484" })] },
  { id: "gpu01", name: "gpu01", kind: "Linux", chips: [["GPU 14 of 24 GB"], ["Up 41 days"]], lines: [["Graphics memory", 90, "%"], ["Disk", 85, "%"]],
    services: [S("infer", "infer", "ok", "Crash looped Oct 4, back since Oct 5", "", { where: ":8610", bad: 1 }), S("sorter", "sorter", "ok", "", "", { where: ":8450" }), S("date-reader", "date-reader", "ok", "", "", { where: ":8452" }), S("infer-watch", "infer watchdog", "ok", "Every 5 minutes", "timer"), S("sorter-restart", "Sorter restart", "ok", "Ran 03:45", "timer")] },
  { id: "web01", name: "web01", kind: "Linux", chips: [["Disk 31%"], ["Up 5 days"]], lines: [["Disk", 85, "%"]],
    services: [S("wiki", "Staff wiki", "ok", "2 replicas", "Sep 29"), S("gateway", "Gateway", "ok"), S("uptime", "Uptime ping", "ok"), S("night-backup", "Night backup", "ok", "Ran 02:20", "timer"), S("updater", "Image updater", "ok", "Ran 02:05", "timer")] },
  { id: "intake", name: "intake", kind: "Mac mini", chips: [["Up 6 days"]], lines: [["Disk", 85, "%"]],
    services: [S("intake-portal", "Client intake", "ok", "Fine on the LAN address"), S("local-model", "Local model", "ok")] },
  { id: "outside", name: "Outside", kind: "Off-site", chips: [], lines: [],
    services: [
      S("relay", "Courier app relay", "ok", "Health 200", "3.4.1", { lead: "Sits between the couriers' phones and the Routewise API. The numbers are from a 214-request test burst.", facts: [["Requests a minute", "1,340"], ["Error rate", "0%", "ok"], ["p95 response", "50 ms"], ["Phones hung up", "0"], ["Routewise calls", "214, none failed", "ok"], ["Certificate", "Renews Oct 19"]] }),
      S("intake-dns", "intake.brightwater.example", "warn", "Does not resolve on office DNS", "", { bad: 1, lead: "The intake page answers on its LAN address. The public name does not resolve from the office, and no release tag has been cut yet.", facts: [["Office DNS", "No such name", "warn"], ["LAN address", "200", "ok"]], act: "Open the intake page" }),
      S("site-scan", "site-scan", "ok", "Last run Oct 1", "quarterly"), S("licence-seeder", "licence-seeder", "ok")
    ] },
  { id: "depends", name: "Depends on", kind: "Not ours", chips: [], lines: [],
    services: [S("db", "Database server", "none", "No check yet"), S("routewise", "Routewise API", "none", "No check yet"), S("smtp", "Mail relay", "none", "No check yet"), S("filedrop", "Filedrop", "none", "No check yet"), S("power", "Power backup", "none", "No check yet")] },
  { id: "pcs", name: "Staff PCs", kind: "33 seen this week", chips: [["24 agents reporting"]], lines: [],
    services: [S("a-agent", "Brightwater Notifier", "ok", "24 PCs"), S("a-proof", "Proof Viewer", "ok", "6 PCs", "4.1.3"), S("a-finder", "Job Finder Tray", "ok", "4 PCs", "3.08"), S("a-clerk", "Desk Clerk", "ok", "3 PCs", "2.6.1"), S("a-quote", "Quote Puller", "ok", "2 PCs", "1.14"), S("a-rush", "Rush Tracker", "ok", "2 PCs, one held at 1.4.2 on purpose", "2.1.0"), S("a-plate", "Plate Decoder", "ok", "1 PC", "1.2.2"), S("a-scan", "Flatbed Scanner", "ok", "1 PC", "1.3.7")] }
];

var NOW = [
  { m: "vault", s: "helpdesk", kind: "Deploy", title: "The helpdesk deploy has failed twice", since: "since Jul 16" },
  { m: "vault", s: "loghouse", kind: "Check is wrong", title: "Loghouse reports unhealthy, but it is answering", since: "since Aug 8" },
  { m: "outside", s: "intake-dns", kind: "Outside", title: "The intake address does not resolve on office DNS", since: "seen Oct 5" }
];
var SOON = [["Memory on vault", "88%", "vault"], ["Free space on press02", "72 GB", "press02"], ["Pages that cannot show staleness", "2", "press01"]];

var LOGS = [
  ["17:46", "info", "dokkit", "Every health address answered"],
  ["16:41", "info", "desk-53", "Job Finder: search finished"],
  ["15:22", "error", "desk-53", "Rush Tracker: poll cycle failed, database connection timed out"],
  ["13:08", "error", "desk-53", "Rush Tracker: poll cycle failed, database connection timed out"],
  ["12:14", "error", "desk-23", "Proof Viewer: engine reported a file with no proof id"],
  ["11:37", "error", "desk-23", "Proof Viewer: engine reported a file with no proof id"],
  ["10:05", "info", "press02", "ocr-llm started"],
  ["02:20", "info", "web01", "Night backup finished, 61 MB"],
  ["02:05", "info", "web01", "Image updater ran, no restart needed"],
  ["01:10", "info", "vault", "Mail links ran"]
];
var WAKE = [["Client intake down", 1], ["Courier app relay down", 1], ["press01 or press02 down", 1], ["vault down", 1], ["Database unreachable", 1], ["A night job failed", 1], ["A deploy failed", 0], ["One person's desktop app keeps failing", 0]];
