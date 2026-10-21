// Made-up company for the UI direction mocks. Same shape for all five directions.
window.DOKKIT = (function () {
  var now = Date.now(), min = 60000, hr = 60 * min;
  var ago = function (m) { return new Date(now - m * min).toISOString(); };

  var machines = [
    { id: "db-01", os: "linux", state: "down", cpu: 38, mem: 61, disk: 72, uptime: "41 days", program: "0.4.2", services: 7, attention: 1, soon: 0 },
    { id: "web-02", os: "linux", state: "degraded", cpu: 64, mem: 58, disk: 44, uptime: "12 days", program: "0.4.2", services: 12, attention: 1, soon: 0 },
    { id: "nas", os: "linux", state: "degraded", cpu: 12, mem: 33, disk: 91, uptime: "88 days", program: "0.4.2", services: 8, attention: 1, soon: 1 },
    { id: "mail", os: "linux", state: "ok", cpu: 9, mem: 41, disk: 37, uptime: "23 days", program: "0.4.2", services: 9, attention: 0, soon: 1 },
    { id: "build", os: "windows", state: "ok", cpu: 22, mem: 47, disk: 63, uptime: "6 days", program: "0.4.1", services: 7, attention: 0, soon: 0 },
    { id: "sql", os: "windows", state: "ok", cpu: 31, mem: 76, disk: 58, uptime: "19 days", program: "0.4.2", services: 8, attention: 0, soon: 0 },
    { id: "front-desk-pc", os: "windows", state: "away", cpu: null, mem: null, disk: null, uptime: "office hours", program: null, services: 0, attention: 0, soon: 0 }
  ];

  var issues = [
    { id: "DOK-3", tab: "needs", state: "down", title: "Nightly purge did not run", kind: "Job", machine: "db-01", service: "nightly-purge", since: ago(21 * 60 + 30), count: 1,
      note: "Expected by 01:20, with 20 minutes' grace. The last run was yesterday at 01:00 and took 4 min.", timeline: [[ago(21 * 60 + 30), "Missed its 01:00 start"], [ago(45 * 60), "Ran in 4 min: Purged 17,422 rows"]] },
    { id: "DOK-7", tab: "needs", state: "degraded", title: "Upload portal answers slowly", kind: "Custom check", machine: "web-02", service: "upload-portal", since: ago(40), count: 3,
      note: "Three checks in a row took over two seconds. It started 20 minutes after deploy 2.4.1.", timeline: [[ago(40), "Latency 2.4 s (limit 2 s)"], [ago(60), "Deployed 2.4.1 (9f3c2ab) by ci"]] },
    { id: "DOK-4", tab: "needs", state: "degraded", title: "Disk /data is nearly full", kind: "Threshold", machine: "nas", service: "disk", since: ago(10), count: 1,
      note: "91% used and climbing about 0.7% a day. At this rate it is full in 12 days.", timeline: [[ago(10), "91.0% (limit 90%)"], [ago(7 * 24 * 60), "79.0%"]] },
    { id: "DOK-10", tab: "needs", state: "down", env: "dev", title: "Web preview is down", kind: "Web address", machine: "build", service: "web-preview", since: ago(90), count: 1,
      note: "Connection refused on http://localhost/web-preview.", timeline: [[ago(90), "Connection refused"]] },
    { id: "DOK-8", tab: "soon", state: "soon", title: "Certificate for mail expires in 21 days", kind: "Expiry", machine: "mail", service: "mail-tls", since: ago(120), count: 1,
      note: "It expires on " + new Date(now + 21 * 24 * hr).toDateString() + ".", timeline: [[ago(120), "21 days left"]] },
    { id: "DOK-5", tab: "soon", state: "soon", title: "Disk /data full in about 12 days", kind: "Forecast", machine: "nas", service: "disk", since: ago(30), count: 1,
      note: "Forecast from the last week of readings.", timeline: [[ago(30), "Forecast: full around " + new Date(now + 12 * 24 * hr).toDateString()]] },
    { id: "F-1", tab: "unwatched", state: "found", title: "Port 22 (sshd) on build", kind: "Found by a scan", machine: "build", service: "sshd", since: ago(200), count: 1, note: "Answering on port 22. Not watched yet.", timeline: [] },
    { id: "F-2", tab: "unwatched", state: "found", title: "Print Spooler service on build", kind: "Found by a scan", machine: "build", service: "Spooler", since: ago(200), count: 1, note: "A Windows service, running. Not watched yet.", timeline: [] },
    { id: "F-3", tab: "unwatched", state: "found", title: "Task defrag on sql, Sundays 03:00", kind: "Found by a scan", machine: "sql", service: "defrag", since: ago(300), count: 1, note: "A scheduled task. Not watched yet.", timeline: [] },
    { id: "F-4", tab: "unwatched", state: "found", title: "Port 8443 on web-02", kind: "Found by a scan", machine: "web-02", service: "8443", since: ago(320), count: 1, note: "Something answers on 8443. Not watched yet.", timeline: [] },
    { id: "DOK-9", tab: "snoozed", state: "degraded", title: "Report builder is slow", kind: "Web address", machine: "sql", service: "report-builder", since: ago(360), count: 1, note: "Reports take over a minute. Snoozed until 17:00.", timeline: [[ago(360), "Answering in 64 s"]] }
  ];

  var serviceNames = {
    "db-01": ["postgres", "pgbouncer", "wal-archive", "pg-exporter", "replica-sync", "log-shipper", "nightly-purge"],
    "web-02": ["nginx", "upload-portal", "api", "worker-queue", "redis", "resize-worker", "session-store", "search-index", "image-cache", "cdn-sync", "payment-gateway", "upload-portal (staging)"],
    "nas": ["smb-share", "nfs-export", "backup", "snapshot-keeper", "smart-monitor", "replication", "media-index", "photo-sync"],
    "mail": ["postfix", "dovecot", "spam-filter", "mail-queue", "mail-tls", "dkim-signer", "webmail", "antivirus", "list-server"],
    "build": ["ci-runner", "artifact-store", "docker-daemon", "package-mirror", "nightly-build", "web-preview", "cache-cleaner"],
    "sql": ["sql-server", "sql-agent", "report-builder", "ssis", "ssrs", "linked-server", "etl-loader", "reporting-portal"]
  };
  var services = [];
  Object.keys(serviceNames).forEach(function (m) {
    serviceNames[m].forEach(function (s) {
      var issue = issues.find(function (i) { return i.service === s && i.machine === m && i.tab !== "unwatched"; });
      services.push({ machine: m, id: s, kind: /nightly|backup|purge/.test(s) ? "job" : "service",
        state: issue ? (issue.tab === "soon" ? "soon" : issue.tab === "snoozed" ? "snoozed" : issue.state) : "ok",
        env: s === "web-preview" ? "dev" : /staging/.test(s) ? "staging" : "production",
        version: s === "upload-portal" ? "2.4.1" : null });
    });
  });

  // 48 half hours per machine: ok, warn, bad, off (not expected), none (silent).
  function lastDay(m) {
    return Array.from({ length: 48 }, function (_, i) {
      if (m === "front-desk-pc") { var h = (new Date(now - (47 - i) * 30 * min)).getHours(); return h >= 8 && h <= 17 ? "ok" : "off"; }
      if (m === "db-01") return i > 5 ? "bad" : "ok";
      if (m === "web-02") return i > 44 ? "warn" : i === 30 ? "warn" : "ok";
      if (m === "nas") return i > 46 ? "warn" : "ok";
      if (m === "sql") return i > 35 ? "warn" : "ok";
      return "ok";
    });
  }

  var jobs = [
    { id: "nightly-purge", machine: "db-01", schedule: "01:00 daily", last: "missed", lastRun: ago(45 * 60), took: "4 min", runs: ["ok", "ok", "ok", "missed"] },
    { id: "backup", machine: "nas", schedule: "after midnight", last: "ok", lastRun: ago(200), took: "52 min", runs: ["ok", "slow", "ok", "ok", "ok", "slow"] },
    { id: "nightly-build", machine: "build", schedule: "on push", last: "running", lastRun: ago(6), took: null, progress: [4000, 9000], runs: ["ok", "running"] }
  ];

  var levels = ["info", "info", "info", "warn", "info", "error"];
  var msgs = ["upload received", "thumbnail made", "virus scan passed", "stored in the share", "resize timed out after 30 s", "checkpoint complete", "checkpoint took 38 s"];
  var logs = Array.from({ length: 40 }, function (_, i) {
    var err = i % 7 === 3, warn = i % 11 === 5;
    return { at: ago(i * 3 + 1), level: err ? "error" : warn ? "warn" : "info", service: i % 5 === 4 ? "postgres" : "upload-portal",
      machine: i % 5 === 4 ? "db-01" : "web-02", msg: err ? "resize timed out after 30 s" : warn ? "checkpoint took 38 s" : msgs[i % 4] };
  });

  var deploys = [
    { service: "upload-portal", version: "2.4.1", commit: "9f3c2ab", by: "ci", at: ago(60), after: "Errors went from 0 to 14 an hour" },
    { service: "upload-portal", version: "2.4.0", commit: "41be850", by: "ci", at: ago(3 * 24 * 60), after: "No change" },
    { service: "api", version: "7.12.0", commit: "7fe7108", by: "maria", at: ago(26 * 60), after: "No change" }
  ];

  return { now: now, machines: machines, issues: issues, services: services, lastDay: lastDay, jobs: jobs, logs: logs, deploys: deploys,
    fine: { services: services.filter(function (s) { return s.state === "ok"; }).length, machines: 6 },
    ago: function (iso) { var m = Math.round((now - new Date(iso)) / min); return m < 60 ? m + " min ago" : m < 1440 ? Math.round(m / 60) + " h ago" : Math.round(m / 1440) + " d ago"; } };
})();
