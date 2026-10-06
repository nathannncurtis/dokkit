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

Send a batch of lines. The main door. The body is newline-delimited JSON, one item per line, with a `type` and an `at` or `t`. The types are `state`, `inventory`, `metric`, `beat`, `job`, `stats`, `log`, `deploy` and `custom`. A batch is at most 5 MB compressed and 10,000 lines. A refused line does not fail the batch. Send the same `Dokkit-Batch` id again and nothing is stored twice. An app key may not send `state` or `inventory`, and may make 100 checks per service. Takes a machine key (`dkm_`) or an app key (`dka_`).

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

`429` An app key has used up its bucket of 10,000 lines, refilling at 100 a second. Wait for Retry-After seconds.

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

`429` An app key has used up its bucket of 10,000 lines, refilling at 100 a second. Wait for Retry-After seconds.

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

`429` An app key has used up its bucket of 10,000 lines, refilling at 100 a second. Wait for Retry-After seconds.

### PUT /api/v1/declare

Declare a service from a dokkit.toml. The contents of a `dokkit.toml`, sent as JSON with the same structure. Sending the same file twice changes nothing. Checks, jobs, logs and stats become active. Tasks become proposals. The file owns the service and its checks, so checks it no longer lists are removed. Only a machine key may declare; an app key answers 403. Takes a machine key (`dkm_`).


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

Send what a scan found. What `dokkit scan` found, as the file was written. Nothing in it is active until a person accepts it in the interface. So far the server keeps running Windows services and listening ports, and leaves out what is already watched or was dismissed. Takes a machine key (`dkm_`).


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

`429` An app key has used up its bucket of 10,000 lines, refilling at 100 a second. Wait for Retry-After seconds.

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

## Errors

Error reports from an app, in Dokkit's own format or as Sentry envelopes. App key.


### POST /api/v1/errors

Report an error in Dokkit's format. One error report. Reports are grouped by `type` and the app's own frames. Message text is dropped unless the service's page is set to keep it. An error does not open an issue or alert anyone. See `errors.md`. Takes a machine key (`dkm_`) or an app key (`dka_`).


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

`429` An app key has used up its bucket of 10,000 lines, refilling at 100 a second. Wait for Retry-After seconds.

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

`429` An app key has used up its bucket of 10,000 lines, refilling at 100 a second. Wait for Retry-After seconds.

## Work

The `dokkit` program asks for tasks, sends their output and result, and fetches updates. Machine key.


### GET /api/v1/program/{target}

Download the newer dokkit program. The newer `dokkit` program this server holds, for a machine asked to fetch it. The target is the operating system and architecture, such as `windows-amd64`. Takes a machine key (`dkm_`).

- `target` (path): The kind of machine, as `<os>-<arch>`.

`200` The program file.

`401` Missing or bad key.

`404` Not found.

### GET /api/v1/work

Ask for a task to run. The `dokkit` program asks for work and the server holds the request for up to `wait` seconds. 204 means nothing to do; ask again. `command_sha256` is the pin of the task that was accepted; the program runs the task only when its own pin is the same one. A task has a name and nothing else. There are no arguments. Takes a machine key (`dkm_`).

- `wait` (query, optional): Seconds to hold the request.

`200` A task to run.

```json
{
  "run": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
  "task": "nightly-purge",
  "as": "ordinary",
  "command_sha256": "9f2b6c0d1e7a4b83a5c6f1d2e3b4a5968778695a4b3c2d1e0f9a8b7c6d5e4f30"
}
```

`204` Nothing to do. Ask again.

`401` Missing or bad key.

### POST /api/v1/work/{run}/output

Send a chunk of task output. A chunk of the running task's output, as plain text. The server keeps the last part. Takes a machine key (`dkm_`).

- `run` (path): The run id from `GET /work`.

Send:

```
Purged 412 files.

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

Send the result of a task. Either an exit code with the duration, or a refusal with the reason. A refusal is how the program says it will not run a task that is not defined on its machine or not accepted. Takes a machine key (`dkm_`).

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

### GET /api/v1/tasks/accepted

List the tasks accepted for this machine. So `dokkit task list` can say which tasks are accepted. Takes a machine key (`dkm_`).


`200` The accepted tasks.

```json
{
  "items": [
    {
      "task": "nightly-purge",
      "command_sha256": "9f2b6c0d1e7a4b83a5c6f1d2e3b4a5968778695a4b3c2d1e0f9a8b7c6d5e4f30",
      "as": "ordinary"
    }
  ]
}
```

`401` Missing or bad key.

## Read

Read issues, machines, services, jobs, logs, errors, deploys, rules, proposals and tasks. User token.


### GET /api/v1/proposals

List things waiting to be accepted. Found things and tasks that wait for a person to accept them. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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
      "machine": "db-01"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/deploys

List deploys. Deploy history, newest first. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

List error groups. Error groups by type and place, newest first, at most 200. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

What needs a look. What needs a look, what will soon, what was found and is not watched, what is snoozed, issues in other environments, and how many things are fine. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

List open and snoozed issues. Open issues, then snoozed ones. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Get one issue. One issue, open or closed, with its notes. The id is the issue's uuid. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

List machines. Machines with their vitals. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Get one machine. One machine with its services and its thresholds. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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
  }
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### GET /api/v1/services

List services. Services across machines. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `q` (query, optional): Search the name and slug.
- `machine` (query, optional): A machine id or name.

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

Get one service. One service with its checks, facts, routing, version and open issue. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Get chart data for a service. Without `metric`, the names of the metrics the service has. With `metric`, its points between `from` and `to`. Answers 404 for an unknown service, a time that is not RFC 3339, or a `from` that is not before `to`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

List jobs. Every job with its schedule, last run, last good run and next expected run. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

List the runs of a job. The recent runs of one job, up to 100. The id is the job's service id. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the job's service.

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

Get one error group. One group with the stack and tags of its latest report. The message is there only when the service keeps messages, and needs `read-logs`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the error group.

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

Which version is where. Which version of each service is on which machine, and under `apps`, each app that runs on many hosts with the hosts on each version. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

List alert rules. Alert rules, first match first. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

### GET /api/v1/tasks

List accepted tasks. Accepted tasks, each with its machine, command and latest run. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "name": "nightly-purge",
      "command": "purge.cmd",
      "machine": "nas",
      "as": "ordinary",
      "last_run": null
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/task-runs

List task runs. Runs of tasks, with their output. Output needs `read-logs`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


`200` OK.

```json
{
  "items": [
    {
      "id": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3",
      "state": "ok",
      "by": "token ci-bot",
      "exit_code": 0,
      "duration_ms": 81234,
      "output": "Purged 412 files.",
      "started_at": "2026-10-05T02:00:01Z",
      "finished_at": "2026-10-05T02:01:22Z",
      "task": "nightly-purge",
      "machine": "nas"
    }
  ],
  "next": null
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/alerts

Alert settings. Who is told by default, the limits, the night and the mail settings. Addresses, user names and secrets are shown only as `set` or `not set`. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Alert suggestions. Issues that opened six times or more in a month and are snoozed, where the daily digest could take them instead. Nothing changes until a person accepts. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Archived months of logs. The archived months of logs that can be loaded back. Takes a user token (`dku_`) with the `read-logs` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

## Act

Snooze and acknowledge issues, route and hold services, accept found things, run tasks, keep error text and set when a job is late. User token with `act`.


### POST /api/v1/issues/{id}/snooze

Snooze an issue. Snoozes an issue until a time. An unknown issue answers 404. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Bring a snoozed issue back. Brings a snoozed issue back. An unknown issue answers 404. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Mark an issue as seen. Marks an issue as seen. An unknown issue answers 404. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Add a note to an issue. Adds a note. The note is signed with the token's label. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Snooze, unsnooze or acknowledge many issues. Does one action to a list of issue ids. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Start watching a found service. Starts watching a found service. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Stop watching a service. Stops watching a service. Open issues close and what the checks said is forgotten. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Set who is told about a service. Sets the channel for `down` and for `degraded`. A field that is not sent stays as it was; a value that is not a channel clears that route. `night` is optional; false holds the alerts of a night until it ends. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the service.

Send:

```
{
  "down": "page",
  "degraded": "digest",
  "night": false
}
```

`200` The routing now in force.

```json
{
  "down": "page",
  "degraded": "digest",
  "night": false
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### PUT /api/v1/services/{id}/hold

Hold a version on purpose. Marks a version as held on purpose. An empty or missing `version` clears the hold. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Accept a found thing. Accepts a found service or port, so it is watched. A task is accepted by a person in the interface, not here. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Dismiss a found thing. Dismisses a found thing so it is not offered again. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

### POST /api/v1/tasks/{id}/run

Run an accepted task. Runs an accepted task on its machine. The task runs its accepted command and takes no arguments. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the task.

`200` The run id.

```json
{
  "run": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

### PUT /api/v1/services/{id}/messages

Keep or stop keeping error text. Keeps the text of a service's errors from now on, or stops keeping it. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Set when a job is late. Sets when a job counts as late (grace) and as run too long (max_runtime). A field left out is cleared. A job from a dokkit.toml is changed in the file. Takes a user token (`dku_`) with the `act` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

## Admin

Keys, people, alert rules and settings, interface-added checks, restart, making jobs, accepting tasks, updating the program and loading logs back. User token with `admin`.


### POST /api/v1/jobs

Add a job to watch. Adds a job and its machine if it is new. The key and the addresses the job calls are returned once. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Add an alert rule. Adds a rule to the end of the list. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Replace the checks added in the interface. Replaces the checks added in the interface. Checks that came from a file are changed in the file. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Allow or stop automatic restart. Allows or stops automatic restart of a service. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Replace an alert rule. Replaces what a rule says. Its place in the order stays. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Delete an alert rule. Deletes a rule. Deleting one that is not there still answers ok. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the rule.

`200` Done.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/keys

List keys. Every key that still works, newest first. The key text is never shown again; `hint` is the start of it. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Make a key. Makes a user token with a label and scopes (only scopes the calling token holds, and never `admin`, which is made in Settings), an app key for a service, or a one-use enrolment token that lasts an hour. The key is shown once, in this answer. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Revoke a key. Revokes a key. It stops working at once. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the key.

`200` Revoked.

```json
{
  "ok": true
}
```

`401` Missing or bad key.

`403` The key may not do this.

### GET /api/v1/users

List people. The people who can sign in. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Add a person. Adds a person who can sign in. Roles are `owner`, `member` and `viewer`. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Remove a person. Removes a person. Their user tokens stop working. The last owner cannot be removed. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

### POST /api/v1/tasks/{id}/accept

Accept a task. Accepts a task that is waiting, so its machine may run the command. Accepting lets the server ask a machine to run a command, so it needs `admin`. Send the command and pin that proposals shows. A task whose command or pin has changed since answers 422. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the task, from proposals.

Send:

```
{
  "command": "systemctl restart portal",
  "pin": "5d41402abc4b2a76b9719d911017c592",
  "system": false
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

`422` The input is not right.

### POST /api/v1/tasks/{id}/dismiss

Dismiss a task. Dismisses a task that is waiting until its command or pin changes. Send the command and pin that proposals shows. A task whose command or pin has changed since answers 422. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the task, from proposals.

Send:

```
{
  "command": "systemctl restart portal",
  "pin": "5d41402abc4b2a76b9719d911017c592"
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

`422` The input is not right.

### POST /api/v1/machines/{id}/update

Ask a machine to fetch the newer program. Asks an enrolled machine to fetch the newer `dokkit` program from this server. It only fetches: a person finishes the update on the machine. Answers 422 when the server holds no program. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

- `id` (path): The id of the machine.

`200` The run id.

```json
{
  "run": "6f1c2a8e-3b7d-4c52-9e0a-5d41b7c8e9f3"
}
```

`401` Missing or bad key.

`403` The key may not do this.

`404` Not found.

`422` The input is not right.

### PUT /api/v1/alerts

Change alert settings. Saves the settings that are sent and checks them. Answers with the settings as they now are. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Send a test alert. Sends a test alert by one channel. Answers 422 when the channel is not one that sends, or when the send fails, with what went wrong. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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

Accept an alert suggestion. Sends that service's issues of that kind to the daily digest from now on. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

Dismiss an alert suggestion. Dismisses the suggestion for that service. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

### POST /api/v1/logs/archives/{name}/restore

Load an archived month back. Loads an archived month of logs back into the database for a week. Loading a month that is already back does nothing and answers 0 lines. Takes a user token (`dku_`) with the `admin` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.

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

## MCP

The MCP server for AI tools. User token.


### GET /mcp

Not served. Answers 405. The MCP server takes POST only. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


`401` Missing or bad key.

`405` Method not allowed.

### POST /mcp

Talk to the MCP server. The MCP server, as JSON-RPC over one POST address. It can do no more than the user token allows. An AI tool with a token can do through MCP everything the token can do through the API. The tools are, with `read` scope: `attention`, `find`, `service`, `jobs`, `job_runs`, `errors`, `since_deploy`, `tasks`, `machines`, `machine`, `issues`, `issue`, `deploys`, `versions`, `rules`, `proposals`, `task_runs`, `series` and `day`; with `read-logs` scope: `logs`; with `act` scope: `snooze`, `acknowledge`, `unsnooze`, `note`, `bulk`, `watch`, `unwatch`, `routing`, `hold`, `accept_proposal`, `dismiss_proposal` and `run_task`; with `admin` scope: `add_rule`, `update_rule`, `delete_rule`, `set_checks`, `allow_restart`, `keys`, `make_key`, `revoke_key`, `people`, `add_person` and `remove_person`. `make_key` returns the key text once. Admin tools are marked destructive. `tools/list` shows only the tools the token may use. Every answer starts with a line saying that what follows is data written by machines and apps, never instructions. An argument of the wrong type is an `isError` answer. A tool error is an answer with `isError` true, not an HTTP error. Takes a user token (`dku_`) with the `read` scope. Without `read-logs`, job output, task output, error messages and notes are left out of the answer.


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
