# The Dokkit API (v1)

This is the contract. The server, `dokkit`, the CLI, the client libraries and the MCP are all tested against it. Built so far: `POST /report` for `job`, `state`, `custom`, `beat`, `metric`, `stats`, `deploy` and `log` lines, `GET /services/<id>/series`, versions in `inventory`, `POST /deploys`, `POST /errors`, the ping URLs, `GET /ping`, `PUT /declare`, `POST /proposals`, `GET /checks`, taking work, and the read and act calls for issues (with notes and bulk actions), machines, services, versions, jobs, logs, errors, deploys, rules, proposals and tasks, and a service's routing. Not built yet: `watch` and `unwatch`, editing checks, `hold`, `restart`, and the `admin` calls. A token can accept or dismiss a found thing; a task is accepted by a person in the interface.

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
| `http` | A URL answers with an expected status inside a time limit. |
| `tcp` | A port accepts a connection. |
| `process` | A process with a given name or command line is running. |
| `windows-service` | A Windows service is in the running state. |
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

The web interface uses a login session, not a token.

Roles for people: `owner`, `member`, and `viewer`. A viewer sees everything except secrets and keys.

## Conventions

- Base path `/api/v1`. Within v1, changes only ever add. Unknown fields are ignored by both sides.
- Requests and answers are JSON unless stated.
- Keys travel as `Authorization: Bearer <key>`.
- Times are RFC 3339 in UTC.
- Lists use cursors. A list answer is `{"items": [...], "next": "<cursor or null>"}` and the next page is asked for with `?cursor=`.
- Lists take `q` (search), `machine`, `service`, `environment`, `from` and `to` wherever those make sense.
- An error answer is `{"error": {"code": "...", "message": "..."}}`.
- `401` for a missing or bad key, `403` for a key without the scope, `404` for something that does not exist or that the key may not know exists, `413` for too large, `422` for a body that does not fit this contract, `429` with `Retry-After` when the server is busy.

### Encryption

Two supported ways on a local network:

1. A real certificate, from a reverse proxy or a private overlay network.
2. Pinning. The enrol command copied from the interface carries the server certificate's fingerprint. `dokkit` stores it and refuses any other server from then on.

There is no switch that skips verification.

### Clocks

The server stamps every item with its own receive time and records the sender's clock offset. "Last seen" is always the server's time. An item dated in the future is clamped to the receive time.

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

Answers `{"machine": "<id>", "key": "dkm_..."}`. The token is spent.

### `POST /report`

The main door. The body is newline-delimited JSON, one item per line, optionally gzip-compressed (`Content-Encoding: gzip`). The header `Dokkit-Batch: <uuid>` names the batch; sending the same batch again stores nothing twice.

The answer:

```json
{"accepted": 412, "refused": [{"line": 17, "code": "unknown_service", "message": "..."}]}
```

A refused line does not fail the batch.

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
{"service": "upload-portal", "version": "2.3.0", "machine": "<id>", "commit": "abc123", "by": "ci"}
```

For CI. A deploy is also recorded automatically whenever a service's reported version changes, so most apps never call this.

### Taking work

```
GET /work?wait=50
```

`dokkit` asks for work and the server holds the request for up to 50 seconds. `204` means nothing to do; ask again. Otherwise:

```json
{"run": "<id>", "task": "security-scan", "command_sha256": "<hex>"}
```

`command_sha256` is the SHA-256 of the command that was accepted. `dokkit` runs the task only when the command in its own file has the same one.

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

A login session, or a user token with `read`. Log contents need `read-logs`.

| Call | Gives |
|---|---|
| `GET /inbox` | What needs a look, what will soon, and what was found and is not watched, with counts. |
| `GET /machines`, `GET /machines/<id>` | Machines, their vitals and thresholds. |
| `GET /services`, `GET /services/<id>` | Services. One service includes its checks, facts, routing, version on each machine, recent deploys and open issues. |
| `GET /services/<id>/series` | Chart data. Takes `metric`, `from`, `to` and `points`. |
| `GET /issues`, `GET /issues/<id>` | Issues and their history. |
| `GET /jobs`, `GET /jobs/<id>/runs` | Jobs with schedule, last run, last good run and next expected run; then the runs. |
| `GET /logs` | Log search. Takes `q`, `level`, `machine`, `service`, `from`, `to`. |
| `GET /errors`, `GET /errors/<id>` | Errors grouped by type and place; then the individual reports. |
| `GET /deploys` | Deploy history. |
| `GET /versions` | Which version of each service is on which machine. |
| `GET /rules` | Alert rules. |
| `GET /proposals` | Things waiting to be accepted. |
| `GET /tasks`, `GET /task-runs` | Accepted tasks and their runs. |

## Act

A login session, or a user token with `act`.

| Call | Does |
|---|---|
| `POST /issues/<id>/snooze` | Snooze until a time. `{"until": "..."}` |
| `POST /issues/<id>/unsnooze` | Bring it back. |
| `POST /issues/<id>/acknowledge` | Mark as seen. |
| `POST /issues/<id>/notes` | Add a note. |
| `POST /issues/bulk` | Any of the above for a list of issues. |
| `POST /services/<id>/watch`, `/unwatch` | Start or stop watching a found service. |
| `PUT /services/<id>/checks` | Edit checks added in the interface. Checks that came from a file are changed in the file. |
| `PUT /services/<id>/routing` | Who is told, by which channel, for `down` and for `degraded`. |
| `PUT /services/<id>/hold` | Mark a version on a machine as held on purpose. |
| `PUT /services/<id>/restart` | Allow or stop automatic restart. |
| `POST /proposals/<id>/accept`, `/dismiss` | Accept all or some of a proposal, or dismiss it. |
| `POST /rules`, `PUT /rules/<id>`, `DELETE /rules/<id>` | Alert rules. |
| `POST /tasks/<id>/run` | Run an accepted task on its machine. Answers with the run id. |

Keys, tokens and users are managed with the `admin` scope and are never offered through the MCP.
