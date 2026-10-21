# The Dokkit API

Dokkit watches machines, services and jobs. This is the HTTP API that the `dokkit` program, the command line, the client libraries, the MCP server and any script use.

Every call carries a key as `Authorization: Bearer <key>`. Key prefixes: `dke_` enrolment token, `dkm_` machine key, `dka_` app key (write only), `dku_` user token with the scopes `read`, `read-logs`, `act`, `admin`.


## Intake

Machines and apps send reports, deploys and declarations. Machine key or app key.


### POST /api/v1/enrol

Trade an enrolment token for a machine key. Spends a one-use enrolment token and makes the machine. The answer holds the machine key, shown once. A name that is already enrolled answers 409 and the token is kept, unless the token was made for that machine; then it enrols again and revokes that machine's earlier keys. Takes no key in the header. The enrolment token (`dke_`) goes in the body.


Send:

```
{
  "token": "dke_3kQ9xV2mTn7LwRb8",
  "hostname": "db-01",
  "os": "windows",
  "arch": "amd64",
  "dokkit": "0.1.0"
}
```

`200` The machine and its key.

```json
{
  "machine": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "key": "dkm_7Hq2pXz4Yc9VnB1a"
}
```

`401` Missing or bad key.

`409` Conflict.

`422` The body does not fit.

### POST /api/v1/report

Send a batch of lines. The main door. The body is newline-delimited JSON, one item per line, with a `type` and an `at` or `t`. The types are `state`, `inventory`, `metric`, `beat`, `job`, `stats`, `log`, `deploy` and `custom`. A batch is at most 5 MB compressed and 10,000 lines. A refused line does not fail the batch. Send the same `Dokkit-Batch` id again and nothing is stored twice. An app key may not send `state` or `inventory`, and may make 100 checks per service. Any line may carry `environment`: a value other than `production` is stored on a sibling service of that environment that never alerts, unless the service is declared by a `dokkit.toml`, which keeps its own environment. Takes a machine key (`dkm_`) or an app key (`dka_`).

- `Dokkit-Batch` (header, optional): Names the batch. Sending it again stores nothing twice.
- `Content-Encoding` (header, optional): Set to gzip when the body is compressed.

Send:

```
{"type":"job","service":"nightly-purge","name":"nightly-purge","run":"r-2041","event":"ok","exit_code":0,"duration_ms":81234}
{"type":"log","t":"2026-10-05T21:14:03.120Z","level":"error","msg":"Upload failed","service":"upload-portal","fields":{"route":"/upload","status":500}}

```

`200` How many lines were accepted, and the ones refused.

```json
{
  "accepted": 1,
  "refused": [
    {
      "line": 2,
      "code": "unknown_service",
      "message": "No service \"upload-portal\" on this machine."
    }
  ]
}
```

`401` Missing or bad key.

`413` Too large.

`422` The batch id is not a UUID (`bad_batch`), or the body is not valid gzip (`bad_gzip`).

### GET /api/v1/in/{key}/job/{name}/{event}

Ping a job with a web request. For anything that can only make a web request, such as a cron job on a storage box. `start`, `ok` and `fail` record the run. Any other event answers 404. Takes an app key (`dka_`).

- `key` (path): An app key (`dka_`). It travels in the address because the callers can only make a web request.
- `name` (path): The job's name.
- `event` (path): What happened.
- `run` (query, optional): Ties a start to its finish.

`200` Recorded.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`404` Not found.

`413` Too large.

`422` The body does not fit.

### POST /api/v1/in/{key}/job/{name}/{event}

Ping a job and keep its output. Same as the GET. The body, if there is one, is kept as the last lines of the job's output, at most 16 KB. Any content type is accepted. Takes an app key (`dka_`).

- `key` (path): An app key (`dka_`). It travels in the address because the callers can only make a web request.
- `name` (path): The job's name.
- `event` (path): What happened.
- `run` (query, optional): Ties a start to its finish.

Send:

```
Purged 412 files.
Done.

```

`200` Recorded.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`404` Not found.

`413` Too large.

`422` The body does not fit.

### PUT /api/v1/declare

Declare a service from a dokkit.toml. The contents of a `dokkit.toml`, sent as JSON with the same structure. Sending the same file twice changes nothing. Checks, jobs, logs and stats become active. The file owns the service and its checks, so checks it no longer lists are removed. A machine key may declare any service on its machine. An app key may declare only the service it belongs to: `service.id` must be its slug (else 422), the machine and kind stay, checks may be of type `beat` or `custom` only, jobs keep `id`, `schedule`, `grace` and `max_runtime`, and the other sections are dropped. Takes a machine key (`dkm_`) or an app key (`dka_`).


Send:

```
{
  "schema": 1,
  "service": {
    "id": "upload-portal",
    "name": "Upload portal",
    "kind": "service"
  },
  "check": [
    {
      "type": "http",
      "name": "front-page",
      "url": "http://localhost:8080/health",
      "expect": 200
    }
  ]
}
```

`200` The service id.

```json
{
  "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The body does not fit.

### GET /api/v1/ping

Check the address, the key and the clock. Lets a machine check its address, its key and its clock. The answer holds the server's time. Takes a machine key (`dkm_`) or an app key (`dka_`).


`200` The key works.

```json
{
  "ok": true,
  "time": "2026-10-05T21:14:03.120000Z"
}
```

`401` Missing or bad key.

### POST /api/v1/proposals

Send what a scan found. What `dokkit scan` found, as the file was written. Nothing in it is active until a person accepts it in the interface. The server keeps running Windows services and systemd services, listening ports, scheduled jobs (`found.jobs`), containers that publish a TCP port and sites with an address, and leaves out what is already watched or was dismissed. A job is accepted as a job that waits for its first report. `notes` (a list of text) says what the scan could not see. Takes a machine key (`dkm_`).


Send:

```
{
  "os": "windows",
  "found": {
    "services": [
      {
        "name": "Spooler",
        "display": "Print Spooler",
        "state": "running"
      }
    ],
    "ports": [
      {
        "port": 5432,
        "program": "postgres.exe"
      }
    ]
  }
}
```

`200` How many things from this machine now wait.

```json
{
  "waiting": 2
}
```

`401` Missing or bad key.

`422` The body does not fit.

### POST /api/v1/deploys

Record a deploy from CI. For CI. `host` is the machine the version went onto, when that is not the machine the service lives on. A deploy is also recorded when a service's reported version changes, so most apps never call this. Takes a machine key (`dkm_`) or an app key (`dka_`).


Send:

```
{
  "service": "upload-portal",
  "version": "2.3.0",
  "host": "web-02",
  "commit": "abc123",
  "by": "ci"
}
```

`200` Recorded.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`422` The body does not fit.

### GET /api/v1/checks

Get the checks added in the interface. The checks added in the interface for this machine, for the `dokkit` program to run. Takes a machine key (`dkm_`).


`200` The checks.

```json
{
  "items": [
    {
      "service": "spooler",
      "name": "windows-service",
      "type": "windows-service",
      "config": {
        "name": "Spooler"
      },
      "restart": false
    }
  ]
}
```

`401` Missing or bad key.

### POST /api/events/raw

Report log lines from an app that logs to Seq. The door for apps and libraries written for Seq: Serilog.Sinks.Seq, seqlog, and the pino, winston and bunyan Seq transports. An app moves by changing its server address and API key. The body is CLEF (one JSON event a line, content type `application/vnd.serilog.clef`, or `?clef`), or Seq's older JSON form `{"Events": [...]}` with `Timestamp`, `Level`, `MessageTemplate`, `Properties`, `Exception` and `RenderedMessage`. Each event is stored as a log line of the app key's service, by the same path as `POST /api/v1/report`: the same limits (10,000 events and 5 MB a request) and no rate limit. Levels are mapped (`Verbose`, `Debug`, `Information`, `Warning`, `Error`, `Fatal` and the short forms), templates are rendered with the properties, properties become `fields`, an exception is kept as `fields.exception`. A property named `service`, `at` or `type` is kept as `service_name`, `seq_at` or `seq_type`. The same body is accepted at `POST /ingest/clef`, where newer Seq clients post CLEF. Takes an app key (`dka_`), in the `X-Seq-ApiKey` header or the `apiKey` query value. Answers as Seq does: `201` with `{"MinimumLevelAccepted": null}`, and errors as `{"Error": "..."}`.

- `clef` (query, optional): Present when the body is CLEF and the content type does not say so.
- `apiKey` (query, optional): The app key, when the client sends it in the query.
- `X-Seq-ApiKey` (header, optional): The app key.

Send:

```
{"@t":"2026-10-05T21:14:03.1200000Z","@mt":"Saved {File} in {Elapsed} ms","File":"a.pdf","Elapsed":41}
{"@t":"2026-10-05T21:14:04.0000000Z","@mt":"Failed {Id}","@l":"Error","@x":"System.IO.IOException: disk","Id":7}

```

`201` Stored.

```json
{
  "MinimumLevelAccepted": null
}
```

`400` The body is not CLEF or Seq's JSON, or no event could be stored.

`401` The key is missing or not an app key.

`413` More than 10,000 events or 5 MB.

### POST /api/v1/quiet

Say this machine is going down on purpose. A machine says it is going down on purpose for a while, such as for a restart. For that long from now, the machine going silent, and its services' and jobs' checks going down or missing, open no issue and send nothing. When the time is up the usual rules resume at once. A second call replaces the window; `for` of `0` ends it. Issues already open stay open. Takes a machine key (`dkm_`) and can only quiet the machine the key belongs to.


Send:

```
{
  "for": "15m",
  "reason": "nightly update"
}
```

`200` Done: when the window ends, or null when it was ended.

```json
{
  "ok": true,
  "until": "2026-10-12T03:20:00.000000Z"
}
```

`401` Missing or bad key, or not a machine key.

`422` `for` is missing, not a duration, or more than 4 hours.

### GET /api/v1/records

Get the found jobs whose runs are read from the machine's own record. The accepted found jobs on this machine whose runs the `dokkit` program reads from the system's own record (a Windows Task Scheduler task or a systemd timer) and reports, with no change to the job. `source` is `task-scheduler` or `systemd-timer`; `unit` is the task's path or the timer's name. Takes a machine key (`dkm_`).


`200` The jobs.

```json
{
  "items": [
    {
      "service": "nightly-export",
      "name": "nightly-export",
      "source": "task-scheduler",
      "unit": "\\Nightly export"
    }
  ]
}
```

`401` Missing or bad key.

## Errors

Error reports from an app, in Dokkit's own format or as Sentry envelopes. App key.


### POST /api/v1/errors

Report an error in Dokkit's format. One error report. Reports are grouped by `type` and the app's own frames. Message text is dropped unless the service's page is set to keep it. An error does not open an issue or alert anyone. Takes a machine key (`dkm_`) or an app key (`dka_`).


Send:

```
{
  "at": "2026-10-05T21:14:03.120Z",
  "service": "upload-portal",
  "release": "2.3.0",
  "environment": "production",
  "host": "web-02",
  "type": "TimeoutError",
  "handled": true,
  "frames": [
    {
      "file": "app/worker.py",
      "function": "run_job",
      "line": 212,
      "own": true
    }
  ],
  "tags": {
    "route": "/upload",
    "status": "500"
  }
}
```

`200` Recorded.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`422` The body does not fit.

### POST /api/{project}/envelope

Report errors from a Sentry SDK. The door for Sentry's open-source SDKs. An SDK is given an address made from an app key and Dokkit's host. Error events are stored; everything else is read and dropped, and the answer tells the SDK to stop sending those kinds. Gzip is accepted. The app key is read from the `X-Sentry-Auth` header, the `sentry_key` query value, or the envelope's first line. The `project` segment is whatever the SDK was given and is not used. Takes an app key (`dka_`).

- `project` (path): The project part of the address the SDK built.
- `sentry_key` (query, optional): The app key, when the SDK sends it in the query.
- `X-Sentry-Auth` (header, optional): Holds `sentry_key=<app key>` among its fields.
- `Content-Encoding` (header, optional): Set to gzip when the body is compressed.

Send:

```
{"event_id":"9ec79c33ec9942ab8353589fcb2e04dc","dsn":"https://dka_4Rm8@your.domain.com/1"}
{"type":"event"}
{"exception":{"values":[{"type":"TimeoutError","value":"upload timed out"}]},"release":"2.3.0"}

```

`200` Accepted. The `X-Sentry-Rate-Limits` header tells the SDK to stop sending kinds Dokkit drops.

```json
{}
```

`401` Missing or bad key.

`413` Too large.

`422` The body does not fit.

## Work

The `dokkit` program asks for work, sends its output and result, and fetches updates. Machine key.


### GET /api/v1/program/{target}

Download the newer dokkit program. The newer `dokkit` program this server holds, for a machine asked to fetch it. The target is the operating system and architecture, such as `windows-amd64`. Takes a machine key (`dkm_`).

- `target` (path): The kind of machine, as `<os>-<arch>`.

`200` The program file.

`401` Missing or bad key.

`404` Not found.

### GET /api/v1/work

Ask for work. The `dokkit` program asks for work and the server holds the request for up to `wait` seconds. 204 means nothing to do; ask again. The run's name is in `task`, and it is one of two. `dokkit:update` asks the program to fetch the newer copy the server holds. `dokkit:imessage` is offered only to the Mac chosen for iMessage and carries two more fields: `to`, the recipients, and `text`, the message. The program answers it on the result address with `exit_code` 0 when every recipient was sent to, 1 otherwise, or `refused` with the reason, and posts one line of output for each recipient. Takes a machine key (`dkm_`).

- `wait` (query, optional): Seconds to hold the request.

`200` A run to do.

```json
{
  "run": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "task": "dokkit:update"
}
```

`204` Nothing to do. Ask again.

`401` Missing or bad key.

### POST /api/v1/work/{run}/output

Send a chunk of output. A chunk of the running run's output, as plain text. The server keeps the last part. Takes a machine key (`dkm_`).

- `run` (path): The run id from `GET /work`.

Send:

```
The newer copy is in place.

```

`200` Kept.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`404` Not found.

### POST /api/v1/work/{run}/result

Send the result of a run. Either an exit code with the duration, or a refusal with the reason. A refusal is how the program says it will not do the run. Takes a machine key (`dkm_`).

- `run` (path): The run id from `GET /work`.

Send:

```
{
  "exit_code": 0,
  "duration_ms": 81234
}
```

`200` Kept.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`404` The run is not running on this machine, or the body is neither an exit code nor a refusal.

### GET /api/v1/releases/{version}/{file}

Download a release file. A file of a release, for the updater on a machine. Takes a machine key (`dkm_`).

- `version` (path): A release version. Letters, digits, dots, dashes and underscores; not starting with a dot.
- `file` (path): A file name in that release, such as `SHA256SUMS`. Same characters as a version.

`200` The file.

`401` Missing or bad key.

`404` Not found.

### GET /api/v1/update

Ask which version to move to. The updater on a machine tells the server what is installed and asks whether to move. The server remembers the versions, that the machine has an updater, and whether it hosts the server. 204 when no version is wanted, the server does not hold the wanted version completely, or every part the machine has is already on it; otherwise 200 with the version. Takes a machine key (`dkm_`).

- `program` (query, optional): The installed program version.
- `server` (query, optional): The installed server version. Left out when the machine does not run the server.
- `updater` (query, optional): The installed updater version.
- `os` (query, optional): 
- `arch` (query, optional): 

`200` Move to this version.

```json
{
  "version": "v1.2.3"
}
```

`204` Nothing to do.

`401` Missing or bad key.

### POST /api/v1/update/result

Report how an update went. The server keeps the last result for the machine and clears its wanted version when `ok` is true. Takes a machine key (`dkm_`).


Send:

```
{
  "version": "v1.2.3",
  "ok": true,
  "note": "program, updater"
}
```

`200` Kept.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`422` The input is not right.

## Read

Read issues, machines, services, jobs, logs, errors, deploys, rules and proposals. User token.


### GET /api/v1/proposals

List things waiting to be accepted. Found things that wait for a person to accept them, each with `origin` (`system`, `software` or `yours`; null when the machine's program did not say) and `why`. The operating system's own things (`origin` `system`) are left out unless `system` is true; the answer says how many in `hidden`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `machine` (query, optional): Only on this machine (id or name).
- `kind` (query, optional): service, port, job, container or site.
- `system` (query, optional): true includes the operating system's own findings (origin system), which are left out otherwise.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "kind": "service",
      "name": "Spooler",
      "detail": {
        "label": "Print Spooler",
        "saw": "Running"
      },
      "machine": "db-01",
      "origin": "software",
      "why": "Installed under C:\\Program Files\\Contoso"
    }
  ],
  "next": null,
  "hidden": {
    "total": 12,
    "machines": {
      "db-01": 12
    }
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/deploys

List deploys. Deploy history, newest first. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `machine` (query, optional): Only on this machine (id or name).
- `service` (query, optional): Only this service (id).
- `environment` (query, optional): Only in this environment.
- `from` (query, optional): Only from this time, RFC 3339.
- `to` (query, optional): Only up to this time, RFC 3339.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "Upload portal",
      "machine": "web-02",
      "version": "2.3.0",
      "from": "2.2.9",
      "commit": "abc123",
      "by": "ci",
      "how": "reported",
      "at": "2026-10-05T19:30:00Z"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/errors

List error groups. Error groups by type and place, newest first, from the newest 1,000. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `machine` (query, optional): Only on this machine (id or name).
- `service` (query, optional): Only this service (id).
- `environment` (query, optional): Only in this environment.
- `from` (query, optional): Only from this time, RFC 3339.
- `to` (query, optional): Only up to this time, RFC 3339.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "type": "TimeoutError",
      "top": {
        "file": "app/worker.py",
        "function": "run_job",
        "line": 212,
        "own": true
      },
      "count": 14,
      "first_seen": "2026-10-05T19:40:00Z",
      "last_seen": "2026-10-05T21:14:03Z",
      "release": "2.3.0",
      "host": "web-02",
      "handled": true,
      "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "Upload portal",
      "machine": "web-02"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/day

The last day. The last 24 hours in 48 half hours, for each machine, and the issues that opened in that time. The last cell is the half hour that holds `to`. A cell is `down` if an issue that was down overlapped it, else `degraded` if any issue overlapped it, else `quiet` if the machine was heard from, else `none` (no signal). An issue counts in the state it has now, for its whole life. Soon issues and issues of services that are not in production colour nothing. Takes a user token (`dku_`) with the `read` scope.

- `to` (query, optional): The end of the window, RFC 3339. Defaults to now.

`200` OK.

```json
{
  "from": "2026-01-09T12:30:00Z",
  "to": "2026-01-10T12:30:00Z",
  "machines": [
    {
      "id": "6f1c2a3e-0b7d-4c55-9a11-2d3f4e5a6b70",
      "name": "db-01",
      "cells": [
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "down",
        "down",
        "quiet",
        "quiet",
        "quiet"
      ]
    },
    {
      "id": "0a9e8d7c-1b2a-4f33-8c44-5d6e7f809a1b",
      "name": "web-02",
      "cells": [
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "degraded",
        "degraded"
      ]
    },
    {
      "id": "3c4d5e6f-7a8b-4c9d-a0b1-c2d3e4f50617",
      "name": "nas",
      "cells": [
        "none",
        "none",
        "none",
        "none",
        "none",
        "none",
        "none",
        "none",
        "none",
        "none",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet",
        "quiet"
      ]
    }
  ],
  "events": [
    {
      "at": "2026-01-10T10:05:00Z",
      "title": "db-01: Postgres is down",
      "machine": "db-01",
      "state": "down",
      "sent": "Paged",
      "closed_at": "2026-01-10T10:50:00Z"
    },
    {
      "at": "2026-01-10T11:40:00Z",
      "title": "web-02: Disk C is nearly full",
      "machine": "web-02",
      "state": "degraded",
      "sent": "Pushed",
      "closed_at": null
    }
  ]
}
```

`422` to is not an RFC 3339 time.

### GET /api/v1/inbox

What needs a look. What needs a look, what will soon, what was found and is not watched, what is snoozed, issues in other environments, and how many things are fine. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "needs_you": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "short_id": "DOK-12",
      "kind": "check",
      "state": "down",
      "title": "upload-portal is down",
      "note": "Connection refused",
      "count": 3,
      "since": "2026-10-05T20:41:00Z",
      "snoozed_until": null,
      "acknowledged_at": null,
      "machine": "web-02",
      "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "alert": {
        "channel": "page",
        "status": "sent"
      },
      "soon": false
    }
  ],
  "soon": [
    {
      "id": "9b2e4d10-77aa-4c3e-8f61-2a5c0d9e1b44",
      "short_id": "DOK-13",
      "kind": "check",
      "state": "degraded",
      "title": "Certificate for upload-portal expires in 12 days",
      "note": "12 days left",
      "count": 1,
      "since": "2026-10-05T20:41:00Z",
      "snoozed_until": null,
      "acknowledged_at": null,
      "machine": "web-02",
      "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "alert": {
        "channel": "push",
        "status": "sent"
      },
      "soon": true
    }
  ],
  "not_watched": [
    {
      "id": "c1d7a0f2-5e3b-4a96-b8d4-0f7e2a6c9b15",
      "kind": "port",
      "name": "5432",
      "detail": {
        "label": "Port 5432",
        "saw": "postgres"
      },
      "machine": "db-01"
    }
  ],
  "snoozed": [],
  "other_environments": [
    {
      "environment": "dev",
      "issues": []
    }
  ],
  "fine": {
    "services": 14,
    "machines": 5
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/issues

List issues. Issues, newest first: the open and snoozed ones, or those of `state`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `state` (query, optional): open, snoozed, closed or all. Left out: open and snoozed.
- `q` (query, optional): Only what contains this text.
- `machine` (query, optional): Only on this machine (id or name).
- `service` (query, optional): Only this service (id).
- `environment` (query, optional): Only in this environment.
- `from` (query, optional): Only from this time, RFC 3339.
- `to` (query, optional): Only up to this time, RFC 3339.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "short_id": "DOK-12",
      "kind": "check",
      "state": "down",
      "title": "upload-portal is down",
      "note": "Connection refused",
      "count": 3,
      "since": "2026-10-05T20:41:00Z",
      "snoozed_until": null,
      "acknowledged_at": null,
      "machine": "web-02",
      "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "alert": {
        "channel": "page",
        "status": "sent"
      }
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/issues/{id}

Get one issue. One issue, open or closed, with its notes. The id is the issue's uuid. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the issue.

`200` OK.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "short_id": "DOK-12",
  "kind": "check",
  "state": "down",
  "title": "upload-portal is down",
  "note": "Connection refused",
  "count": 3,
  "since": "2026-10-05T20:41:00Z",
  "snoozed_until": null,
  "acknowledged_at": null,
  "machine": "web-02",
  "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "alert": {
    "channel": "page",
    "status": "sent"
  },
  "closed_at": null,
  "notes": [
    {
      "text": "Restarted the pool.",
      "by": "token ci-bot"
    }
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/machines

List machines. Machines with their vitals. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `machine` (query, optional): Only on this machine (id or name).
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "db-01",
      "kind": "enrolled",
      "os": "windows",
      "last_seen_at": "2026-10-05T21:14:03Z",
      "down": false,
      "needs_a_look": 0,
      "vitals": {
        "disk_used_percent": 61.2
      }
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/machines/{id}

Get one machine. One machine with its services and its thresholds. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

`200` OK.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "db-01",
  "kind": "enrolled",
  "os": "windows",
  "last_seen_at": "2026-10-05T21:14:03Z",
  "down": false,
  "needs_a_look": 0,
  "vitals": {},
  "services": [],
  "thresholds": {
    "disk_used_percent": 90,
    "memory_used_percent": 90
  },
  "metrics": [
    {
      "name": "disk.used_percent.C",
      "value": 71.4,
      "at": "2026-10-05T21:14:03Z"
    }
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/machines/{id}/processes

Get a machine's newest process list. The newest list the machine sent, about once a minute. `count` is how many processes matched before `limit`. With nothing received yet: `at` null, `items` empty. Takes a user token (`dku_`) with the `read` scope.

- `id` (path): The id of the machine.
- `sort` (query, optional): `memory` (default) or `cpu`.
- `q` (query, optional): Matches the name or the path, any case.
- `pid` (query, optional): One process.
- `limit` (query, optional): How many items.

`200` OK.

`401` Missing or bad key.

`403` The key may not do this.

`404` No such machine.

### GET /api/v1/machines/{id}/processes/history

Get the top processes kept for a machine. The top 10 by memory or by processor of every list received, oldest first, for up to 24 hours back. Takes a user token (`dku_`) with the `read` scope.

- `id` (path): The id of the machine.
- `kind` (query, optional): `memory` (default) or `cpu`.
- `from` (query, optional): Start, RFC 3339. Defaults to an hour before `to`; nothing older than 24 hours is kept.
- `to` (query, optional): End, RFC 3339. Defaults to now.

`200` OK.

`401` Missing or bad key.

`403` The key may not do this.

`404` No such machine.

`422` A kind other than `memory` or `cpu`, a time that is not RFC 3339, or a `from` that is not before `to`.

### GET /api/v1/machines/{id}/series

Get chart data for a machine's own numbers. Without `metric`, the names of the metrics the machine reports itself (disks, memory, processor). With `metric`, its points between `from` and `to`. Answers 404 for an unknown machine, a time that is not RFC 3339, or a `from` that is not before `to`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer. Machine numbers are kept for 30 days.

- `id` (path): The id of the machine.
- `metric` (query, optional): The metric's name.
- `from` (query, optional): Start, RFC 3339. Defaults to 24 hours before `to`.
- `to` (query, optional): End, RFC 3339. Defaults to now.
- `points` (query, optional): How many points.

`200` OK.

```json
{
  "metric": "disk.used_percent.C",
  "points": [
    {
      "at": "2026-10-05T20:00:00Z",
      "value": 71.4
    }
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/services

List services. Services across machines. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Search the name and slug.
- `machine` (query, optional): A machine id or name.
- `service` (query, optional): Only this service (id).
- `environment` (query, optional): Only in this environment.
- `kind` (query, optional): service, job, dependency or app.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "slug": "upload-portal",
      "name": "Upload portal",
      "kind": "service",
      "environment": "production",
      "state": "ok",
      "note": null,
      "version": "2.3.0",
      "held": null,
      "machine": "web-02"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/services/{id}

Get one service. One service with its checks, facts, routing, version and open issue. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

`200` OK.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [
    {
      "name": "front-page",
      "type": "http",
      "state": "ok",
      "note": null,
      "value": 38,
      "checked_at": "2026-10-05T21:14:00Z",
      "source": "file",
      "config": {
        "url": "http://localhost:8080/health"
      }
    }
  ],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/services/{id}/series

Get chart data for a service. Without `metric`, the names of the metrics the service has. With `metric`, its points between `from` and `to`. Answers 404 for an unknown service, a time that is not RFC 3339, or a `from` that is not before `to`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.
- `metric` (query, optional): The metric's name.
- `from` (query, optional): Start, RFC 3339. Defaults to 24 hours before `to`.
- `to` (query, optional): End, RFC 3339. Defaults to now.
- `points` (query, optional): How many points.

`200` OK.

```json
{
  "metric": "queue_depth",
  "points": [
    {
      "at": "2026-10-05T20:00:00Z",
      "value": 4
    }
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/jobs

List jobs. Every job with its schedule, last run, last good run and next expected run. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `machine` (query, optional): Only on this machine (id or name).
- `service` (query, optional): Only this service (id).
- `environment` (query, optional): Only in this environment.
- `state` (query, optional): ok, degraded, down or unknown.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "nightly-purge",
      "machine": "nas",
      "state": "ok",
      "schedule": "0 2 * * *",
      "last_run": {
        "run": "r-2041",
        "result": "ok",
        "started_at": "2026-10-05T02:00:01Z",
        "finished_at": "2026-10-05T02:01:22Z",
        "exit_code": 0,
        "duration_ms": 81234,
        "tail": "Purged 412 files."
      },
      "last_good_run": null,
      "next_expected": "2026-10-06T02:00:00Z",
      "grace": "30m",
      "max_runtime": null
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/jobs/{id}/runs

List the runs of a job. The recent runs of one job, up to 100. The id is the job's service id. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the job's service.
- `result` (query, optional): running, ok or fail.
- `from` (query, optional): Only from this time, RFC 3339.
- `to` (query, optional): Only up to this time, RFC 3339.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "run": "r-2041",
      "result": "ok",
      "started_at": "2026-10-05T02:00:01Z",
      "finished_at": "2026-10-05T02:01:22Z",
      "exit_code": 0,
      "duration_ms": 81234,
      "tail": "Purged 412 files."
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/logs

Search log lines. Log lines, newest first, at most 500. `level` is that level and worse. Answers 404 for an unknown machine or service, or a time that is not RFC 3339. Takes a user token (`dku_`) with the `read-logs` scope.

- `q` (query, optional): Search text.
- `level` (query, optional): That level and worse.
- `machine` (query, optional): A machine id or name.
- `service` (query, optional): A service id.
- `from` (query, optional): Start, RFC 3339.
- `to` (query, optional): End, RFC 3339.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "t": "2026-10-05T21:14:03.120Z",
      "level": "error",
      "msg": "Upload failed",
      "fields": {
        "route": "/upload",
        "status": 500
      },
      "machine": "web-02",
      "service": "upload-portal"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/errors/{id}

Get one error group. One group with the stack and tags of its latest report. The message is there only when the service keeps messages, and needs `read-logs`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer. `reports` lists the group's individual reports, newest first, as `{items, next}`; `cursor` and `limit` page them.

- `id` (path): The id of the error group.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "type": "TimeoutError",
  "count": 14,
  "first_seen": "2026-10-05T19:40:00Z",
  "last_seen": "2026-10-05T21:14:03Z",
  "handled": true,
  "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "Upload portal",
  "machine": "web-02",
  "frames": [
    {
      "file": "app/worker.py",
      "function": "run_job",
      "line": 212,
      "own": true
    }
  ],
  "tags": {
    "route": "/upload"
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/versions

Which version is where. Which version of each service is on which machine, and under `apps`, each app that runs on many hosts with the hosts on each version. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "items": [
    {
      "slug": "upload-portal",
      "name": "Upload portal",
      "on": [
        {
          "machine": "web-02",
          "version": "2.3.0",
          "held": null,
          "environment": "production"
        }
      ]
    }
  ],
  "apps": [],
  "next": null,
  "program": {
    "held": "0.2.0",
    "machines": [
      {
        "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
        "machine": "web-02",
        "version": "0.1.0"
      }
    ]
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/rules

List alert rules. Alert rules, first match first. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "kind": "job",
      "state": "down",
      "machine": "nas",
      "channel": "email",
      "on": true
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/alerts

Alert settings. Who is told by default, the limits, the night and the mail settings. Addresses, user names, the Twilio account SID and secrets are shown only as `set` or `not set`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "down": "page",
  "degraded": "push",
  "push_with": "ntfy",
  "disk_limit": "90",
  "memory_limit": "95",
  "night_from": "22",
  "night_to": "7",
  "night_offset": "0",
  "email_to": "oncall@example.com",
  "pagerduty_key": "set",
  "ntfy_url": "not set",
  "webhook_url": "not set",
  "smtp_password": "not set"
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/alerts/suggestions

Alert suggestions. Issues that opened six times or more in a month and are snoozed, where the daily digest could take them instead. Nothing changes until a person accepts. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "service": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "Flaky sync",
      "state": "down",
      "count": 6
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/logs/archives

Archived months of logs. The archived months of logs that can be loaded back. Takes a user token (`dku_`) with the `read-logs` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "items": [
    {
      "name": "logs-2025-01",
      "size": 1048576,
      "back_until": null
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/releases

List the releases held. The versions this server holds for the updaters, newest first, each with its file names and whether it has both `SHA256SUMS` and `SHA256SUMS.sig`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` The releases.

```json
{
  "items": [
    {
      "version": "v1.2.3",
      "files": [
        "SHA256SUMS",
        "SHA256SUMS.sig",
        "dokkit-windows-x64",
        "dokkit-windows-x64.zip"
      ],
      "complete": true
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/certificate

The certificates served. The certificate the server was installed with and the one put in place with `PUT`, each `null` when there is none. Never a key. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` The certificates.

```json
{
  "installed": {
    "names": [
      "web-01"
    ],
    "issuer": "web-01",
    "not_after": "2036-10-01T13:00:00Z",
    "self_signed": true,
    "sha256": "a99f59d72d4fe3caf976fa019c671dc3e184b9f9c4e7b6ce4494e9c85df1ad3d"
  },
  "uploaded": {
    "names": [
      "example.dokkit.dev"
    ],
    "issuer": "R11",
    "not_after": "2027-01-19T13:00:00Z",
    "self_signed": false,
    "sha256": "069ea4a89410f21e10658bbdb91aa9555af7e39294d4c08e999c7765ddf0d390"
  },
  "renewal": {
    "at": "2026-12-20T03:00:00Z",
    "ok": true,
    "note": "Renewed, runs out 2027-03-20"
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/machines/{id}/quiet/schedules

A machine's scheduled planned downtime. The planned downtime scheduled for the machine, as `{items, next}`. Each item has `id`, `repeat` (`once`, `daily` or `weekly`), `at` (for `once`), `time` (for the repeating kinds, in the server's night time zone, or UTC when none is set), `days` (1 for Monday to 7 for Sunday), `for_seconds`, `reason`, `by` and `next` (the next start, or null). Takes a user token (`dku_`) with the `read` scope. 404 when the machine is not an enrolled machine.

- `id` (path): The id of the machine.

`200` The schedules.

```json
{
  "items": [
    {
      "id": "0b6f2d54-8a1e-4e0c-9d7b-2f3a61c4d8e5",
      "repeat": "daily",
      "at": null,
      "time": "02:00",
      "days": [
        1,
        2,
        3,
        4,
        5,
        6,
        7
      ],
      "for_seconds": 1800,
      "reason": "nightly update",
      "by": "ana",
      "next": "2026-10-14T09:00:00.000000Z"
    }
  ],
  "next": null
}
```

`403` The key may not do this.

`404` Not found.

### GET /api/v1/alerts/people

People alerts can be told. Each person on the server with the destinations they have of their own. The ntfy address, the Pushover user key and the PagerDuty routing key are only `set` or `not set`. Takes a user token (`dku_`) with the `read` scope.


`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "ada",
      "role": "member",
      "email": "ada@example.com",
      "phone": "+15555550100",
      "imessage": null,
      "ntfy_url": "set",
      "pushover_user": "not set",
      "pagerduty_key": "not set"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/alerts/who

Who is told at each level. Where someone is named: the default, a rule, a service or a check. The most specific level that names someone decides: the check, then the service, then the rule, then the default. A level that names nobody is left to the level above, and the default is everyone. Takes a user token (`dku_`) with the `read` scope.


`200` OK.

```json
{
  "items": [
    {
      "scope": "service",
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "to": [
        "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f4"
      ]
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/settings

The values for the whole server. Every value Dokkit decides on its own, server-wide: how alerts are retried and repeated, the defaults for every machine and job, how services are checked, what is kept and for how long, and sign-in limits. `values` is each value now, `defaults` the built-in value and `changed` the names that differ. `disk_on`, `disk_limit`, `memory_on` and `memory_limit` are the same limits as `disk_limit` and `memory_limit` in `/api/v1/alerts`. Takes a user token (`dku_`) with the `read` scope.


`200` The values.

```json
{
  "values": {
    "disk_on": true,
    "disk_limit": 85,
    "disk_after": 3,
    "disk_down": 98
  },
  "defaults": {
    "disk_on": true,
    "disk_limit": 90,
    "disk_after": 3,
    "disk_down": 98
  },
  "changed": [
    "disk_limit"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/machines/{id}/settings

The values for one machine. The values that can differ by machine: disk, memory and processor alerts, when it counts as gone quiet, the disk forecast, how often the program reports and scans. `defaults` is the server-wide value each falls back to. The program on the machine is sent its reporting and scanning values with its checks. Takes a user token (`dku_`) with the `read` scope.

- `id` (path): The id of the machine.

`200` The values.

```json
{
  "values": {
    "disk_on": true,
    "disk_limit": 85,
    "disk_after": 3,
    "disk_down": 98
  },
  "defaults": {
    "disk_on": true,
    "disk_limit": 90,
    "disk_after": 3,
    "disk_down": 98
  },
  "changed": [
    "disk_limit"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/jobs/{id}/settings

The values for one job. The values that can differ by job: its grace, when it has run too long, whether a missed run alerts, and how long its runs are kept. `defaults` is what the job's own file or timing says, else the server-wide value. Takes a user token (`dku_`) with the `read` scope.

- `id` (path): The id of the job, which is its service id.

`200` The values.

```json
{
  "values": {
    "disk_on": true,
    "disk_limit": 85,
    "disk_after": 3,
    "disk_down": 98
  },
  "defaults": {
    "disk_on": true,
    "disk_limit": 90,
    "disk_after": 3,
    "disk_down": 98
  },
  "changed": [
    "disk_limit"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

## Act

Snooze and acknowledge issues, route and hold services, accept found things, keep error text and set when a job is late. User token with `act`.


### POST /api/v1/issues/{id}/snooze

Snooze an issue. Snoozes an issue until a time. An unknown issue answers 404. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the issue.

Send:

```
{
  "until": "2026-10-06T08:00:00Z"
}
```

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The body does not fit.

### POST /api/v1/issues/{id}/unsnooze

Bring a snoozed issue back. Brings a snoozed issue back. An unknown issue answers 404. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the issue.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/issues/{id}/acknowledge

Mark an issue as seen. Marks an issue as seen. An unknown issue answers 404. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the issue.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/issues/{id}/notes

Add a note to an issue. Adds a note. The note is signed with the token's label. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the issue.

Send:

```
{
  "text": "Restarted the upload pool on web-02."
}
```

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The body does not fit.

### POST /api/v1/issues/bulk

Snooze, unsnooze or acknowledge many issues. Does one action to a list of issue ids. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "ids": [
    "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3"
  ],
  "action": "snooze",
  "until": "2026-10-06T08:00:00Z"
}
```

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The body does not fit.

### POST /api/v1/services/{id}/watch

Start watching a found service. Starts watching a found service. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

`200` The service after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/services/{id}/unwatch

Stop watching a service. Stops watching a service. Open issues close and what the checks said is forgotten. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

`200` The service after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### PUT /api/v1/services/{id}/routing

Set who is told about a service. Sets the channels for `down` and for `degraded`, each one channel or a list of channels that each send their own alert. A field that is not sent stays as it was; a value that is not a channel clears that route. `none` cannot be combined with other channels (422 `bad_routing`). `night` is optional; false holds the alerts of a night until it ends. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

Send:

```
{
  "down": [
    "page",
    "email"
  ],
  "degraded": "digest",
  "night": false
}
```

`200` The routing now in force.

```json
{
  "down": "page,email",
  "degraded": "digest",
  "night": false,
  "down_channels": [
    "page",
    "email"
  ],
  "degraded_channels": [
    "digest"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` `none` was combined with other channels.

### PUT /api/v1/services/{id}/hold

Hold a version on purpose. Marks a version as held on purpose. An empty or missing `version` clears the hold. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

Send:

```
{
  "version": "2.2.9"
}
```

`200` The service after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/proposals/{id}/accept

Accept a found thing. Accepts a found service or port, so it is watched. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer. A hidden (system) proposal can be named by its id.

- `id` (path): The id of the proposal.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/proposals/{id}/dismiss

Dismiss a found thing. Dismisses a found thing so it is not offered again. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer. A hidden (system) proposal can be named by its id.

- `id` (path): The id of the proposal.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### PUT /api/v1/services/{id}/messages

Keep or stop keeping error text. Keeps the text of a service's errors from now on, or stops keeping it. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

Send:

```
{
  "keep": true
}
```

`200` The service after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null,
  "keep_messages": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The input is not right.

### PUT /api/v1/jobs/{id}/timing

Set when a job is late. Sets when a job counts as late (grace) and as run too long (max_runtime). A field left out stays as it was; an empty one clears it. A job from a dokkit.toml is changed in the file. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the job, which is its service id.

Send:

```
{
  "grace": "45m",
  "max_runtime": "2h"
}
```

`200` The job after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "nightly-purge",
  "machine": "nas",
  "state": "ok",
  "schedule": "0 2 * * *",
  "grace": "45m",
  "max_runtime": "2h",
  "last_run": null,
  "last_good_run": null,
  "next_expected": "2026-10-06T02:00:00Z"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The input is not right.

### POST /api/v1/proposals/accept

Accept found things. Accepts some found services and ports (`ids`) or every one waiting and shown (`all` true; the operating system's own only with `system` true), so they are watched. Answers `done`, the ids acted on; `404` when none of them is waiting. Takes a user token (`dku_`) with the `act` scope.


Send:

```
{
  "ids": [
    "8f0f6f58-0000-0000-0000-000000000000"
  ]
}
```

`200` Done.

### POST /api/v1/proposals/dismiss

Dismiss found things. Dismisses some proposals (`ids`) or every one waiting and shown (`all` true; the operating system's own only with `system` true). Answers `done`, the ids acted on; `404` when none of them is waiting. Takes a user token (`dku_`) with the `act` scope.


Send:

```
{
  "ids": [
    "8f0f6f58-0000-0000-0000-000000000000"
  ]
}
```

`200` Done.

### POST /api/v1/machines/{id}/quiet/schedules

Schedule planned downtime for a machine. Schedules a window that the server starts by itself, once at a time or repeating. A window it starts is not ended early when the machine comes back; it ends when its time is up or when someone ends it. If the server was down at the start, the window covers the time that is left. Answers with the schedule. 404 when the machine is not an enrolled machine; 422 `bad_duration` or `bad_schedule` for a bad length, repeat, time, days or a `once` time in the past. Takes a user token (`dku_`) with the `act` scope.

- `id` (path): The id of the machine.

Send:

```
{
  "repeat": "weekly",
  "time": "02:00",
  "days": [
    1,
    3
  ],
  "for": "30m",
  "reason": "nightly update"
}
```

`200` The schedule.

```json
{
  "id": "0b6f2d54-8a1e-4e0c-9d7b-2f3a61c4d8e5",
  "repeat": "weekly",
  "at": null,
  "time": "02:00",
  "days": [
    1,
    3
  ],
  "for_seconds": 1800,
  "reason": "nightly update",
  "by": "token ops",
  "next": "2026-10-14T09:00:00.000000Z"
}
```

`403` The key may not do this.

`404` Not found.

`422` A bad length, repeat, time or days.

### DELETE /api/v1/machines/{id}/quiet/schedules/{schedule}

Remove a scheduled planned downtime. Removes the schedule. A window it already started keeps running; end it with `DELETE /machines/{id}/quiet`. Takes a user token (`dku_`) with the `act` scope.

- `id` (path): The id of the machine.
- `schedule` (path): The id of the schedule.

`200` Done.

```json
{
  "ok": true
}
```

`403` The key may not do this.

`404` Not found.

### PUT /api/v1/machines/{id}/routing

Set how a machine that stops reporting is announced. Sets the channels used when this machine stops reporting (`down`: one channel or a list; empty uses the server-wide choice for down) and whether the alert may wake someone at night (`night`, default true; false holds it until the night ends). A field that is not sent stays as it was. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

Send:

```
{
  "down": [
    "page"
  ],
  "night": true
}
```

`200` The routing now in force.

```json
{
  "down": "page",
  "down_channels": [
    "page"
  ],
  "night": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` `none` was combined with other channels.

## Admin

Keys, people, alert rules and settings, interface-added checks, restart, making jobs, updating the program and loading logs back. User token with `admin`.


### POST /api/v1/apps

Add an app that runs on many machines. Adds an app, such as a desktop program, that belongs to no one machine. Its key is returned once and goes into the app's build. Takes a user token (`dku_`) with the `admin` scope.


Send:

```
{
  "name": "Label printer"
}
```

`200` The app, with its key shown once.

```json
{
  "id": "5f0c1c0e-2a52-4c0f-9d5e-6f1b2f9a7c11",
  "name": "Label printer",
  "slug": "label-printer",
  "key": "dka_..."
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The input is not right.

### POST /api/v1/jobs

Add a job to watch. Adds a job and its machine if it is new. The key and the addresses the job calls are returned once. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "name": "Weekly report",
  "machine": "nas",
  "schedule": "0 2 * * 1",
  "grace": "20m"
}
```

`200` The job, with its key shown once.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "Weekly report",
  "key": "dka_3f9c0d2e7b4a",
  "ping": {
    "start": "https://your.domain.com/api/v1/in/dka_3f9c0d2e7b4a/job/weekly-report/start",
    "ok": "https://your.domain.com/api/v1/in/dka_3f9c0d2e7b4a/job/weekly-report/ok",
    "fail": "https://your.domain.com/api/v1/in/dka_3f9c0d2e7b4a/job/weekly-report/fail"
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The input is not right.

### POST /api/v1/rules

Add an alert rule. Adds a rule to the end of the list. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "kind": "job",
  "state": "down",
  "machine": "nas",
  "channel": "email"
}
```

`200` The new rule.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "kind": "job",
  "state": "down",
  "machine": "nas",
  "channel": "email",
  "on": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

### PUT /api/v1/services/{id}/checks

Replace the checks added in the interface. Replaces the checks added in the interface. Checks that came from a file are changed in the file. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

Send:

```
{
  "checks": [
    {
      "name": "front-page",
      "type": "http",
      "config": {
        "url": "http://localhost:8080/health"
      },
      "fail_after": 3
    }
  ]
}
```

`200` The service after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The body does not fit.

### PUT /api/v1/services/{id}/restart

Allow or stop automatic restart. Allows or stops automatic restart of a service. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

Send:

```
{
  "allow": true
}
```

`200` The service after the change.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "slug": "upload-portal",
  "name": "Upload portal",
  "kind": "service",
  "environment": "production",
  "state": "ok",
  "note": null,
  "version": "2.3.0",
  "held": null,
  "machine": "web-02",
  "checks": [],
  "routing": {
    "down": "page",
    "degraded": null
  },
  "restart": false,
  "stats": null,
  "stats_at": null,
  "open_issue": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### PUT /api/v1/rules/{id}

Change an alert rule. Changes a rule: a field left out stays as it was and an empty one clears it. A kind, state or channel that is not one of its choices, null, or a machine that is not text answers 422. Its place in the order stays. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the rule.

Send:

```
{
  "kind": "job",
  "state": "down",
  "machine": "nas",
  "channel": "page",
  "on": true
}
```

`200` The rule.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "kind": "job",
  "state": "down",
  "machine": "nas",
  "channel": "page",
  "on": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### DELETE /api/v1/rules/{id}

Delete an alert rule. Deletes a rule. Deleting one that is not there still answers ok. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the rule.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

### POST /api/v1/add-script

Make the script that adds a Windows machine. Makes a one-use enrolment token that lasts 24 hours and returns a PowerShell script holding it, the server address, the certificate fingerprint when one is needed, and the newest complete release. Run on the machine as administrator, the script fetches the program from this server with the token, checks the release signature and the file's checksum, enrols, installs the service and the updater, checks it reports and offers to delete itself. Takes a user token (`dku_`) with the `admin` scope.


Send:

```
{
  "name": "reception"
}
```

`200` The key, shown once.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "key": "dku_7Hq2pXz4Yc9VnB1aQw3E"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The body does not fit.

### GET /api/v1/keys

List keys. Every key that still works, newest first. The key text is never shown again; `hint` is the start of it. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `kind` (query, optional): user, app, enrol or machine.
- `machine` (query, optional): Only on this machine (id or name).
- `from` (query, optional): Only from this time, RFC 3339.
- `to` (query, optional): Only up to this time, RFC 3339.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` The keys.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "kind": "user",
      "hint": "dku_7Hq2",
      "label": "ci-bot",
      "scopes": [
        "read",
        "act"
      ],
      "used_at": null,
      "expires_at": null,
      "inserted_at": "2026-10-05T19:00:00Z",
      "machine": null,
      "service": null
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### POST /api/v1/keys

Make a key. Makes a user token with a label and scopes (only scopes the calling token holds, and never `admin`, which is made in Settings), an app key for a service, or a one-use enrolment token that lasts an hour. The key is shown once, in this answer. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "kind": "user",
  "label": "ci-bot",
  "scopes": [
    "read",
    "act"
  ]
}
```

`200` The key, shown once.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "key": "dku_7Hq2pXz4Yc9VnB1aQw3E"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The body does not fit.

### DELETE /api/v1/keys/{id}

Revoke a key. Revokes a key. It stops working at once. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the key.

`200` Revoked.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/phones

List phones. The phones paired to read this server through its relay. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


`401` Missing or bad key.

`403` The key may not do this.

`200` The phones.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "Work iPhone",
      "added_at": "2026-10-13T09:00:00Z",
      "last_fetch_at": null
    }
  ],
  "next": null
}
```

### POST /api/v1/phones

Pair a phone. Makes a phone with its own key and slot, and uploads at once. The answer holds `code`, the text a QR code carries, shown once: it holds the fetch token and the phone's key. The relay must be set first. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


Send:

```
{
  "name": "Work iPhone"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`200` The phone, with its code.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "Work iPhone",
  "added_at": "2026-10-13T09:00:00Z",
  "last_fetch_at": null,
  "code": "dokkit-phone:1:eyJyZWxheSI6Imh0dHBzOi8vcmVsYXkuZXhhbXBsZS5jb20ifQ"
}
```

`422` The body does not fit.

### GET /api/v1/phones/relay

The relay. The relay phones are served through. The upload key is only set or not set. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


`401` Missing or bad key.

`403` The key may not do this.

`200` The relay.

```json
{
  "address": "https://relay.example.com",
  "mailbox": "92bea4d52a1d53f0c8111edf39e26a89",
  "key": "set",
  "last_good_upload": "2026-10-13T09:01:00Z",
  "last_error": null
}
```

### PUT /api/v1/phones/relay

Set the relay. Saves the relay, then makes one upload and says whether the relay took it. `address` may end in `/m/<mailbox>`, as `dokkit relay add` prints it. A key left out stays. A different mailbox removes every phone; the same one keeps them. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


Send:

```
{
  "address": "https://relay.example.com",
  "mailbox": "92bea4d52a1d53f0c8111edf39e26a89",
  "key": "dkr_..."
}
```

`401` Missing or bad key.

`403` The key may not do this.

`200` The relay, and what the upload did.

```json
{
  "address": "https://relay.example.com",
  "mailbox": "92bea4d52a1d53f0c8111edf39e26a89",
  "key": "set",
  "last_good_upload": "2026-10-13T09:01:00Z",
  "last_error": null,
  "uploaded": true,
  "result": "The relay took the snapshot."
}
```

`422` The body does not fit.

### POST /api/v1/phones/relay/shared

Use the shared relay. Asks the shared relay for a new mailbox and saves its address, mailbox and upload key as the relay, then makes one upload and says whether the relay took it, as setting the relay does. The shared relay is `https://relay.dokkit.dev` unless `DOKKIT_SHARED_RELAY` names another. A different mailbox removes every phone. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


`401` Missing or bad key.

`403` The key may not do this.

`200` The relay, and what the upload did.

```json
{
  "address": "https://relay.example.com",
  "mailbox": "92bea4d52a1d53f0c8111edf39e26a89",
  "key": "set",
  "last_good_upload": "2026-10-13T09:01:00Z",
  "last_error": null,
  "uploaded": true,
  "result": "The relay took the snapshot."
}
```

`422` The shared relay made no mailbox, or what it gave could not be saved.

### DELETE /api/v1/phones/{id}

Remove a phone. Removes a phone and uploads at once without its slot, so its token stops working. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.

- `id` (path): The id of the phone.

`401` Missing or bad key.

`403` The key may not do this.

`200` Removed.

```json
{
  "ok": true
}
```

`404` No such phone.

### GET /api/v1/users

List people. The people who can sign in. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `q` (query, optional): Only what contains this text.
- `cursor` (query, optional): The `next` of an earlier answer, for the following page.
- `limit` (query, optional): Items in a page: 1 to 500, 100 when left out (500 for logs).

`200` The people.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "sam",
      "role": "owner"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### POST /api/v1/users

Add a person. Adds a person who can sign in. Roles are `owner`, `member` and `viewer`. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "name": "sam",
  "role": "member",
  "password": "a long passphrase"
}
```

`200` The person.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "sam",
  "role": "member"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The body does not fit.

### DELETE /api/v1/users/{id}

Remove a person. Removes a person. Their user tokens stop working. The last owner cannot be removed. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the person.

`200` Removed.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The body does not fit.

### POST /api/v1/machines/{id}/update

Approve a release for a machine, or ask it to fetch the program. With `version`, sets the machine's wanted version, and only to a version the server holds completely (422 `not_held`, or `bad_version` when it is not `v` and three numbers). The updater on the machine does the rest. Without a body, asks an enrolled machine to fetch the newer `dokkit` program from this server, which a person finishes on the machine; 422 when the server holds no program. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

Send:

```
{
  "version": "v1.2.3"
}
```

`200` Asked: the version; or the run id of the fetch.

```json
{
  "ok": true,
  "version": "v1.2.3"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The input is not right.

### PUT /api/v1/alerts

Change alert settings. Saves the settings that are sent and checks them. `imessage_machine` must be an enrolled machine whose os is darwin, and every recipient in `imessage_to` and `sms_to` a phone number (or, for iMessage, an email address); otherwise 422. Answers with the settings as they now are. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "down": "push",
  "pagerduty_key": "R0UT1NGKEY",
  "night_to": "8"
}
```

`200` The settings after the change.

```json
{
  "down": "push",
  "degraded": "push",
  "push_with": "ntfy",
  "disk_limit": "90",
  "memory_limit": "95",
  "night_from": "22",
  "night_to": "7",
  "night_offset": "0",
  "pagerduty_key": "set",
  "webhook_url": "set"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The input is not right.

### POST /api/v1/alerts/test

Send a test alert. Sends a test alert by one channel. Answers ok, or 422 with one reason. A page, and a push that goes through PagerDuty, stays open for two minutes and then resolves itself, so the phone has time to ring; the answer then carries `resolves_in` (120). For SMS it is Twilio's own message when it gave one, and for iMessage it is the Mac's answer, which is waited for up to a minute. For the others it is a fixed reason that never carries anything the far end said. A 422 with code `slow_down` comes after four tests at once for a token, then one every 25 seconds; a test that stays open costs twice as much: two at once, then one every 50 seconds. Answers 422 too when the channel is not one that sends, or `person` is not a person on the server (code `bad_person`). Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "channel": "webhook"
}
```

`200` Sent.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The input is not right.

### POST /api/v1/alerts/suggestions/{id}/accept

Accept an alert suggestion. Sends that service's issues of that kind to the daily digest from now on. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the suggestion, from the list.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/alerts/suggestions/{id}/dismiss

Dismiss an alert suggestion. Dismisses the suggestion for that service. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the suggestion, from the list.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/logs/retention

How long log lines stay live. `months` is how many months stay live, `action` is what happens to an older month (`archive` or `delete`), and `older` is how many months are older than the limit now and will be handled by the next hourly sweep. Takes a user token (`dku_`) with the `admin` scope.


`200` The setting.

```json
{
  "months": 12,
  "action": "archive",
  "older": 0
}
```

`401` Missing or bad key.

`403` The key may not do this.

### PUT /api/v1/logs/retention

Change how long log lines stay live. `months` is a whole number from 1 to 120. With `action` `delete` an older month is dropped without a file, and `confirm` must be `true`. The change acts on the next sweep, not in this call. Archive files that already exist stay and can still be loaded back. A setting left out stays as it was. Takes a user token (`dku_`) with the `admin` scope.


Send:

```
{
  "months": 6,
  "action": "delete",
  "confirm": true
}
```

`200` The setting after the change, as in the GET.

```json
{
  "months": 6,
  "action": "delete",
  "older": 2
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A setting is not right. The message says which.

### POST /api/v1/logs/archives/{name}/restore

Load an archived month back. Loads an archived month of logs back into the database for a week. Loading a month that is already back does nothing and answers 0 lines. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `name` (path): The name of the month, from the list.

`200` Loaded.

```json
{
  "ok": true,
  "lines": 18204
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/services/{id}/logs/move

Move log lines to another service. Moves the log lines of a service to another service, across all monthly partitions and in batches of 20,000, and answers when done. Lines can be picked by the value of one of their fields and by time. The moved lines take the target service's machine. With dry=true nothing changes and the answer counts the lines that would move. Takes a user token (`dku_`) with the `admin` scope. Not offered through MCP.

- `id` (path): The service the lines are taken from.
- `dry` (query, optional): true to count without moving.

Send:

```
{
  "to": "7f0c2f0e-0000-4000-8000-000000000000",
  "field": "app_name",
  "values": [
    "Records Finder"
  ]
}
```

`200` Moved, or counted.

```json
{
  "moved": 104211
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` Same service, bad field or values, or a bad time.

### POST /api/v1/services/{id}/logs/delete

Delete log lines of a service. Deletes the log lines of a service that match every filter given, across all monthly partitions and in batches of 20,000, and answers when done. At least one filter is required, so a call can never empty a service by accident. With dry=true nothing changes and the answer counts the lines that would go. Takes a user token (`dku_`) with the `admin` scope. Not offered through MCP.

- `id` (path): The service the lines are deleted from.
- `dry` (query, optional): true to count without deleting.

Send:

```
{
  "field": "app_name",
  "values": [
    "Records Finder"
  ]
}
```

`200` Deleted, or counted.

```json
{
  "deleted": 104211
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` No filter, a bad field, values, q or level, or a bad time.

### PUT /api/v1/releases/{version}/{file}

Put a release file on the server. The body is the file, as is, up to 200 MB, and replaces a file of that name. It is written to disk as it arrives. The server stores it and does not check it; the updater does. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `version` (path): A release version. Letters, digits, dots, dashes and underscores; not starting with a dot.
- `file` (path): A file name in that release, such as `SHA256SUMS`. Same characters as a version.

`200` Stored.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`413` The file is over 200 MB.

`422` The name is not allowed.

### DELETE /api/v1/releases/{version}

Remove a release. Removes every file of that version from the server. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `version` (path): A release version. Letters, digits, dots, dashes and underscores; not starting with a dot.

`200` Removed.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The name is not allowed.

### POST /api/v1/update-all

Ask every updater to move to a release. Sets the wanted version on every machine that has an updater. Only a version the server holds completely is accepted: 422 with code `not_held` otherwise, and `bad_version` when it is not `v` and three numbers. Nothing updates until this is called; there is no automatic following of new releases. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "version": "v1.2.3"
}
```

`200` Asked.

```json
{
  "ok": true,
  "version": "v1.2.3",
  "machines": 3
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` The version is not one the server holds completely.

### PUT /api/v1/certificate

Put a certificate in place. Checks that both parse, that the key belongs to the first certificate, that it is neither expired nor not yet valid and that it names at least one DNS name, then saves both and serves the certificate at once to clients that ask for one of its names (SNI). Anything else, and a client that connects by address, still gets the installed certificate. A server that does not serve TLS itself answers 422. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
```

`200` The certificates after the change.

```json
{
  "installed": {
    "names": [
      "web-01"
    ],
    "issuer": "web-01",
    "not_after": "2036-10-01T13:00:00Z",
    "self_signed": true,
    "sha256": "a99f59d72d4fe3caf976fa019c671dc3e184b9f9c4e7b6ce4494e9c85df1ad3d"
  },
  "uploaded": {
    "names": [
      "example.dokkit.dev"
    ],
    "issuer": "R11",
    "not_after": "2027-01-19T13:00:00Z",
    "self_signed": false,
    "sha256": "069ea4a89410f21e10658bbdb91aa9555af7e39294d4c08e999c7765ddf0d390"
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A check failed. The message says which.

### DELETE /api/v1/certificate

Remove the uploaded certificate. Removes the uploaded certificate. The installed one is not touched. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` The certificates after the change.

```json
{
  "installed": {
    "names": [
      "web-01"
    ],
    "issuer": "web-01",
    "not_after": "2036-10-01T13:00:00Z",
    "self_signed": true,
    "sha256": "a99f59d72d4fe3caf976fa019c671dc3e184b9f9c4e7b6ce4494e9c85df1ad3d"
  },
  "uploaded": {
    "names": [
      "example.dokkit.dev"
    ],
    "issuer": "R11",
    "not_after": "2027-01-19T13:00:00Z",
    "self_signed": false,
    "sha256": "069ea4a89410f21e10658bbdb91aa9555af7e39294d4c08e999c7765ddf0d390"
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A check failed. The message says which.

### GET /api/v1/certificate/settings

Settings for getting a certificate by itself. The name, the Cloudflare token (only as `set` or `not set`) and the certificate authority's directory. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` The settings.

```json
{
  "acme_name": "example.dokkit.dev",
  "acme_cloudflare_token": "set",
  "acme_directory": "https://acme-v02.api.letsencrypt.org/directory"
}
```

`401` Missing or bad key.

`403` The key may not do this.

### PUT /api/v1/certificate/settings

Change those settings. Once `acme_name` and `acme_cloudflare_token` are set, the server gets a certificate for the name from the certificate authority, proving the name with a TXT record at `_acme-challenge.<name>` that it adds at Cloudflare and removes again, and renews it when 30 days or fewer are left. A setting left out stays as it was. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "acme_name": "example.dokkit.dev",
  "acme_cloudflare_token": "cf-api-token"
}
```

`200` The settings after the change.

```json
{
  "acme_name": "example.dokkit.dev",
  "acme_cloudflare_token": "set",
  "acme_directory": "https://acme-v02.api.letsencrypt.org/directory"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A setting is not right. The message says which.

### POST /api/v1/certificate/renew

Get a certificate now. Gets a certificate for `acme_name` now, whatever the one held has left. It waits for the whole exchange, which can take a few minutes. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` The certificates after the change.

```json
{
  "installed": {
    "names": [
      "web-01"
    ],
    "issuer": "web-01",
    "not_after": "2036-10-01T13:00:00Z",
    "self_signed": true,
    "sha256": "a99f59d72d4fe3caf976fa019c671dc3e184b9f9c4e7b6ce4494e9c85df1ad3d"
  },
  "uploaded": {
    "names": [
      "example.dokkit.dev"
    ],
    "issuer": "R11",
    "not_after": "2027-01-19T13:00:00Z",
    "self_signed": false,
    "sha256": "069ea4a89410f21e10658bbdb91aa9555af7e39294d4c08e999c7765ddf0d390"
  },
  "renewal": {
    "at": "2026-12-20T03:00:00Z",
    "ok": true,
    "note": "Renewed, runs out 2027-03-20"
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` It failed. The message says why; the same sentence is kept as `renewal` in `GET /certificate`.

### GET /api/v1/certificate/name

The name on dokkit.dev. The name this server holds through the dokkit.dev claim service, empty when none: the address set for it (empty means this machine's own), the address last sent, and whether that worked. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`200` The name.

```json
{
  "name": "home.dokkit.dev",
  "address": "",
  "sent": "192.168.1.20",
  "ok": true,
  "note": "home.dokkit.dev points at 192.168.1.20"
}
```

`401` Missing or bad key.

`403` The key may not do this.

### POST /api/v1/certificate/name

Claim a name on dokkit.dev. With `code`, the one-time claim code from names.dokkit.dev: the server makes a key, registers it with the claim service, makes the name `acme_name` and points the name at `address`, or at this machine's own address when that is empty. From then on the server sends its address once a day, which keeps the name from lapsing, and certificates for the name are proved through the claim service. Without `code`, only the address changes. Follow with `POST /certificate/renew`. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "code": "k3j5w2x7q4m6p2r8t5v3y7z2",
  "address": ""
}
```

`200` The name after the change.

```json
{
  "name": "home.dokkit.dev",
  "address": "",
  "sent": "192.168.1.20",
  "ok": true,
  "note": "home.dokkit.dev points at 192.168.1.20"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` It failed. The message says why.

### POST /api/v1/dependencies

Add something outside that is depended on. Adds a service of kind `dependency`. With `check` (`{type: http, url}` or `{type: tcp, address: host:port}`) it is put on `machine`, an enrolled machine whose dokkit runs the check; without a check it belongs to the group machine Outside. Answers as `GET /services/{id}` does. Takes a user token (`dku_`) with the `admin` scope.


Send:

```
{
  "name": "Payment gateway",
  "machine": "web-01",
  "check": {
    "type": "http",
    "url": "https://pay.example.com/health"
  }
}
```

`200` Done.

### POST /api/v1/machines/{id}/quiet

Plan downtime for a machine. The same as `POST /quiet`, for a person or a tool, for any enrolled machine. Answers with the machine's `id`, `name` and `planned_downtime` (`started_at`, `until`, `reason`, `by`), null when none is running. 404 when the machine is not an enrolled machine. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

Send:

```
{
  "for": "30m",
  "reason": "disk swap"
}
```

`200` Done.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "web01",
  "planned_downtime": {
    "started_at": "2026-10-12T03:00:00.000000Z",
    "until": "2026-10-12T03:30:00.000000Z",
    "ended_at": null,
    "reason": "disk swap",
    "by": "token ops",
    "ended_by": null
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` `for` is missing, not a duration, or more than 4 hours.

### DELETE /api/v1/machines/{id}/quiet

End a machine's planned downtime. Ends the window now, and the usual rules apply from this moment. Answers like `POST`. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

`200` Done.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "web01",
  "planned_downtime": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### POST /api/v1/machines/{id}/scan

Ask a machine to look itself over again. Queues the built-in piece of work `dokkit:scan` for an enrolled machine. It takes no parameters. The machine runs the same read-only scan as `dokkit scan` and sends the result to proposals, where nothing is watched until it is accepted. A program too old to know `dokkit:scan` refuses the run. 404 when the machine is not an enrolled machine. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

Send:

```
{
  "version": "v1.2.3"
}
```

`200` Asked: the id of the queued run.

```json
{
  "run": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The input is not right.

### PUT /api/v1/alerts/who

Name who is told at one level. `to` is a list of person ids, `["everyone"]`, which is the server-wide destinations and behaves as before, or `["oncall"]`: everyone on call in the PagerDuty schedule chosen in the alert settings when the alert is sent, each told on their own destinations, matched by email. If nobody here matches or PagerDuty cannot be reached, the server-wide destinations are told. An empty list names nobody at that level, so the level above decides. Takes a user token (`dku_`) with the `admin` scope.


Send:

```
{
  "scope": "service",
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "to": [
    "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f4"
  ]
}
```

`200` Saved.

```json
{
  "scope": "service",
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "to": [
    "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f4"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` Refused, with the reason.

### PUT /api/v1/alerts/people/{id}

Change a person's destinations. A destination left out stays as it was; an empty one clears it. Email and iMessage may hold several addresses with commas between them. The ntfy address must be https. A person's ntfy topic gets the server's ntfy token only when it is on the same host as the server's ntfy address. A person with no destination for a channel makes that alert fail with a reason that names them. Takes a user token (`dku_`) with the `admin` scope.

- `id` (path): The id of the person.

Send:

```
{
  "email": "ada@example.com",
  "phone": "+15555550100"
}
```

`200` Saved.

```json
{
  "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "name": "ada",
  "role": "member",
  "email": "ada@example.com",
  "phone": "+15555550100",
  "imessage": null,
  "ntfy_url": "set",
  "pushover_user": "not set",
  "pagerduty_key": "not set"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` Refused, with the reason.

### POST /api/v1/alerts/heartbeat/shared

Use dokkit.dev as the outside heartbeat. Asks dokkit.dev for a heartbeat address, with no account, and saves it as heartbeat_url. dokkit.dev tells this server's ntfy topic (one without a token) or webhook when the calls stop for five minutes, and again when they start. Called again, or when those alert settings change, it points the same heartbeat at the new place. The service is `https://beat.dokkit.dev` unless `DOKKIT_SHARED_HEARTBEAT` names another. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


`401` Missing or bad key.

`403` The key may not do this.

`200` The heartbeat in use.

`422` dokkit.dev made no heartbeat, or this server has nothing for it to send to.

### DELETE /api/v1/alerts/heartbeat/shared

Stop using dokkit.dev as the outside heartbeat. Removes the heartbeat at dokkit.dev and clears heartbeat_url. Takes a user token (`dku_`) with the `admin` scope. Not offered through the MCP.


`401` Missing or bad key.

`403` The key may not do this.

`200` Stopped.

### PUT /api/v1/settings

Change the values for the whole server. Changes server-wide values. A pair that must agree (such as enrol_hours and enrol_max_hours, silent_minutes and report_seconds, update_run_minutes and updater_minutes) is checked only when one of the two is sent. A value a machine or job sets for itself stays. Each value is a whole number in its range, true or false, or text for a list of lengths such as `1h, 4h, 1d`. `null` or an empty text puts a value back to what `defaults` shows; a value equal to it is stored as no change. Names left out stay as they were; an unknown name is refused. Takes a user token (`dku_`) with the `admin` scope.


Send:

```
{
  "disk_limit": 85,
  "cpu_on": true,
  "snooze_choices": "1h, 4h, 1d",
  "remind_minutes": null
}
```

`200` The values after the change, as in the GET.

```json
{
  "values": {
    "disk_on": true,
    "disk_limit": 85,
    "disk_after": 3,
    "disk_down": 98
  },
  "defaults": {
    "disk_on": true,
    "disk_limit": 90,
    "disk_after": 3,
    "disk_down": 98
  },
  "changed": [
    "disk_limit"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A value is not right. The message says which.

### PUT /api/v1/machines/{id}/settings

Change the values for one machine. Changes one machine's values. A machine's own disk or memory limit replaces a threshold its dokkit.toml declares for the same number. Each value is a whole number in its range, true or false, or text for a list of lengths such as `1h, 4h, 1d`. `null` or an empty text puts a value back to what `defaults` shows; a value equal to it is stored as no change. Names left out stay as they were; an unknown name is refused. Takes a user token (`dku_`) with the `admin` scope.

- `id` (path): The id of the machine.

Send:

```
{
  "disk_limit": 85,
  "cpu_on": true,
  "snooze_choices": "1h, 4h, 1d",
  "remind_minutes": null
}
```

`200` The values after the change, as in the GET.

```json
{
  "values": {
    "disk_on": true,
    "disk_limit": 85,
    "disk_after": 3,
    "disk_down": 98
  },
  "defaults": {
    "disk_on": true,
    "disk_limit": 90,
    "disk_after": 3,
    "disk_down": 98
  },
  "changed": [
    "disk_limit"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A value is not right. The message says which.

`404` Not found.

### PUT /api/v1/jobs/{id}/settings

Change the values for one job. Changes one job's values. They replace the job's own grace and max_runtime while they are set. Each value is a whole number in its range, true or false, or text for a list of lengths such as `1h, 4h, 1d`. `null` or an empty text puts a value back to what `defaults` shows; a value equal to it is stored as no change. Names left out stay as they were; an unknown name is refused. Takes a user token (`dku_`) with the `admin` scope.

- `id` (path): The id of the job, which is its service id.

Send:

```
{
  "disk_limit": 85,
  "cpu_on": true,
  "snooze_choices": "1h, 4h, 1d",
  "remind_minutes": null
}
```

`200` The values after the change, as in the GET.

```json
{
  "values": {
    "disk_on": true,
    "disk_limit": 85,
    "disk_after": 3,
    "disk_down": 98
  },
  "defaults": {
    "disk_on": true,
    "disk_limit": 90,
    "disk_after": 3,
    "disk_down": 98
  },
  "changed": [
    "disk_limit"
  ]
}
```

`401` Missing or bad key.

`403` The key may not do this.

`422` A value is not right. The message says which.

`404` Not found.

### GET /api/v1/alerts/oncall

PagerDuty schedules and who is on call. Asks PagerDuty, with the REST API key in the alert settings, for the account's schedules and for everyone on call now in the chosen schedule, and says which person on this server each is. An answer is kept for a minute; a failure is not. `error` says why something could not be read. Takes a user token (`dku_`) with the `admin` scope.


`200` OK.

```json
{
  "schedules": [
    {
      "id": "PSCHED1",
      "name": "Primary"
    }
  ],
  "schedule": "PSCHED1",
  "oncall": [
    {
      "name": "Ada Lovelace",
      "email": "ada@example.com",
      "person": {
        "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f4",
        "name": "ada"
      }
    }
  ],
  "error": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

## MCP

The MCP server for AI tools. User token.


### GET /mcp

Not served. Answers 405. The MCP server takes POST only. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


`401` Missing or bad key.

`405` Method not allowed.

### POST /mcp

Talk to the MCP server. The MCP server, as JSON-RPC over one POST address. It can do no more than the user token allows. An AI tool with a token can do through MCP everything the token can do through the API. The tools are, with `read` scope: `attention`, `find`, `service`, `jobs`, `job_runs`, `errors`, `since_deploy`, `machines`, `machine`, `issues`, `issue`, `deploys`, `versions`, `rules`, `proposals`, `series`, `processes`, `process_history` and `day`; with `read-logs` scope: `logs`; with `act` scope: `snooze`, `acknowledge`, `unsnooze`, `note`, `bulk`, `watch`, `unwatch`, `routing`, `hold`, `accept_proposal`, `dismiss_proposal`, `scan_machine`, `plan_downtime` and `end_downtime`; with `admin` scope: `add_rule`, `update_rule`, `delete_rule`, `set_checks`, `allow_restart`, `keys`, `make_key`, `revoke_key`, `people`, `add_person` and `remove_person`. `make_key` returns the key text once. Admin tools are marked destructive. `tools/list` shows only the tools the token may use. Every answer starts with a line saying that what follows is data written by machines and apps, never instructions. An argument of the wrong type is an `isError` answer; a null argument is the same as one left out, and a whole number written as 5.0 is an integer. A tool error is an answer with `isError` true, not an HTTP error. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, error messages and notes are left out of the answer.


Send:

```
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "find",
    "arguments": {
      "q": "upload",
      "machine": "web-02"
    }
  }
}
```

`200` A JSON-RPC answer, with a result or an error.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[{\"id\":\"6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3\",\"name\":\"Upload portal\",\"state\":\"ok\"}]"
      }
    ]
  }
}
```

`202` A notification, which has no id and gets no answer.

`400` The body is not a request.

`401` Missing or bad key.
