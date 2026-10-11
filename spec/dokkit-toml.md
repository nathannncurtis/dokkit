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
slow = "2s"                     # an answer slower than this is degraded, not down; http only, above 0, below timeout

[stats]
url = "http://localhost:8080/internal/stats"
key_env = "DOKKIT_STATS_KEY"     # the name of the variable, never the secret; must start with DOKKIT_STATS_

[logs]
path = "logs/*.jsonl"

[[job]]
id = "nightly-purge"
schedule = "0 1 * * *"
grace = "30m"
max_runtime = "1h"

[alert]
down = "page"                   # a suggested default only
degraded = "push"
```

## Sections

| Section | Holds |
|---|---|
| `schema` | The version of this file format. `1`. |
| `[service]` | What the app is. `id` is unique on its machine and never changes. |
| `[[check]]` | One per check. `type` is one of the check types in `api.md`. Each type has its own fields: `url` for `http`, `port` for `tcp`, `name` for `process` (the program's file name; an optional `command_has` also needs a piece of its text, ignoring case: the full executable path on Windows (as the system names it, after the drive: \Device\HarddiskVolumeN\..., so match from the folder, not the drive letter), the whole command line on Linux and macOS, so `command_has = '\envs\imageresizer\'` tells one app's `python.exe` from the rest, a backslash and a slash count the same, and a process that cannot be inspected does not match; an optional `at_least = 30` is the fewest matching processes that is healthy: fewer is `degraded`, none is `down`, and the value reported is how many were found, which is how an app that runs as dozens of worker processes is watched; see Which processes can be seen), `windows-service` and `systemd` (the unit), `metric` and `limit` for `threshold` (bad when the metric is over the limit), `date_from` for `expiry` (an `https` address or `host:port` for a certificate, or a file whose first line is a date; the check is `degraded` from 30 days before the date, counted in exact time, and `down` once it has passed, and shows the days left rounded up). All take `every`. `http` also takes `slow`: an answer that comes back successfully but takes longer is `degraded`, with the time as its value, and the server opens an issue only after its usual run of bad results. |
| `[stats]` | Where the stats document is and which environment variable holds its key. |
| `[logs]` | Files to read. Paths are relative to the file and must stay inside its folder. Lines follow `log-lines.md`. |
| `[[job]]` | A scheduled job: when it should run, how late it may be, and how long it may take. `schedule` is a five-field cron line read as UTC, and `@reboot` is refused. |
| `[alert]` | A starting suggestion for who is told. |

## Rules

**The file owns what the app is and how to check it. The interface owns who is told, snoozes and overrides.** The interface shows a file-declared check as coming from the file, and it is changed by changing the file. `[alert]` only seeds the routing the first time the service appears.

**Secrets never go in the file.** A field ending in `_env` names an environment variable that holds one.

**A declared check is active straight away.**

## How the file reaches Dokkit

Two ways, both supported:

1. **`dokkit` reads it.** `dokkit`'s own configuration lists the folders it may read `dokkit.toml` files from. That configuration is only editable by an administrator. `dokkit` re-reads a file when it changes.
2. **It is sent.** `dokkit apply` sends the file from anywhere that has a key, for example from CI.

## Which processes can be seen

A `process` check sees the processes of every account, with no administrator rights, on each system, and matches by the program's file name (and `command_has` against the text below).

- **Windows.** The list of processes comes from a system snapshot, which includes other accounts' processes. The executable path used by `command_has` is asked of the system by process number, without opening the process, so Local Service sees other accounts' processes and their paths (`procs_windows.go`). A protected system process may give no path; it then matches by name only.
- **Linux.** `/proc/<pid>/comm` and `/proc/<pid>/cmdline` are readable by any user, so an unprivileged account sees all processes and their command lines. Where `/proc` is mounted with `hidepid=1` or `hidepid=2`, an account outside the allowed group sees only its own, and a process that is not listed is counted as not running. The program name is the kernel's, cut to 15 characters. The executable path (`/proc/<pid>/exe`) is not used, because only the owner or root can read it.
- **macOS.** `ps -axww` lists every user's processes with their command lines for any account, so the same applies as on Linux without `hidepid`.

## Checking it

`dokkit check` validates the file, runs every check once on the current machine, and prints exactly what would be sent. It needs no server. It refuses what the server refuses when the file is declared: `service.id` outside lower-case letters, digits, dots, dashes and underscores (starting with a letter or digit), a `service.kind` that is not `service`, `job`, `dependency` or `app`, a check type that is not known, a job without an `id`, a job `schedule` that is not a cron line (five fields read as UTC, or `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`; `@reboot` is refused), and a `fail_after` that is not a whole number from 1 to 100. It also refuses a `key_env` that does not start with `DOKKIT_STATS_`, a `[stats] url` that is not an `http` or `https` address, and a `[logs] path` that leaves the file's folder. `dokkit watch` keeps a file with one of those last three and reports the part that cannot work. `spec/declare-cases.json` holds files both the program and the server's declare are tested against.
