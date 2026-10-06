# The Dokkit API (v1)

This is the contract. The server, `dokkit`, the CLI, the client libraries and the MCP are all tested against it. Built so far: `POST /report` for `job`, `state`, `custom`, `beat`, `metric`, `stats`, `deploy` and `log` lines, `GET /services/<id>/series`, versions in `inventory`, `POST /deploys`, `POST /errors`, the ping URLs, `GET /ping`, `PUT /declare`, `POST /proposals`, `GET /checks`, taking work, and the read and act calls for issues (with notes and bulk actions), machines, services, versions, jobs, logs, errors, deploys, rules, proposals and tasks,, and for a service its routing, watching, interface-added checks, held version and restart. The `admin` calls are `GET`, `POST` and `DELETE` on `/keys` and `/users`, the rule calls, `PUT /services/<id>/checks` and `PUT /services/<id>/restart`: a new key is shown once, in the answer that made it, and the last owner cannot be removed. A token with `act` can accept or dismiss a found thing; accepting a task needs `admin`, because it lets the server ask a machine to run a command. Alert settings, jobs, job timing, error text, the program update, archived logs and alert suggestions have calls too. A full-control token (with `admin`) is made only in Settings, and signing in, the password and the theme belong to the browser.

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
| **Rule** | A condition, a channel (`page`, `push`, `email`, `text`, `digest`, `webhook`) and who receives it. |
| **Proposal** | Something found or offered that is not active until accepted in the interface: scan results and tasks. |
| **Task** | A named piece of work defined on a machine. A task run is one execution. |
| **Environment** | `production` by default. Anything reported under another environment, such as `dev`, is shown and never alerts. |

### Check types

| Type | Passes when |
|---|---|
| `http` | A URL answers with an expected status inside a time limit. An optional `slow` (a duration such as `2s`) makes a slow answer degraded, not down. |
| `tcp` | A port accepts a connection. |
| `process` | A process with a given name or command line is running. |
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
| Enrolment token | `dke_` | Pasted once into `dokkit enrol` | One use, expires. Trades for a machine key. |
| Machine key | `dkm_` | `dokkit` | Report for that machine, propose, take work. |
| App key | `dka_` | A library, or a script inside an app | Write-only, for one service. It can read nothing, is rate-limited and can be revoked, so it is safe inside a desktop or phone app. |
| User token | `dku_` | Scripts and the MCP | Scopes: `read`, `read-logs`, `act`, `admin`. |

The web interface uses a login session, not a token. A session lasts 14 days, and signing out or changing the password ends every session of that person. Every sign-in or password change is counted before the password is checked: after 10 from one name and address together, or 30 from one address, in ten minutes, the answer is `429` with `Retry-After` until the window passes. Many attempts on one name from different addresses are slowed, not refused. Behind a proxy the address is the last `X-Forwarded-For` entry. A user token made by a person stops working when that person is removed; user tokens made before that was recorded are not tied to anyone and have to be revoked and made again.

Roles for people: `owner`, `member`, and `viewer`. A viewer sees everything except secrets and keys.

## Conventions

- Base path `/api/v1`. Within v1, changes only ever add. Unknown fields are ignored by both sides.
- Requests and answers are JSON unless stated.
- Keys travel as `Authorization: Bearer <key>`.
- `POST /report`, `POST /errors` and the ping URLs answer `OPTIONS` and send `Access-Control-Allow-Origin: *`, so a browser page can use an app key.
- Times are RFC 3339 in UTC.
- Lists use cursors. A list answer is `{"items": [...], "next": "<cursor or null>"}` and the next page is asked for with `?cursor=`.
- Lists take `q` (search), `machine`, `service`, `environment`, `from` and `to` wherever those make sense.
- An error answer is `{"error": {"code": "...", "message": "..."}}`.
- `401` for a missing or bad key, `403` for a key without the scope, `404` for something that does not exist or that the key may not know exists, `413` for too large, `422` for a body that does not fit this contract (a body that is not valid gzip answers `422` with the code `bad_gzip`), `429` with `Retry-After` when the server is busy or a key has used up its request bucket.

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

**Read and act, built so far:** `GET /inbox`, `/issues`, `/machines`, `/services`, `/services/<id>`, `/jobs`, `/jobs/<id>/runs` and `/logs`, and `POST /issues/<id>/snooze`, `/unsnooze` and `/acknowledge`, all with a user token made in Settings. Lists answer with `next` always null for now.

## Intake

Machine key or app key.

### `POST /enrol`

```json
{"token": "dke_...", "hostname": "host-01", "os": "windows", "arch": "amd64", "dokkit": "0.1.0"}
```

Answers `{"machine": "<id>", "key": "dkm_..."}`. The token is spent. A name that is already enrolled answers `409` and the token is kept, unless the token was made for that machine (`POST /keys` with `{"kind": "enrol", "machine": "host-01"}`); then it enrols again and revokes that machine's earlier keys.

### `POST /report`

The main door. The body is newline-delimited JSON, one item per line, optionally gzip-compressed (`Content-Encoding: gzip`). The header `Dokkit-Batch: <uuid>` names the batch; sending the same batch again stores nothing twice.

The answer:

```json
{"accepted": 412, "refused": [{"line": 17, "code": "unknown_service", "message": "..."}]}
```

A refused line does not fail the batch, including a line the database cannot store. An app key is limited to a bucket of 10,000 lines refilling at 100 a second and answers `429` with `Retry-After` when it is empty. It may make 100 checks per service.

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

### Ping URLs

For anything that can only make a web request, such as a cron job on a storage box.

```
GET or POST /api/v1/in/<app key>/job/<name>/start
GET or POST /api/v1/in/<app key>/job/<name>/ok
GET or POST /api/v1/in/<app key>/job/<name>/fail
```

A POST body, if there is one, is kept as the last lines of output. `?run=<id>` ties a start to its finish.

### `PUT /declare`

The contents of a `dokkit.toml`, sent as JSON with the same structure. Sending the same file twice changes nothing. Checks, jobs, logs and stats become active. Tasks become proposals. See `dokkit-toml.md`.

### `POST /proposals`

What a scan found: the file `dokkit scan` wrote, as it is. Nothing in a proposal is active until it is accepted in the interface. So far the server keeps the running Windows services and the listening ports, and leaves out what is already watched or was dismissed. Tasks are offered through `PUT /declare`.

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
{"run": "<id>", "task": "security-scan", "command_sha256": "<hex>"}
```

`command_sha256` is the pin of the task that was accepted: a SHA-256 that `dokkit` computes over the command, the absolute path of the `dokkit.toml` that declares it (links resolved) and the contents of every word of the command (quotes removed) that is a regular file inside the task's folder, links resolved. A file outside the folder is not hashed. A task also carries the path of its file, shown beside the command. `dokkit` sends the pin with each task it declares and runs the task only when its own pin is the same one. A task accepted before pins existed has none and must be accepted again; a task declared with no pin by an older `dokkit` waits with the note that it needs a newer one and is never run.

A task has a name and nothing else. There are no arguments in v1, so the server cannot shape what runs.

```
POST /work/<run>/output     a chunk of output
POST /work/<run>/result     {"exit_code": 0, "duration_ms": 81234}
```

`dokkit` only runs a task that is defined on its machine and has been accepted. Anything else is answered with a refusal result.

### Errors

Two doors, both described in `errors.md`:

```
POST /errors                        Dokkit's own format
POST /api/<project>/envelope/       reports from Sentry's open-source SDKs
```

## Read

A login session, or a user token with `read`. Log contents need `read-logs`: without it, job output, task output, error messages and the notes on issues, services and checks are left out of every answer.

| Call | Gives |
|---|---|
| `GET /inbox` | `needs_you`, `soon`, `not_watched`, `snoozed`, `other_environments` (grouped by environment, never counted as needing you) and `fine` (`services` is the production services with nothing open, on machines that are reporting; `machines` is how many machines those are on). |
| `GET /day` | The last 24 hours in 48 half hours: `from`, `to`, `machines` (each with `cells`, 48 states of `down`, `degraded`, `quiet` or `none` for no signal) and `events` (the issues that opened, oldest first, with `sent` and `closed_at`; `sent` says what was done to tell someone and stays after the issue closes). The last cell is the half hour that holds `to`. Takes `to` (RFC 3339), default now. An issue counts in its last state. Soon issues and other environments colour nothing. |
| `GET /machines`, `GET /machines/<id>` | Machines, their vitals and thresholds. |
| `GET /services`, `GET /services/<id>` | Services. One service includes its checks, facts, routing, version on each machine, recent deploys and open issues. |
| `GET /services/<id>/series` | Chart data. Takes `metric`, `from`, `to` and `points`. |
| `GET /issues`, `GET /issues/<id>` | Issues and their history. |
| `GET /jobs`, `GET /jobs/<id>/runs` | Jobs with schedule, last run, last good run and next expected run; then the runs. |
| `GET /logs` | Log search. Takes `q`, `level`, `machine` (id or name), `service`, `from` and `to` (RFC 3339). An unknown machine or service, or a time that is not one, answers `404`. |
| `GET /errors`, `GET /errors/<id>` | Errors grouped by type and place; then the individual reports. |
| `GET /deploys` | Deploy history. |
| `GET /versions` | Which version of each service is on which machine, under `apps` each app that runs on many hosts with the hosts on each version, and under `program` the version this server gives machines to fetch and what each machine runs. |
| `GET /rules` | Alert rules. |
| `GET /alerts` | The alert settings: who is told by default, the limits, the night and the mail settings. Addresses (ntfy, webhook, heartbeat), the mail user name and secrets are never returned, only `set` or `not set`. |
| `GET /alerts/suggestions` | Issues that keep opening and are snoozed, which the daily digest could take instead. |
| `GET /logs/archives` (`read-logs`) | The archived months of logs that can be loaded back. |
| `GET /proposals` | Things waiting to be accepted. A task comes with the `command` and `pin` to send back to accept or dismiss it. |
| `GET /tasks`, `GET /task-runs` | Accepted tasks and their runs. |

## Act

A login session, or a user token with `act`. Keys, people, rules, alert settings, checks, restart, making a job, accepting a task, updating the program and loading logs back need `admin`. The interface holds the same line: what needs `admin` here is done by an owner there, and a member sees a line that says so.

| Call | Does |
|---|---|
| `POST /issues/<id>/snooze` | Snooze until a time. `{"until": "..."}`. An unknown issue answers `404`, here and for `unsnooze` and `acknowledge`. |
| `POST /issues/<id>/unsnooze` | Bring it back. |
| `POST /issues/<id>/acknowledge` | Mark as seen. |
| `POST /issues/<id>/notes` | Add a note. |
| `POST /issues/bulk` | Any of the above for a list of issues. |
| `POST /services/<id>/watch`, `/unwatch` | Start or stop watching a found service. |
| `PUT /services/<id>/checks` (`admin`) | Edit checks added in the interface. Checks that came from a file are changed in the file. |
| `PUT /services/<id>/routing` | Who is told, by which channel, for `down` and for `degraded`. A field that is not sent stays as it was. `night: false` holds this service's alerts during the night until it ends; `night: true` sends what is held. |
| `PUT /services/<id>/hold` | Mark a version on a machine as held on purpose. |
| `PUT /services/<id>/restart` (`admin`) | Allow or stop automatic restart. |
| `POST /proposals/<id>/accept`, `/dismiss` | Accept all or some of a proposal, or dismiss it. |
| `PUT /services/<id>/messages` | `{"keep": true}` keeps the text of the service's errors from now on; `false` stops. |
| `POST /jobs` (`admin`) | Add a job: `name` and `machine`, and optionally `schedule` (cron, UTC), `grace` and `max_runtime` (such as `30m`). Answers with the job's `key` and the `ping` addresses, shown once. A new machine name adds the machine. |
| `PUT /jobs/<id>/timing` | Set `grace` and `max_runtime` of a job added in the interface. A field left out stays as it was; an empty one clears it. A job from a `dokkit.toml` answers `422`: change the file. |
| `POST /rules`, `PUT /rules/<id>`, `DELETE /rules/<id>` (`admin`) | Alert rules. `PUT` changes only the fields sent; an empty one clears it. A `kind`, `state` or `channel` that is not one of its choices, `null`, or a `machine` that is not text answers `422`. |
| `PUT /alerts` (`admin`) | Change alert settings. A setting left out stays as it was; a secret sent as an empty string is cleared. A secret is sent to one host: if `ntfy_url` or `smtp_host` changes and its secret (`ntfy_token`, `smtp_password`) is not sent in the same call, the secret is cleared, and the answer carries a `note` that says so. Addresses may be on the server's own network but not this machine or a link-local address (see `alerts.md`); `smtp_port` is 25, 465, 587 or 2525. The night is whole hours, addresses must be `https`, `down`, `degraded` and `push_with` must be one of their choices: otherwise `422`. Answers with the settings as `GET /alerts` shows them. |
| `POST /alerts/test` (`admin`) | `{"channel": "webhook"}` sends a test alert by that channel. The answer is `{"ok": true}` or `422` with one fixed reason, never anything the far end said. `422` with code `slow_down` after four tests at once, then one every 25 seconds, for each token. |
| `POST /alerts/suggestions/<id>/accept`, `/dismiss` (`admin`) | Send that service's issues to the daily digest from now on, or drop the suggestion. |
| `POST /logs/archives/<name>/restore` (`admin`) | Load an archived month back for a week. Answers with the number of `lines` loaded. |
| `POST /tasks/<id>/accept`, `/dismiss` (`admin`) | Accept or dismiss a task that is waiting. Send the `command` and `pin` that `GET /proposals` shows; if either has changed since, the answer is `422` and nothing is accepted. `accept` takes `system: true` to run the task as the system account. Accepting lets the server ask a machine to run a command, so it needs `admin`. |
| `POST /tasks/<id>/run` | Run an accepted task on its machine. Answers with the run id. |
| `POST /machines/<id>/update` (`admin`) | Ask an enrolled machine to fetch the newer `dokkit` program. A person finishes the update on the machine. Answers `422` when the server holds no program. |

Keys, tokens and users are managed with the `admin` scope. A token can make a token only with scopes it holds itself, and never one with `admin`: that is made in Settings.
