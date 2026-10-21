// Made-up estate for the Android direction mocks, in the shape of the phone snapshot (spec/phone-cases/snapshot.json).
// Every direction reads this file, so they all show the same servers, machines, services and issues.
window.PHONE = (function () {
  var now = Date.now(), MIN = 60000, HR = 60 * MIN;
  var at = function (minutesAgo) { return new Date(now - minutesAgo * MIN).toISOString(); };
  var ahead = function (minutes) { return new Date(now + minutes * MIN).toISOString(); };

  function svc(id, machine, name, state, extra) {
    var s = { id: id, machine: machine, name: name, kind: "service", state: state, environment: "production", version: null, note: null, checks: [], chart: { metric: null, values: [] } };
    for (var k in extra) s[k] = extra[k];
    return s;
  }
  function chart(base, spread, tail) {
    return Array.from({ length: 24 }, function (_, i) {
      var v = base + Math.round(Math.sin(i / 2.3) * spread + (i % 5) * spread / 6);
      return tail && i >= 24 - tail.length ? tail[i - (24 - tail.length)] : Math.max(0, v);
    });
  }

  var services = [
    // db-01
    svc("s-postgres", "db-01", "postgres", "ok", { checks: [{ name: "port 5432", type: "tcp", state: "ok", checked_at: at(0.4) }], chart: { metric: "connections", values: chart(42, 8) } }),
    svc("s-pgbouncer", "db-01", "pgbouncer", "ok"),
    svc("s-wal", "db-01", "wal-archive", "ok"),
    svc("s-pgexp", "db-01", "pg-exporter", "ok"),
    svc("s-replica", "db-01", "replica-sync", "ok"),
    svc("s-purge", "db-01", "nightly-purge", "down", { kind: "job", note: "Expected at 01:00. Its last good run was yesterday at 01:04 and took 4 minutes.",
      checks: [{ name: "schedule", type: "job", state: "down", note: "Missed its 01:00 start, with 20 minutes' grace.", checked_at: at(1) }] }),
    // web-02
    svc("s-nginx", "web-02", "nginx", "ok"),
    svc("s-upload", "web-02", "upload-portal", "degraded", { version: "2.4.1", note: "Three checks in a row took over two seconds.",
      checks: [
        { name: "GET /health", type: "http", state: "degraded", note: "Answered in 2.4 s. The limit is 2 s.", checked_at: at(0.5) },
        { name: "process", type: "process", state: "ok", checked_at: at(0.5) },
        { name: "port 8080", type: "tcp", state: "ok", checked_at: at(0.5) }
      ], chart: { metric: "response time, ms", values: chart(380, 90, [1650, 1980, 2310, 2440]) } }),
    svc("s-api", "web-02", "api", "ok", { version: "7.12.0", chart: { metric: "requests a minute", values: chart(820, 160) } }),
    svc("s-queue", "web-02", "worker-queue", "ok"),
    svc("s-redis", "web-02", "redis", "ok"),
    svc("s-resize", "web-02", "resize-worker", "ok"),
    svc("s-session", "web-02", "session-store", "ok"),
    svc("s-search", "web-02", "search-index", "ok"),
    svc("s-imgcache", "web-02", "image-cache", "ok"),
    svc("s-cdnsync", "web-02", "cdn-sync", "ok"),
    svc("s-pay", "web-02", "payment-gateway", "ok"),
    svc("s-upload-stg", "web-02", "upload-portal", "degraded", { environment: "staging" }),
    // nas
    svc("s-disk", "nas", "disk /data", "degraded", { kind: "threshold", note: "91 percent full. The limit is 90.", chart: { metric: "used, %", values: chart(84, 1, [89, 90, 90, 91]) },
      checks: [{ name: "disk /data", type: "threshold", state: "degraded", note: "91.0 percent used, limit 90.", checked_at: at(0.6) }] }),
    svc("s-smb", "nas", "smb-share", "ok"),
    svc("s-nfs", "nas", "nfs-export", "ok"),
    svc("s-backup", "nas", "backup", "ok", { kind: "job" }),
    svc("s-snapkeep", "nas", "snapshot-keeper", "ok"),
    svc("s-smart", "nas", "smart-monitor", "unknown"),
    svc("s-photo", "nas", "photo-sync", "ok"),
    // mail
    svc("s-postfix", "mail", "postfix", "ok"),
    svc("s-dovecot", "mail", "dovecot", "ok"),
    svc("s-spam", "mail", "spam-filter", "ok"),
    svc("s-tls", "mail", "mail-tls", "ok", { kind: "expiry", note: "The certificate expires in 21 days.",
      checks: [{ name: "certificate", type: "expiry", state: "ok", note: "21 days left.", checked_at: at(30) }] }),
    svc("s-webmail", "mail", "webmail", "ok"),
    svc("s-av", "mail", "antivirus", "ok"),
    // build
    svc("s-ci", "build", "ci-runner", "ok"),
    svc("s-artifact", "build", "artifact-store", "ok"),
    svc("s-docker", "build", "docker-daemon", "ok"),
    svc("s-mirror", "build", "package-mirror", "unknown"),
    svc("s-nbuild", "build", "nightly-build", "ok", { kind: "job" }),
    svc("s-preview", "build", "web-preview", "down", { environment: "dev", note: "Connection refused" }),
    // sql
    svc("s-sqlsrv", "sql", "sql-server", "ok"),
    svc("s-sqlagent", "sql", "sql-agent", "ok"),
    svc("s-reports", "sql", "report-builder", "degraded", { note: "Reports take over a minute.",
      checks: [{ name: "GET /reports/health", type: "http", state: "degraded", note: "Answered in 64 s.", checked_at: at(0.7) }] }),
    svc("s-etl", "sql", "etl-loader", "ok"),
    // front-desk-pc: down, in planned downtime
    svc("s-fdagent", "front-desk-pc", "check-in kiosk", "ok"),
    // not on a machine
    svc("s-site", "g-web", "public website", "ok", { kind: "http", chart: { metric: "response time, ms", values: chart(210, 40) } }),
    svc("s-status", "g-web", "status page", "ok", { kind: "http" }),
    svc("s-dns", "g-cloud", "dns", "ok", { kind: "dns" }),
    svc("s-payapi", "g-cloud", "payments api", "unknown", { kind: "http" })
  ];

  function onMachine(id) { return services.filter(function (s) { return s.machine === id; }); }

  var machines = [
    { id: "db-01", name: "db-01", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.3),
      vitals: { "cpu.percent": 38, "memory.used_percent": 61, "disk.used_percent./": 72 } },
    { id: "web-02", name: "web-02", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.2),
      vitals: { "cpu.percent": 64, "memory.used_percent": 58, "disk.used_percent./": 44 } },
    { id: "nas", name: "nas", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.4),
      vitals: { "cpu.percent": 12, "memory.used_percent": 33, "disk.used_percent./": 41, "disk.used_percent./data": 91 } },
    { id: "mail", name: "mail", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.5),
      vitals: { "cpu.percent": 9, "memory.used_percent": 41, "disk.used_percent./": 37 } },
    { id: "build", name: "build", os: "windows", kind: "enrolled", down: false, last_seen_at: at(0.6),
      vitals: { "cpu.percent": 22, "memory.used_percent": 47, "disk.used_percent.C:": 63 },
      schedules: [{ id: "q1", reason: "Windows updates", next: ahead(60 * 26) }] },
    { id: "sql", name: "sql", os: "windows", kind: "enrolled", down: false, last_seen_at: at(0.4),
      vitals: { "cpu.percent": 31, "memory.used_percent": 88, "disk.used_percent.D:": 58 } },
    { id: "front-desk-pc", name: "front-desk-pc", os: "windows", kind: "enrolled", down: true, last_seen_at: at(170),
      vitals: {}, planned_downtime: { until: ahead(60 * 11), reason: "Off outside office hours" } },
    { id: "g-web", name: "Websites", kind: "group", down: false, vitals: {} },
    { id: "g-cloud", name: "Cloud", kind: "group", down: false, vitals: {} }
  ];
  machines.forEach(function (m) { m.services = onMachine(m.id); });

  function issue(o) {
    var base = { count: 1, acknowledged_at: null, snoozed_until: null, closed_at: null, alert: { channel: "push", status: "sent" }, history: [] };
    for (var k in o) base[k] = o[k];
    return base;
  }
  var issues = [
    issue({ id: "i3", short_id: "DOK-3", title: "Nightly purge did not run", kind: "job", machine: "db-01", service: "s-purge", state: "down", since: at(21 * 60 + 30),
      note: "Expected at 01:00. Its last good run was yesterday at 01:04 and took 4 minutes.", alert: { channel: "page", status: "sent" },
      history: [{ at: at(21 * 60 + 30), event: "opened" }, { at: at(21 * 60 + 29), event: "paged", note: "on call" }] }),
    issue({ id: "i7", short_id: "DOK-7", title: "Upload portal answers slowly", kind: "custom", machine: "web-02", service: "s-upload", state: "degraded", since: at(40), count: 3,
      note: "Three checks in a row took over two seconds. It started 20 minutes after deploy 2.4.1.", acknowledged_at: at(12),
      history: [{ at: at(40), event: "opened" }, { at: at(25), event: "reopened" }, { at: at(12), event: "acknowledged", by: "alex" }] }),
    issue({ id: "i4", short_id: "DOK-4", title: "Disk /data is nearly full", kind: "threshold", machine: "nas", service: "s-disk", state: "degraded", since: at(10),
      note: "91 percent full. The limit is 90. At this week's rate it is full in about 12 days.", alert: { channel: "push", status: "held", until: ahead(60 * 9) },
      history: [{ at: at(10), event: "opened" }, { at: at(9), event: "held", note: "night hours" }] }),
    issue({ id: "i8", short_id: "DOK-8", title: "Certificate for mail expires in 21 days", kind: "expiry", machine: "mail", service: "s-tls", state: "degraded", soon: true, since: at(120),
      note: "It expires on " + new Date(now + 21 * 24 * HR).toDateString() + ".", history: [{ at: at(120), event: "opened" }] }),
    issue({ id: "i5", short_id: "DOK-5", title: "Disk /data full in about 12 days", kind: "forecast", machine: "nas", service: "s-disk", state: "degraded", soon: true, since: at(30),
      note: "Forecast from the last week of readings.", history: [{ at: at(30), event: "opened" }] }),
    issue({ id: "i9", short_id: "DOK-9", title: "Report builder is slow", kind: "http", machine: "sql", service: "s-reports", state: "degraded", since: at(360),
      note: "Reports take over a minute.", snoozed_until: ahead(150),
      history: [{ at: at(360), event: "opened" }, { at: at(300), event: "snoozed", until: ahead(150), by: "alex" }] }),
    issue({ id: "i10", short_id: "DOK-10", title: "Web preview is down", kind: "http", machine: "build", service: "s-preview", state: "down", since: at(90), alert: null,
      note: "Connection refused.", history: [{ at: at(90), event: "opened" }] })
  ];
  function byId(id) { return issues.find(function (i) { return i.id === id; }); }
  services.forEach(function (s) { s.open_issue = issues.find(function (i) { return i.service === s.id && !i.closed_at && !i.soon; }) || null; });

  var jobs = [
    { id: "s-purge", machine: "db-01", name: "nightly-purge", state: "down", schedule: "0 1 * * *", next_expected: ahead(60 * 2 + 30), last_good_run: at(45 * 60),
      last_run: { result: "ok", exit_code: 0, duration_ms: 240000, started_at: at(45 * 60) } },
    { id: "s-backup", machine: "nas", name: "backup", state: "ok", schedule: "after midnight", next_expected: ahead(60 * 8), last_good_run: at(200),
      last_run: { result: "ok", exit_code: 0, duration_ms: 3120000, started_at: at(252) } },
    { id: "s-nbuild", machine: "build", name: "nightly-build", state: "ok", schedule: "on push", last_good_run: at(60 * 9),
      last_run: { result: "running", started_at: at(6), done: 4000, total: 9000 } }
  ];

  var logs = {
    "s-upload": [
      { t: at(0.4), level: "error", msg: "resize timed out after 30 s" }, { t: at(0.9), level: "info", msg: "upload received" },
      { t: at(1.4), level: "info", msg: "thumbnail made" }, { t: at(2), level: "warn", msg: "slow answer: 2.4 s" },
      { t: at(2.6), level: "info", msg: "virus scan passed" }, { t: at(3.1), level: "error", msg: "resize timed out after 30 s" },
      { t: at(3.7), level: "info", msg: "stored in the share" }, { t: at(4.4), level: "info", msg: "upload received" }
    ],
    "s-purge": [
      { t: at(45 * 60 - 4), level: "info", msg: "Purged 17,422 rows" }, { t: at(45 * 60 - 1), level: "info", msg: "vacuum started" },
      { t: at(45 * 60), level: "info", msg: "purge started" }
    ],
    "s-reports": [{ t: at(1), level: "warn", msg: "query took 64 s: monthly-sales" }, { t: at(6), level: "info", msg: "report queued" }]
  };

  // 48 half hours per machine, oldest first: ok, warn, bad, off (not expected), none (no data).
  // The phone snapshot does not carry this yet; it is here to show the design.
  function lastDay(id) {
    return Array.from({ length: 48 }, function (_, i) {
      var h = new Date(now - (47 - i) * 30 * MIN).getHours();
      if (id === "front-desk-pc") return h >= 8 && h < 18 ? "ok" : "off";
      if (id === "db-01") return i === 5 ? "bad" : "ok";
      if (id === "web-02") return i > 45 ? "warn" : i === 30 ? "warn" : "ok";
      if (id === "nas") return i > 46 ? "warn" : "ok";
      if (id === "sql") return i > 35 ? "warn" : "ok";
      return "ok";
    });
  }

  var snapshot = {
    schema: 1,
    server: { name: "northwind", version: "v0.4.2", made_at: at(0.7), counter: 1791937925, left_out: [] },
    inbox: {
      needs_you: [byId("i3"), byId("i7"), byId("i4")],
      soon: [byId("i8"), byId("i5")],
      snoozed: [byId("i9")],
      not_watched: [
        { id: "f1", machine: "build", name: "22", kind: "port", detail: { label: "Port 22", saw: "sshd" } },
        { id: "f2", machine: "build", name: "Spooler", kind: "service", detail: { label: "Print Spooler", saw: "Running" } },
        { id: "f3", machine: "sql", name: "defrag", kind: "job", detail: { label: "defrag", saw: "Sundays 03:00" } }
      ],
      other_environments: [{ environment: "dev", issues: [byId("i10")] }],
      fine: { services: services.filter(function (s) { return s.state === "ok"; }).length, machines: 6 }
    },
    machines: machines, services: services, issues: issues, jobs: jobs, logs: logs
  };

  // A second paired server, small and calm, so the server picker and the Servers list have something to show.
  var lab = {
    schema: 1,
    server: { name: "harbor-lab", version: "v0.4.2", made_at: at(1.2), counter: 88213, left_out: [] },
    inbox: { needs_you: [], soon: [], snoozed: [], not_watched: [], other_environments: [], fine: { services: 5, machines: 2 } },
    machines: [
      { id: "pi-4", name: "pi-4", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.5), vitals: { "cpu.percent": 7, "memory.used_percent": 29, "disk.used_percent./": 52 },
        services: [svc("l1", "pi-4", "home-assistant", "ok"), svc("l2", "pi-4", "mqtt", "ok"), svc("l3", "pi-4", "zigbee2mqtt", "ok")] },
      { id: "nuc", name: "nuc", os: "linux", kind: "enrolled", down: false, last_seen_at: at(0.4), vitals: { "cpu.percent": 18, "memory.used_percent": 44, "disk.used_percent./": 66 },
        services: [svc("l4", "nuc", "plex", "ok"), svc("l5", "nuc", "backup", "ok", { kind: "job" })] }
    ],
    services: [], issues: [], jobs: [], logs: {}
  };
  lab.services = lab.machines.reduce(function (a, m) { return a.concat(m.services); }, []);

  var servers = [
    { id: "mb-northwind", name: "northwind", relay: "https://relay.example.net", added_at: at(60 * 24 * 12), state: { snapshot: snapshot, made_at: snapshot.server.made_at, problem: null } },
    { id: "mb-lab", name: "harbor-lab", relay: "https://relay.example.net", added_at: at(60 * 24 * 3), state: { snapshot: lab, made_at: lab.server.made_at, problem: null } }
  ];

  return { now: now, at: at, ahead: ahead, servers: servers, lastDay: lastDay };
})();
