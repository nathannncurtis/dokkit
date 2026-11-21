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
fail_after = 3                  # bad results in a row before an issue opens; 1 to 100, the server default is 3

[stats]
url = "http://localhost:8080/internal/stats"
key_env = "DOKKIT_STATS_KEY"     # the name of the variable, never the secret; must start with DOKKIT_STATS_

[logs]
path = "logs/*.jsonl"

[[job]]
id = "nightly-purge"
schedule = "0 1 * * *"
grace = "30m"                  # how late it may start; the server default is 30m
max_runtime = "1h"              # how long a run may take; declaring it turns the limit on

[alert]
down = "page"                   # a suggested default only
degraded = "push"
```

## Sections

| Section | Holds |
|---|---|
| `schema` | The version of this file format. `1`. |
| `[service]` | What the app is. `id` is unique on its machine and never changes. |
| `[[check]]` | One per check. `type` is one of `http`, `tcp`, `process`, `windows-service`, `systemd`, `beat`, `stats`, `threshold`, `expiry` and `custom` (a job is a `[[job]]`, not a check). Each type has its own fields: `url` for `http` (an optional `status` is the answer that counts as healthy: a code such as `200`, a range such as `"200-299"`, or a list of those such as `[200, "400-403"]`, from 100 to 599; any other answer is down; without it anything under 400 is healthy; redirects are followed unless `status` includes a 3xx code), `port` for `tcp` (with an optional `host`, `localhost` when left out), `name` for `process` (the program's file name; an optional `command_has` also needs a piece of its text, ignoring case: the full executable path on Windows (as the system names it, after the drive: \Device\HarddiskVolumeN\..., so match from the folder, not the drive letter), the whole command line on Linux and macOS, so `command_has = '\envs\imageresizer\'` tells one app's `python.exe` from the rest, a backslash and a slash count the same, and a process that cannot be inspected does not match; an optional `at_least = 30` is the fewest matching processes that is healthy: fewer is `degraded`, none is `down`, and the value reported is how many were found, which is how an app that runs as dozens of worker processes is watched; see Which processes can be seen), `windows-service` and `systemd` (the unit), `metric` and `limit` for `threshold` (bad when the metric is over the limit), `date_from` for `expiry` (an `https` address or `host:port` for a certificate, or a file whose first line is a date; the check is `degraded` from 30 days before the date, counted in exact time, and `down` once it has passed, and shows the days left rounded up; the 30 days is a default, changed in Settings). All take `every`, `timeout` and `fail_after`, the number of bad results in a row (a whole number from 1 to 100) after which the server opens an issue. When one is left out, the server's value is used: 30 seconds, 5 seconds and 3 by default, changed in Settings under Checks. `http` also takes `slow`: an answer that comes back successfully but takes longer is `degraded`, with the time as its value, and the server opens an issue only after its usual run of bad results. |
| `[stats]` | Where the stats document is and which environment variable holds its key. |
| `[logs]` | Files to read. Paths are relative to the file and must stay inside its folder. Each line is a JSON object (`t`, `level`, `msg`, `service`, `fields`) or a CLEF line; any other line is kept as its message. |
| `[[job]]` | A scheduled job: when it should run, how late it may be (`grace`, 30 minutes by default) and how long it may take (`max_runtime`). A `max_runtime` in the file turns the limit on for that job; without one, a run is flagged only when "Too long" is on in the job's settings (60 minutes by default). `schedule` is a five-field cron line read as UTC, and `@reboot` is refused. |
| `[alert]` | A starting suggestion for who is told. |
| `[app]` | How the updater installs a release of this service. `kind` is `windows-service`, `installer`, `compose`, `systemd` or `launchd`. See Updating the app. |

## Rules

**The file owns what the app is and how to check it. The interface owns who is told, snoozes and overrides.** The interface shows a file-declared check as coming from the file, and it is changed by changing the file. `[alert]` only seeds the routing the first time the service appears.

**Secrets never go in the file.** A field ending in `_env` names an environment variable that holds one.

**A declared check is active straight away.**

## How the file reaches Dokkit

Two ways, both supported:

1. **`dokkit` reads it.** `dokkit`'s own configuration lists the folders it may read `dokkit.toml` files from. That configuration is only editable by an administrator. `dokkit` re-reads a file when it changes.
2. **It is sent.** `dokkit apply` sends the file from anywhere that has a key, for example from CI. A machine key may declare any service on its machine. An app key may declare only the service it belongs to: `[service] id` must match, the machine and kind stay as they are, `[service]` may set the name and environment, `[[job]]` keeps `id`, `schedule`, `grace` and `max_runtime`, `[[check]]` may be of type `beat` or `custom` only (any other type is refused), and the other sections are dropped.

## Updating the app

`[app]` tells the updater (`dokkit updater run`, installed by an administrator) what to do with a release the server hands it. The updater reads it from this machine's own file and never from the server's copy, and uses it only when the file and its folder are owned by administrators (root on Linux and macOS) and cannot be changed by anyone else. The release file comes from the server; its SHA-256 must match, and on Windows a `.exe` or `.msi` must carry a valid Authenticode signature (from the signer pinned for the app in Dokkit, when one is) unless "Require a signed installer" is turned off in the app's update settings. A failed start or failed checks puts the old files back and starts them again.

| Field | Meaning |
|---|---|
| `kind` | `windows-service`, `installer`, `compose`, `systemd` or `launchd`. |
| `name` | The service, unit or label to restart (`windows-service`, `systemd`, `launchd`). |
| `folder` or `file` | What to replace, one of the two (`windows-service`, `systemd`, `launchd`). A `folder` takes a `.zip`, `.tar.gz` or `.tgz` that is extracted over it, so files not in the archive stay. A `file` takes the file itself, or the one entry of an archive with the same file name. The old copy is kept beside it as `.dokkit-previous`. |
| `args` | A list of arguments for an `installer`, `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` when left out. A `.msi` runs as `msiexec /i file /qn /norestart` plus these. |
| `compose_file`, `compose_service` | The Compose file and the service whose image tag is changed (`compose`). |
| `tag` | The image tag for `compose`: `{version}` is the release tag and `{number}` is the same without a leading `v`. `{version}` when left out. |
| `asset` | A file name pattern the server uses to pick the release file when a release has several. |
| `health_wait` | How long to wait for the checks to pass after the start, from `10s` to `1h`. The release's own value, else `5m`, when left out. |

After the start the updater runs every check in the same file every 5 seconds until all pass. If `[service] version_from` is a file, its first line must also match the release. A file with neither checks nor a version file is healthy straight after the start.

```toml
# a Windows service whose folder is replaced from a .zip
[app]
kind = "windows-service"
name = "AcmeIntake"
folder = 'C:\Program Files\Acme Intake'

# a silent installer
[app]
kind = "installer"
args = ["/VERYSILENT", "/NORESTART"]

# a Compose service: the image tag in compose.yml is changed, pulled and started
[app]
kind = "compose"
compose_file = "/srv/acme/compose.yml"
compose_service = "intake"
tag = "{number}"

# a systemd service whose one binary is replaced
[app]
kind = "systemd"
name = "acme-intake"
file = "/usr/local/bin/acme-intake"
health_wait = "2m"

# a launchd job whose folder is replaced
[app]
kind = "launchd"
name = "com.example.intake"
folder = "/usr/local/acme"
```

Each file has one `[app]`, for its own `[service]`. The examples show one `[app]` each; a file holds only one.

## Which processes can be seen

A `process` check sees the processes of every account, with no administrator rights, on each system, and matches by the program's file name (and `command_has` against the text below).

- **Windows.** The list of processes comes from a system snapshot, which includes other accounts' processes. The executable path used by `command_has` is asked of the system by process number, without opening the process, so Local Service sees other accounts' processes and their paths (`procs_windows.go`). A protected system process may give no path; it then matches by name only.
- **Linux.** `/proc/<pid>/comm` and `/proc/<pid>/cmdline` are readable by any user, so an unprivileged account sees all processes and their command lines. Where `/proc` is mounted with `hidepid=1` or `hidepid=2`, an account outside the allowed group sees only its own, and a process that is not listed is counted as not running. The program name is the kernel's, cut to 15 characters. The executable path (`/proc/<pid>/exe`) is not used, because only the owner or root can read it.
- **macOS.** `ps -axww` lists every user's processes with their command lines for any account, so the same applies as on Linux without `hidepid`.

## Checking it

`dokkit check` validates the file, runs every check once on the current machine, and prints exactly what would be sent. It needs no server. It refuses what the server refuses when the file is declared: `service.id` outside lower-case letters, digits, dots, dashes and underscores (starting with a letter or digit), a `service.kind` that is not `service`, `job`, `dependency` or `app`, a check type that is not known, a job without an `id`, a job `schedule` that is not a cron line (five fields read as UTC, or `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`; `@reboot` is refused), and a `fail_after` that is not a whole number from 1 to 100. It also refuses a `key_env` that does not start with `DOKKIT_STATS_`, a `[stats] url` that is not an `http` or `https` address, and a `[logs] path` that leaves the file's folder. `dokkit watch` keeps a file with one of those last three and reports the part that cannot work. `spec/declare-cases.json` holds files both the program and the server's declare are tested against.
