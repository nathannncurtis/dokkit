# `dokkit.toml`

One file in an app's repo that says what the app is and how to tell if it is healthy. It ships with the app.

```toml
schema = 1

[service]
id = "upload-portal"
name = "Upload portal"
kind = "service"                # service, job, dependency or app
environment = "production"      # anything else never alerts
version_from = "stats"          # "stats", a file path, or a command

[[check]]
type = "http"
url = "http://localhost:8080/healthz"
every = "30s"
timeout = "5s"

[stats]
url = "http://localhost:8080/internal/stats"
key_env = "STATS_KEY"           # the name of the variable, never the secret

[logs]
path = "logs/*.jsonl"

[[job]]
id = "nightly-purge"
schedule = "0 1 * * *"
grace = "30m"
max_runtime = "1h"

[[task]]
id = "security-scan"
run = "scripts/zap.ps1"
timeout = "2h"                  # the server ends a run still going after 12 hours

[alert]
down = "page"                   # a suggested default only
degraded = "push"
```

## Sections

| Section | Holds |
|---|---|
| `schema` | The version of this file format. `1`. |
| `[service]` | What the app is. `id` is unique on its machine and never changes. |
| `[[check]]` | One per check. `type` is one of the check types in `api.md`. Each type has its own fields: `url` for `http`, `port` for `tcp`, `name` for `process` and `windows-service`, `metric` and `limit` for `threshold` (bad when the metric is over the limit), `date_from` for `expiry` (an `https` address or `host:port` for a certificate, or a file whose first line is a date). All take `every`. |
| `[stats]` | Where the stats document is and which environment variable holds its key. |
| `[logs]` | Files to read. Paths are relative to the file. Lines follow `log-lines.md`. |
| `[[job]]` | A scheduled job: when it should run, how late it may be, and how long it may take. `schedule` is a five-field cron line read as UTC, and `@reboot` is refused. |
| `[[task]]` | A named piece of work the server may be allowed to ask for. |
| `[alert]` | A starting suggestion for who is told. |

## Rules

**The file owns what the app is and how to check it. The interface owns who is told, snoozes and overrides.** The interface shows a file-declared check as coming from the file, and it is changed by changing the file. `[alert]` only seeds the routing the first time the service appears.

**Secrets never go in the file.** A field ending in `_env` names an environment variable that holds one.

**A declared check is active straight away. A declared task is not.** A task is a command that the server could later ask a machine to run. It arrives as a proposal, is accepted in the interface, and is pinned to the exact command that was accepted. If the command in the file changes, it is proposed again and the old one stops being runnable. A task runs under an ordinary account unless it was accepted to run otherwise. Without this, anyone able to edit a file in a repo could get a command run by a privileged service.

**Tasks take no arguments.** The server can ask for a task by name and nothing else.

## How the file reaches Dokkit

Two ways, both supported:

1. **`dokkit` reads it.** `dokkit`'s own configuration lists the folders it may read `dokkit.toml` files from. That configuration is only editable by an administrator. `dokkit` re-reads a file when it changes.
2. **It is sent.** `dokkit apply` sends the file from anywhere that has a key, for example from CI.

## Checking it

`dokkit check` validates the file, runs every check once on the current machine, and prints exactly what would be sent. It needs no server.
