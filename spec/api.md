# The Dokkit API (v1)

This is the contract. The server, `dokkit`, the CLI, the client libraries and the MCP are all tested against it. Every call described here is served. Signing in, the password, two-step sign-in and the theme belong to the browser and are not part of the API. A token with `admin` is made only in Settings.

## One rule

There is one HTTP API on the server. `dokkit`, the CLI, the libraries, the MCP and any script are clients of it. The web interface and the API are thin layers over the same server code, so nothing can be seen or done in the interface that the API cannot do.

## The words

| Word | Meaning |
|---|---|
| **Machine** | A host. Either `enrolled` (`dokkit` is on it) or `seen` (an app on it reported, for example a staff PC). A machine of kind `group` holds things with no host, such as outside dependencies. |
| **Service** | Anything that is a row. Kind is `service`, `job`, `dependency` or `app` (a desktop app on many PCs). Has `version`, `listens` and `environment`. |
| **Check** | One way of knowing a service's state. See the check types below. |
| **State** | `ok`, `degraded`, `down`, `unknown` (watched, no signal) or `unwatched` (found, nothing watching it). |
| **Issue** | Opens when a check goes bad and closes by itself when it recovers. Has a short id (`DOK-12`), a kind, a since-time and a count. Can be snoozed until a time or acknowledged. |
| **Job run** | One run of a job: start, finish, exit code, duration, progress, last lines of output. |
| **Deploy** | Version X of service S went onto machine M at time T. |
| **Rule** | A condition, a channel (`page`, `push`, `email`, `imessage`, `sms`, `digest`, `webhook`, or `none`, shown as Nobody, which sends nothing) and who receives it. A rule made without a channel gets `none`. |
| **Proposal** | Something found that is not active until accepted in the interface: scan results. |
| **Environment** | `production` by default. Anything reported under another environment, such as `dev`, is shown and never alerts. |

### Check types

| Type | Passes when |
|---|---|
| `http` | A URL answers with an expected status inside a time limit. An optional `slow` (a duration such as `2s`) makes a slow answer degraded, not down. |
| `tcp` | A port accepts a connection. |
| `process` | A process with a given name, and optionally a piece of its executable path (Windows) or command line (Linux, macOS), is running. |
| `windows-service` | A Windows service is in the running state. |
| `systemd` | A systemd unit is active. The unit is in `name`. |
| `beat` | The app said it was alive inside the expected interval. |
| `job` | A run started and finished well inside its schedule, grace and maximum runtime. |
| `stats` | The service's stats document was fetched and its numbers are inside their limits. |
| `threshold` | A number is on the right side of a limit. |
| `expiry` | A date is more than 30 days away. |
| `custom` | The app reported its own state for a check it named. |

## Keys

Every key has a recognisable prefix and a built-in checksum, so a leaked one can be spotted and a mistyped one rejected without a lookup. The server stores only a hash. A key is shown once, when it is made.

| Key | Prefix | Held by | Can do |
|---|---|---|---|
| Enrolment token | `dke_` | Pasted once into `dokkit enrol` | One use, expires after 4 hours. Trades for a machine key. |
| Machine key | `dkm_` | `dokkit` | Report for that machine, propose, take work. |
| App key | `dka_` | A library, or a script inside an app | Write-only, for one service. It can read nothing and can be revoked, so it is safe inside a desktop or phone app. |
| User token | `dku_` | Scripts and the MCP | Scopes: `read`, `read-logs`, `act`, `admin`. Each call needs the one scope it names; `admin` does not include the others. |

The read and act calls take only a user token. The web interface uses a login session, not a token, and a session is not accepted on `/api/v1`. A session lasts 14 days, and signing out or changing the password ends every session of that person. Every sign-in or password change is counted before the password is checked: after 10 from one name and address together, or 30 from one address, in ten minutes, the answer is `429` with `Retry-After` until the window passes. Many attempts on one name from different addresses are slowed, not refused. Behind a proxy the address is the last `X-Forwarded-For` entry. A person can turn on two-step sign-in at `/two-step`: signing in then asks for the password and after it a six-digit code from an authenticator app (TOTP, 30 seconds, SHA-1). Each code works once, and wrong codes are counted the same way as wrong passwords. Turning it on shows ten recovery codes once (two groups of six characters); they are stored only as hashes. At the code step a recovery code can be typed in place of an authenticator code and works once; signing in with one lands on `/two-step`, which says so and how many are left. `/two-step` can make a new set with a current authenticator code, which ends the old set. Turning two-step off, or `totp_reset`, deletes the codes. Tokens are not affected. Someone who lost their phone is let back in from the server itself with `bin/dokkit rpc 'Dokkit.Accounts.totp_reset("name")'`. A user token made by a person stops working when that person is removed; user tokens made before that was recorded are not tied to anyone and have to be revoked and made again.

Roles for people: `owner`, `member`, and `viewer`. A viewer sees everything except secrets and keys.

## Conventions

- Base path `/api/v1`. Within v1, changes only ever add. Unknown fields are ignored by both sides.
- Requests and answers are JSON unless stated.
- Keys travel as `Authorization: Bearer <key>`. The exceptions: the ping URLs carry the app key in the path, the Seq doors take it in `X-Seq-ApiKey` or `?apiKey=`, and the Sentry door takes it as `sentry_key` in `X-Sentry-Auth`, in the query or in the envelope's first line.
- `POST /report`, `POST /errors` and the ping URLs answer `OPTIONS` and send `Access-Control-Allow-Origin: *`, so a browser page can use an app key.
- Times are RFC 3339 in UTC.
- Lists use cursors. A list answer is `{"items": [...], "next": "<cursor or null>"}` and the next page is asked for with `?cursor=`. A cursor is opaque and marks a place in the list, not a page number, so items added or removed between two calls leave no gap and no repeat. `?limit=` is 1 to 500 and defaults to 100 (500 for `/logs`). A cursor that is not one answers `422` with the code `bad_cursor`. Lists drawn from deploys and error groups reach back to the newest 1,000.
- Lists take `q` (search), `machine` (id or name), `service` (id), `environment`, `from` and `to` (RFC 3339; a bad time answers `422` with `bad_time`) wherever those make sense: `/issues` all of them (`from` and `to` on when the issue opened), `/machines` `q` and `machine`, `/services` and `/jobs` `q`, `machine`, `service` and `environment`, `/deploys` and `/errors` all of them, `/jobs/<id>/runs` `from`, `to` and `result`, `/proposals` `q`, `machine` and `kind`, `/keys` `q`, `kind`, `machine`, `from` and `to`, `/users`, `/rules` and `/releases` `q`. `/services` also takes `kind` and `/jobs` `state`.
- An error answer is `{"error": {"code": "...", "message": "..."}}`. Errors the web framework raises itself, such as a route that does not exist (`404`) or a body that is not valid JSON (`400`), answer `{"errors": {"detail": "Not Found"}}` instead, with the status's own words, when the request accepts JSON.
- `401` for a missing or bad key (code `bad_key`), `403` for a key without the scope (code `no_scope`), `404` for something that does not exist or that the key may not know exists, `413` for too large, `422` for a body that does not fit this contract (a body that is not valid gzip answers `422` with the code `bad_gzip`). `429` with `Retry-After` comes only from the alert test call (code `rate_limited`) and the sign-in throttle, which belongs to the browser. An app key has no limit on how many lines or calls it sends.

### Encryption

Two supported ways on a local network:

1. A real certificate, from a reverse proxy or a private overlay network.
2. Pinning. The enrol command copied from the interface carries the server certificate's fingerprint. `dokkit` stores it and refuses any other server from then on.

There is no switch that skips verification.

### Clocks

The server stamps every item with its own receive time and a log line keeps both its own time and the time it arrived; the difference is the sender's clock offset, and is zero when the line's time was clamped or missing. "Last seen" is always the server's time. An item dated in the future is clamped to the receive time.

### Limits

- A report batch: 5 MB compressed, 10,000 lines.
- One log line: 64 KB. Longer lines are cut and marked as cut.
- The last lines of a job's output: 16 KB.
- A gzip body that inflates to more than 100 MB is refused as too large.
- An app key has no limit on how fast it sends.

## Intake

Machine key or app key, except where a call says otherwise: `POST /enrol` takes an enrolment token in its body, the ping URLs and the Sentry door take an app key, and `POST /proposals`, `GET /records`, `GET /checks`, the work calls, the update calls and `GET /program/<os>-<arch>` take a machine key only (`401` for any other).

### `GET /ping`

`{"ok": true, "time": "<RFC 3339>"}`, for a machine to check its address, its key and its clock. Any machine key or app key.

### `POST /enrol`

```json
{"token": "dke_...", "hostname": "host-01", "os": "windows", "arch": "amd64", "dokkit": "0.1.0"}
```

Answers `{"machine": "<id>", "key": "dkm_..."}`. The token is spent. A name that is already enrolled answers `409` and the token is kept, unless the token was made for that machine (`POST /keys` with `{"kind": "enrol", "machine": "host-01"}`); then it enrols again and revokes that machine's earlier keys. A token made with `POST /keys` lasts 4 hours, the same as one made in the interface; `{"hours": 24}` sets another whole number of hours from 1 to 72 and anything else answers `422` with code `bad_hours`. Settings and the Add a machine page list tokens that are made and not yet used, with the time each has left, and revoke one with `DELETE /keys/<id>`. When a machine enrols the page names which token became it.

### `POST /report`

The main door. The body is newline-delimited JSON, one item per line, optionally gzip-compressed (`Content-Encoding: gzip`). The header `Dokkit-Batch: <uuid>` names the batch; sending the same batch again stores nothing twice.

The answer:

```json
{"accepted": 412, "refused": [{"line": 17, "code": "unknown_service", "message": "..."}]}
```

A refused line does not fail the batch, including a line the database cannot store. It may make 100 checks per service; a line that would make a 101st is refused with `too_many_checks`.

Every line has `type` and `at`. With a machine key the machine is known. With an app key the service is known, and the line may carry `host` so the machine can be recorded as seen.

| `type` | Fields | From |
|---|---|---|
| `state` | `service`, `check`, `state`, `note`, `value` | `dokkit` |
| `inventory` | `os`, `dokkit`, `uptime_seconds`, `services` (each with `id`, `name`, `version`, `listens`, `how_found`) | `dokkit` |
| `metric` | `name`, `value`, `unit`, and `service` if it is not a machine-wide number | `dokkit`, app |
| `beat` | `service`, `name`, `every_seconds` | App |
| `job` | `service`, `name` (the job, when a service has more than one; otherwise the service itself), `run`, `event` (`start`, `progress`, `ok`, `fail`), and by event: `exit_code`, `duration_ms`, `done`, `total`, `tail` | `dokkit`, app |
| `stats` | `service`, `document` (see `stats-v1.md`) | `dokkit`, app |
| `log` | The fields in `log-lines.md` | `dokkit`, app |
| `deploy` | `service`, `version`, `commit`, `by` | `dokkit`, app |
| `custom` | `service`, `check`, `state`, `value`, `note` | App |

An app key may not send `state` or `inventory`.

Any line, and the bodies of `POST /errors` and `POST /deploys`, may carry `environment`. Which service it lands on:

- A service with a `dokkit.toml` declaration keeps the environment the file gives it, whatever a line says.
- Otherwise `production`, no environment, or a value that is not lower-case letters, digits, dots, dashes and underscores (32 at most) leaves the line on the key's own service.
- Any other value is stored on a sibling service of the same machine with the slug `<slug>~<environment>`, the name `<name> (<environment>)` and that environment. It never alerts and the production service is not changed by it. A service takes at most 5 such siblings; a line for a sixth is refused with `too_many_environments`.

### `POST /api/events/raw`

The door for apps that log to Seq, at the address Seq clients post to (`POST /ingest/clef` takes the same body, where newer clients post CLEF). An app moves by changing its server address and API key. The body is CLEF, one JSON event a line (`Content-Type: application/vnd.serilog.clef`, or `?clef`), or Seq's older JSON form, `{"Events": [{"Timestamp", "Level", "MessageTemplate", "Properties", "Exception", "RenderedMessage"}]}`. The key is an app key, in `X-Seq-ApiKey` or `?apiKey=`. Each event becomes a `log` line of the key's service through the same path as `POST /report`, with the same limits and storage; see `log-lines.md`. The answer is Seq's: `201` with `{"MinimumLevelAccepted": null}`, or `{"Error": "..."}` with `400` (not CLEF or Seq JSON, or no event stored), `401` or `413` (more than 10,000 events or 5 MB).

### Ping URLs

For anything that can only make a web request, such as a cron job on a storage box.

```
GET or POST /api/v1/in/<app key>/job/<name>/start
GET or POST /api/v1/in/<app key>/job/<name>/ok
GET or POST /api/v1/in/<app key>/job/<name>/fail
```

A POST body, if there is one, is kept as the last lines of output. `?run=<id>` ties a start to its finish.

### `PUT /declare`

The contents of a `dokkit.toml`, sent as JSON with the same structure. Sending the same file twice changes nothing. Checks, jobs, logs and stats become active. See `dokkit-toml.md`.

A machine key declares any service on its machine. An app key declares the one service it belongs to: `service.id` must be that service's slug, or the answer is `422`. The service keeps its machine and kind, and the file may set its name and environment. Only `schema`, `service`, `check` and `job` are read. Checks of type `beat` or `custom`, which only wait for reports, are accepted and any other check type is refused. A job keeps `id`, `schedule`, `grace` and `max_runtime`. At most 100 checks and jobs. An app key counts against its rate limit.

### `POST /proposals`

What a scan found: the file `dokkit scan` wrote, as it is. Nothing in a proposal is active until it is accepted in the interface. The server keeps the running Windows and systemd services, the listening ports, scheduled jobs (`found.jobs`, with `notes` saying what the scan could not see), containers that publish a TCP port and sites that have an address, and leaves out what is already watched or was dismissed. A job is accepted as a job that waits for its first report; a container becomes a service with a `tcp` check and a site a service with an `http` check.

Each service, port, job, container and site may carry `origin` (`system`, `software` or `yours`) and `why`, one line naming the fact the program decided from (`spec/program.md`, Origin). The server keeps both; anything else in `origin` is stored as unknown. A program that sends none is stored as unknown, which is shown and never hidden. When a machine sends a proposal again, the origin and why of its findings that nobody has decided about are brought up to date; a finding that was dismissed is left as it is, and a proposal without an origin never erases one already kept.

### `POST /quiet`

A machine says it is going down on purpose: `{"for": "15m", "reason": "nightly update"}`. `for` is a length written as seconds, minutes or hours (`90s`, `15m`, `4h`, a bare number is seconds) and at most `4h`; `reason` is optional and cut at 200 characters. For that long from now the machine going silent, and its checks going down or missing, open no issue and send nothing (`alerts.md`, Planned downtime). A second call replaces the window; `{"for": "0"}` ends it. Issues already open stay open. A machine key can only quiet its own machine. Answers `{"ok": true, "until": "<time>"}`, `until` null when it ended a window; `422` with `bad_duration` for a `for` that is missing, is not a length or is over the most.

### `GET /records`

The accepted found jobs on this machine whose runs the program reads from the system's own record: `{"items": [{"service": "nightly-export", "name": "nightly-export", "source": "task-scheduler", "unit": "\\Nightly export"}]}`. `source` is `task-scheduler` or `systemd-timer`.

### `GET /checks`

The checks added in the interface for this machine, for `dokkit` to run: `{"items": [{"service": "spooler", "name": "windows-service", "type": "windows-service", "config": {"name": "Spooler"}}]}`.

### `POST /deploys`

```json
{"service": "upload-portal", "version": "2.3.0", "host": "<name>", "commit": "abc123", "by": "ci"}
```

For CI. `host` is the machine the version went onto, when that is not the machine the service lives on. A deploy is also recorded automatically whenever a service's reported version changes, so most apps never call this.

### Taking work

```
GET /program/<os>-<arch>           the newer dokkit this server holds, for a machine asked to fetch it
GET /work?wait=50
```

`dokkit` asks for work and the server holds the request for up to 50 seconds. `204` means nothing to do; ask again. Otherwise:

```json
{"run": "<id>", "task": "dokkit:update"}
```

The server asks for two things and nothing else. `dokkit:update` asks the program to fetch the newer copy the server holds. There are no arguments, so the server cannot shape what the program does. `dokkit:imessage` is offered only to the Mac chosen for iMessage and carries two more fields:

```json
{"run": "<id>", "task": "dokkit:imessage", "to": ["+15555550100", "someone@example.com"], "text": "Upload portal is down (web-01, DOK-12)"}
```

The program posts one output line for each recipient (`sent to X` or `not sent to X: why`) and a result with `exit_code` 0 when all were sent, 1 otherwise, or `{"refused": "why"}`.

```
POST /work/<run>/output     a chunk of output
POST /work/<run>/result     {"exit_code": 0, "duration_ms": 81234}
```

A name the program does not know is answered with a refusal result.

### Updates

How an update reaches a machine is in `updates.md`. The updater on a machine uses its machine key.

```
GET /update?program=v1.2.3&server=v1.2.3&updater=v1.2.3&os=windows&arch=x64
POST /update/result
GET /releases/<version>/<file>      a file of a release the server holds
```

`GET /update` remembers what the machine is on (`server` is left out when it does not run the server) and that it has an updater. `204` when no version is wanted, when the server does not hold the wanted version completely (both `SHA256SUMS` and `SHA256SUMS.sig`), or when every part the machine has is already on it. Otherwise `200`:

```json
{"version": "v1.2.3"}
```

The result is `{"version": "v1.2.3", "ok": true, "note": "program, updater"}`, or `ok: false` with a `note` of at most 2000 characters. The server keeps the last result for the machine and, when `ok` is true, clears the wanted version. The answer is `{"ok": true}`; a result with no `version`, no `ok` or a longer note answers `422`.

### Errors

Two doors, both described in `errors.md`:

```
POST /errors                        Dokkit's own format
POST /api/<project>/envelope/       reports from Sentry's open-source SDKs
```

### `POST /mcp`

The MCP, as JSON-RPC over one address outside `/api/v1`. It takes a user token and does no more than that token's scopes allow; `GET /mcp` answers `405`. See `mcp.md`.

## Read

A user token with `read`. Log contents need `read-logs`: without it, job output, error messages and the notes on issues, services and checks are left out of every answer.

| Call | Gives |
|---|---|
| `GET /inbox` | `needs_you`, `soon`, `not_watched`, `snoozed`, `planned_downtime` (the machines in a window, with `machine`, `id`, `until`, `reason`, `by`), `other_environments` (grouped by environment, never counted as needing you) and `fine` (`services` is the production services with nothing open, on machines that are reporting; `machines` is how many machines those are on). |
| `GET /day` | The last 24 hours in 48 half hours: `from`, `to`, `machines` (each with `cells`, 48 states of `down`, `degraded`, `planned` for a machine in planned downtime, `quiet` or `none` for no signal) and `events` (the issues that opened, oldest first, with `sent` and `closed_at`; `sent` says what was done to tell someone and stays after the issue closes). The last cell is the half hour that holds `to`. Takes `to` (RFC 3339), default now. An issue counts in its last state. Soon issues and other environments colour nothing. |
| `GET /machines`, `GET /machines/<id>` | Machines, their vitals and thresholds, and `planned_downtime` (null or the running window). One machine also has `metrics`: the latest reading of each of its own numbers (`name`, `value`, `at`), however old, and `downtime_history`: its last 20 windows, newest first, each with who started and ended it. |
| `GET /machines/<id>/series` | Chart data for a machine's own numbers (`disk.used_percent.<mount>`, `memory.used_percent`, `cpu.percent`), the same as a service's: without `metric` the names, with it the points. Takes `metric`, `from`, `to` and `points`. Machine numbers are kept for 30 days. |
| `GET /services`, `GET /services/<id>` | Services. One service includes its `checks`, `facts` (the `[service]` table of its description file, empty when it has none), `routing`, `versions` (the version on each machine: for an app each host that reported it, for anything else each machine that has a service of the same id), the ten latest `deploys`, `stats` and its `open_issue`. |
| `GET /services/<id>/series` | Chart data. Takes `metric`, `from`, `to` and `points`. |
| `GET /issues`, `GET /issues/<id>` | Issues, newest first. `state` is `open` (not snoozed), `snoozed`, `closed` or `all`; left out, the open and snoozed ones. One issue has `history`, oldest first: `opened`, each `note` (with `by` and `note`), `acknowledged`, `snoozed` and `closed`. Dokkit keeps only the current snooze, so `snoozed` has `until` and no `at`. |
| `GET /jobs`, `GET /jobs/<id>/runs` | Jobs with schedule, last run, last good run and next expected run; then the runs, newest first. A run has `done` and `total` while it reports progress, which the Jobs page and the service page show as a bar and "4,000 of 9,000" for a run in progress. |
| `GET /logs` (`read-logs`) | Log search. Takes `q`, `level`, `machine` (id or name), `service`, `from` and `to` (RFC 3339). An unknown machine or service, or a time that is not one, answers `404`. |
| `GET /errors`, `GET /errors/<id>` | Errors grouped by type and place; then one group with its latest stack and `reports`, its individual reports newest first as `{"items", "next"}`, paged by `cursor` and `limit`. |
| `GET /deploys` | Deploy history. |
| `GET /versions` | Which version of each service is on which machine, under `apps` each app that runs on many hosts with the hosts on each version, and under `program` the version this server gives machines to fetch and what each machine runs. |
| `GET /rules` | Alert rules. |
| `GET /alerts` | The alert settings: who is told by default, the limits, the night and the mail settings. `down`, `degraded`, `self_down` and `self_degraded` are text, with commas when several channels are set, and each has a list beside it (`down_channels` and so on). `night_zone` is the time zone name, or empty while the night is read as UTC plus `night_offset`. The ntfy, webhook and heartbeat addresses, the mail user name, the Twilio account SID and every secret are never returned, only `set` or `not set`. The answer is the same for every token with `read`. |
| `GET /alerts/suggestions` | Issues that keep opening and are snoozed, which the daily digest could take instead. |
| `GET /logs/archives` (`read-logs`) | The archived months of logs that can be loaded back. |
| `GET /proposals` | Things waiting to be accepted, each with `origin` and `why` (null when the machine's program did not say). The operating system's own things (`origin` `system`) are left out unless `system=true`, and the answer carries `hidden`: `{"total": 409, "machines": {"<machine name>": 12}}`, the number left out under the same `machine`, `kind` and `q` filters, in total and for each machine (`{"total": 0, "machines": {}}` with `system=true`). The Found page hides the same things by default. |
| `GET /releases` | The releases the server holds, newest first: `version`, `files` and `complete`, which is true when both `SHA256SUMS` and `SHA256SUMS.sig` are held. |

## Act

A user token with `act`. Keys, people, rules, alert settings, checks, restart, making an app, a dependency or a job, updating the program, releases, the uploaded certificate and loading logs back need `admin`. The `GET` calls in this table need only `read`, except `GET /certificate/settings`, which needs `admin`. The interface holds the same line: what needs `admin` here is done by an owner there, and a member sees a line that says so.

| Call | Does |
|---|---|
| `POST /issues/<id>/snooze` | Snooze until a time. `{"until": "..."}`. An unknown issue answers `404`, here and for `unsnooze` and `acknowledge`. |
| `POST /issues/<id>/unsnooze` | Bring it back. |
| `POST /issues/<id>/acknowledge` | Mark as seen. |
| `POST /issues/<id>/notes` | Add a note: `{"text": "..."}`, kept to 2,000 characters and recorded as written by the token. `404` for an unknown issue, `422` with `bad_note` without text. |
| `POST /issues/bulk` | Snooze, unsnooze or acknowledge a list of issues: `{"ids": [...], "action": "snooze", "until": "..."}`, where `action` is `snooze` (with `until`), `unsnooze` or `acknowledge`. Answers `{"ok": true}`; ids that do not exist are skipped; anything else answers `422` with `bad_action`. |
| `POST /services/<id>/watch`, `/unwatch` | Start or stop watching a found service. |
| `PUT /services/<id>/checks` (`admin`) | Edit checks added in the interface. Checks that came from a file are changed in the file. |
| `PUT /services/<id>/routing` | By which channels this service's alerts go, for `down` and for `degraded`: one channel of a rule, or several as a list or as text with commas (`["page", "email"]`), each sending its own alert. `none` (Nobody) sends nothing for this service and cannot be combined with others (`422`, `bad_routing`). A value that is not a channel clears the setting so the rules decide. A field that is not sent stays as it was. Answers `{"down", "degraded", "night", "down_channels", "degraded_channels"}`: `down` and `degraded` are text, with commas when there are several, exactly as before for one channel; the lists are beside them. Before: `{"down": "page", "degraded": null, "night": true}`. After, for two channels: `{"down": "page,email", "degraded": null, "night": true, "down_channels": ["page", "email"], "degraded_channels": []}`. `night: false` holds this service's alerts during the night until it ends; `night: true` sends what is held. |
| `PUT /services/<id>/hold` | Mark a version on a machine as held on purpose: `{"version": "..."}`. Answers as `GET /services/<id>` does. |
| `PUT /services/<id>/restart` (`admin`) | Allow or stop automatic restart: `{"allow": true}`. Answers as `GET /services/<id>` does. |
| `POST /proposals/<id>/accept`, `/dismiss` | Accept or dismiss one proposal. |
| `POST /proposals/accept`, `/dismiss` | Accept or dismiss some proposals, `{"ids": [...]}`, or every one waiting and shown, `{"all": true}`; `all` leaves out the operating system's own things unless `"system": true` is sent too, while any proposal, hidden or not, can be named by id. Answers `{"ok": true, "done": [ids acted on]}`; ids not waiting are left out of `done`, and `404` when none of the `ids` is waiting. |
| `PUT /services/<id>/messages` | `{"keep": true}` keeps the text of the service's errors from now on; `false` stops. |
| `POST /apps` (`admin`) | Add an app that runs on many machines, such as a desktop program: `name`. Answers with its `id`, `slug` and `key`, shown once. The app belongs to no one machine; each PC it reports from is listed as it is seen. |
| `POST /dependencies` (`admin`) | Add something outside that is depended on: `name`, and optionally `machine` and `check`, which is `{"type": "http", "url": "https://..."}` or `{"type": "tcp", "address": "host:port"}`. Dokkit has no way to run a check from the server, so a check is run by the program on `machine`, which must be enrolled; the program reaches only hosts its own configuration allows. Without a check the dependency belongs to the group machine Outside. Answers as `GET /services/<id>` does. A certificate expiry check is not offered through this call yet: the program is only handed `http`, `tcp`, `process`, `windows-service` and `systemd` checks by the server. |
| `POST /jobs` (`admin`) | Add a job: `name` and `machine`, and optionally `schedule` (cron, UTC), `grace` and `max_runtime` (such as `30m`). Answers with the job's `key` and the `ping` addresses, shown once. A new machine name adds the machine. |
| `PUT /jobs/<id>/timing` | Set `grace` and `max_runtime` of a job added in the interface. A field left out stays as it was; an empty one clears it. A job from a `dokkit.toml` answers `422`: change the file. |
| `POST /rules`, `PUT /rules/<id>`, `DELETE /rules/<id>` (`admin`) | Alert rules. `PUT` changes only the fields sent; an empty one clears it. `channel` is one channel or several as text with commas; `channels` is the same as a list and wins when both are sent; answers carry both. A `kind`, `state`, `channel` or `channels` that is not one of its choices, `null`, `none` combined with others, or a `machine` that is not text answers `422`. |
| `PUT /alerts` (`admin`) | Change alert settings. A setting left out stays as it was; a secret sent as an empty string is cleared. A secret is sent to one host: if `ntfy_url` or `smtp_host` changes and its secret (`ntfy_token`, `smtp_password`) is not sent in the same call, the secret is cleared, and the answer carries a `note` that says so. Addresses may be on the server's own network but not this machine or a link-local address (see `alerts.md`); `smtp_port` is 25, 465, 587 or 2525. The night is whole hours, `night_zone` a time zone name the server knows (such as `America/Los_Angeles`; `digest_at` is read in it), addresses must be `https`, `down`, `degraded`, `self_down` and `self_degraded` must be a channel (`none` included) or a list of channels (a list, or text with commas; `none` alone) and `push_with` one of `ntfy`, `pushover` and `pagerduty`: otherwise `422`. Answers with the settings as `GET /alerts` shows them. |
| `POST /alerts/test` (`admin`) | `{"channel": "webhook"}` sends a test alert by that channel, or by that person's destination when `person` (a person id) is sent. `none`, a channel that is not one and a `person` that is not on this server answer `422` with `bad_channel` or `bad_person`. Otherwise the answer is `{"ok": true}` (with `"resolves_in": 120` for a test that stays open) or `422` with `send_failed` and one reason: for SMS Twilio's own message, for iMessage the Mac's answer (waited for up to a minute), for the others a fixed reason, never anything the far end said. `422` with code `slow_down` after four tests at once, then one every 25 seconds, for each token. A test by `page`, or by `push` when push goes through PagerDuty, stays open for two minutes and then resolves itself (see `alerts.md`) and costs twice as much: two at once, then one every 50 seconds. |
| `PUT /machines/<id>/routing` | How this machine is announced when it stops reporting: `down`, one channel or a list (empty for the server-wide choice for `down`), and `night` (default true; false holds the alert until the night ends). A field that is not sent stays as it was. Answers `{"down", "down_channels", "night"}`. `GET /machines/<id>` carries the same as `silent`. |
| `GET /alerts/people` | Each person with their own destinations (email, phone for SMS, iMessage address, ntfy address, Pushover user key, PagerDuty routing key). The ntfy address, Pushover key and routing key are only `set` or `not set`. |
| `PUT /alerts/people/<id>` (`admin`) | Change a person's destinations. A field left out stays; an empty one clears it. A bad address answers `422`. |
| `GET /alerts/who`, `PUT /alerts/who` (`admin`) | Who is told at each level. `PUT` takes `scope` (`default`, `rule`, `service` or `check`), `id` (not for `default`; for a check, `service` and `name` may be sent instead) and `to`, a list of person ids or `["everyone"]`; an empty list names nobody there so the level above decides. |
| `POST /alerts/suggestions/<id>/accept`, `/dismiss` (`admin`) | Send that service's issues to the daily digest from now on, or drop the suggestion. |
| `POST /logs/archives/<name>/restore` (`admin`) | Load an archived month back for a week. Answers with the number of `lines` loaded. |
| `POST /machines/<id>/update` (`admin`) | `{"version": "v1.2.3"}` sets the machine's wanted version, for its updater to act on, and only to a release the server holds completely: `422` with code `not_held` otherwise, `bad_version` when it is not `v` and three numbers. Answers `{"ok": true, "version": "v1.2.3"}`. Without a body, it asks an enrolled machine to fetch the newer `dokkit` program, which a person finishes on the machine; `422` when the server holds no program. |
| `POST /machines/<id>/scan` (`act`) | Asks an enrolled machine to look itself over again and send what it finds to proposals: the built-in work `dokkit:scan`, which takes no parameters. Answers `{"run": "<id>"}`; `404` for a machine that is not enrolled. A program too old to know it refuses the run. |
| `POST /machines/<id>/quiet` (`act`) | The same as `POST /quiet`, for any enrolled machine, by a person's token: `{"for": "30m", "reason": "disk swap"}`. Answers `{"id", "name", "planned_downtime"}` where `planned_downtime` is `{started_at, until, reason, by, ended_at, ended_by}` or null; `404` for a machine that is not enrolled. `DELETE /machines/<id>/quiet` (`act`) ends the window now and answers the same. |
| `POST /update-all` (`admin`) | The same body, for every machine that has an updater. Answers `{"ok": true, "version": "v1.2.3", "machines": 3}`. |
| `PUT /releases/<version>/<file>` (`admin`) | The body is the file, as is, up to 200 MB (`413` over that), written to disk as it arrives. Replaces a file of that name. The server does not check it; the updater does. A version or file name of anything but letters, digits, dots, dashes and underscores, or one that starts with a dot, answers `422` with code `bad_name`. |
| `DELETE /releases/<version>` (`admin`) | Removes that version's files. |
| `GET /keys`, `POST /keys`, `DELETE /keys/<id>` (`admin`) | The keys that still work, newest first (`id`, `kind`, `hint`, `label`, `scopes`, `used_at`, `expires_at`, `inserted_at`, `machine`, `service`); make one; revoke one. `POST` takes `{"kind": "user", "label": "...", "scopes": [...]}`, `{"kind": "app", "service": "<id>"}` or `{"kind": "enrol", "machine": "...", "hours": 4}` and answers `{"id", "key"}`, the key shown once. A user token made here needs a label and scopes, only holds scopes the calling token holds, and never has `admin`; anything else answers `422` with `bad_key`, and `hours` out of range `bad_hours`. An app key for an unknown service answers `404`. `DELETE` answers `{"ok": true}`. |
| `GET /users`, `POST /users`, `DELETE /users/<id>` (`admin`) | The people (`id`, `name`, `role`); add one with `{"name", "role", "password"}`; remove one, which also revokes that person's user tokens. Both `POST` and `DELETE` answer `422` with `bad_person` and a sentence when the person cannot be added or removed, and the last owner cannot be removed. |
| `GET /certificate` | The certificates the server serves itself: `installed` (the one it was installed with, which enrolled machines pin) and `uploaded`, each `null` when there is none, otherwise `names` (DNS names), `issuer`, `not_after`, `self_signed` and `sha256` (hex fingerprint of the leaf). Never a key. |
| `PUT /certificate` (`admin`) | `{"cert": "<PEM, leaf then its chain>", "key": "<PEM private key>"}`. `422` with code `bad_certificate` and a sentence when a file cannot be read, the key is not the leaf's, the leaf is expired or not yet valid, or it names no DNS name; also when the server does not serve TLS itself. Otherwise saved and served at once to clients that ask for one of its names; any other name, and a client that connects by address, still gets the installed certificate. Answers as `GET` does. |
| `DELETE /certificate` (`admin`) | Removes the uploaded certificate. Answers as `GET` does. |
| `GET /certificate/settings`, `PUT /certificate/settings` (`admin`) | The settings for getting the uploaded certificate by itself: `acme_name` (a DNS name, no wildcard), `acme_cloudflare_token` (a Cloudflare API token that may edit DNS in the name's zone; shown only as `set` or `not set`, an empty string clears it) and `acme_directory` (an https address; Let's Encrypt production when empty, `https://acme-staging-v02.api.letsencrypt.org/directory` for staging). A setting left out stays as it was; a bad one answers `422` with code `bad_settings`. |
| `POST /certificate/renew` (`admin`) | Gets a certificate for `acme_name` now and waits for it, which can take a few minutes. Answers as `GET /certificate` does, or `422` with code `renewal_failed` and the reason. |

With `acme_name` and `acme_cloudflare_token` set, the server checks once a day: when the uploaded certificate does not cover `acme_name`, or has 30 days or fewer left, it gets a new one from the certificate authority (ACME, RFC 8555), proving the name with a TXT record at `_acme-challenge.<name>` that it adds at Cloudflare and always removes again. The certificate goes through the same checks and saving as an upload and is served at once. After a failure it tries again no sooner than twelve hours later. `renewal` in `GET /certificate` is `{"at", "ok", "note"}` for the last attempt: `Renewed, runs out 2027-03-20` or the sentence that says why not.

Keys, tokens and users are managed with the `admin` scope. A token can make a token only with scopes it holds itself, and never one with `admin`: that is made in Settings.
