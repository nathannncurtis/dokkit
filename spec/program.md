# The `dokkit` program

One Go binary, `dokkit`. The same file is the command-line tool and the thing that stays running on a machine.

## Commands

| Group | Command | Does |
|---|---|---|
| In an app repo | `dokkit init` | Asks what the app is and writes `dokkit.toml`. |
| | `dokkit check` | Validates the file, runs every check once on this machine, prints exactly what would be sent. Needs no server. |
| | `dokkit apply` | Sends the file to Dokkit. |
| Jobs | `dokkit run --job <name> -- <command>` | Runs the command and reports start, finish, exit code, duration and the last lines of output. Exits with the command's own exit code. |
| | `dokkit ping <name> [start, ok or fail]` | For a job that cannot be wrapped. |
| This machine | `dokkit enrol <address> <token>` | Trades a one-time token for this machine's key and stores the server's certificate fingerprint. |
| | `dokkit status` | What this machine is watching and when it last reported. |
| | `dokkit doctor` | Can it reach the server, does the certificate match, is the clock right. |
| Discovery | `dokkit scan` | Looks at what is on the machine and writes a proposal file. Sends nothing. |
| | `dokkit propose` | Sends the proposal file to be accepted in the interface. |
| Staying running | `dokkit watch` | Runs in the foreground under a login. An ordinary program: no administrator, no service. |
| | `dokkit watch --background` | The same, left running with no window. |
| | `dokkit startup on`, `off` | Starts `dokkit watch --background` each time this person signs in. No administrator. |
| | `dokkit service install`, `uninstall`, `start`, `stop` | Runs as a service. Needs an administrator once. |
| Tasks | `dokkit task list` | The tasks defined on this machine and whether each is accepted. |
| | `dokkit task run <name>` | Runs a task locally to try it. |

## Three levels

Each is a choice. None is a requirement for the next.

| Level | Needs | What it does |
|---|---|---|
| Declared | No administrator, no scan | Checks only what is listed in `dokkit.toml` files or added in the interface. |
| User-space | No administrator | `dokkit watch` under a login. Sees ports, processes, disks and readable logs. Stops at logoff and cannot restart services. |
| Installed service | Administrator, once | Survives logoff, restarts allow-listed services, and scans when asked. |

## How it behaves

**No open port, at any level.** `dokkit` only makes outbound requests. Work arrives over a request it holds open to the server.

**Nothing is lost when the server is unreachable.** Everything goes to a spool folder on disk first and is sent from there. A log file's read position only moves forward after the server confirms it has the lines. The spool has a size cap, 500 MB by default. When it is hit, the oldest goes and the number dropped is reported.

**`dokkit run` and `dokkit ping` work with or without `dokkit` running.** If it is running they leave their report in the spool folder. If not, they send it themselves.

**It only runs accepted, named tasks.** A task is defined on the machine, accepted in the interface, and pinned to the exact command accepted. The server can ask for a task by name and nothing else.

**It never asks for antivirus to be turned off.** The declared and user-space levels exist so that getting started never needs an exception.

**A scan writes a proposal.** Nothing a scan finds is watched until it is accepted.

## What a scan looks at

| Part | Finds |
|---|---|
| Services | Installed services and their state. |
| Ports | What is listening, and which program owns it. |
| Scheduled tasks | Tasks and timers, and when they last ran. |
| Containers | Running containers and their images. |
| Sites | Sites configured in a web server. |
| Disks | Volumes and free space. |
| Declarations | `dokkit.toml` files in the allowed folders. |

Each part can be switched off with a flag. The proposal file shows everything found before anything is sent.

A scan never reads file contents, credentials, browser data, or another program's memory.

## Updates

`dokkit` never updates itself. The interface shows when a machine is behind. The update is started from there by a person, and runs as a built-in task that checks the release's signature before replacing anything.

## Signing

Every Windows release is signed with a code-signing certificate, and is not packed or compressed into a self-extracting file.

## Configuration

`dokkit`'s own configuration lives outside any app repo and is only editable by an administrator on an installed service. It holds:

- the server address, the certificate fingerprint and the machine key
- the folders `dokkit` may read `dokkit.toml` files from
- the spool folder and its size cap
- the account tasks run under

## Not in this design

A listener on localhost. Earlier notes had `dokkit` listening on localhost so apps and the CLI could hand it data. The spool folder covers the CLI, and libraries send straight to the server, so nothing here needs it. It stays possible, and off.

## Built so far

In `program/`: `dokkit init`, `run`, `ping`, `check`, `apply`, `enrol`, `watch`, `status`, `doctor`, `service`, `scan` and `task`. With `DOKKIT_URL` and `DOKKIT_KEY` set they use that key; otherwise they use the address and machine key that `dokkit enrol` saved in the user's configuration folder.

`dokkit watch` reads `dokkit.toml` files from the folders in `DOKKIT_FOLDERS` or in the saved configuration, and from the folders directly inside them. It declares each file, runs its `http`, `tcp`, `process` and `windows-service` checks on their own timing, sends the log files it names, says the machine is alive once a minute, and re-reads a file when it changes. `dokkit status` shows what `watch` last wrote down: the files it reads, when the spool was last emptied, and how much is waiting.

`dokkit watch --background` starts the same program detached, writing to `watch.log` in the spool folder, and does nothing when one is already running. `dokkit startup on` is for Windows and adds it to the signed-in person's own startup programs. `dokkit status` shows the process number to stop it by.

`dokkit service install` is for Windows. It copies the program to `Program Files\Dokkit` and the saved address, key and folders to `ProgramData\dokkit`, which only administrators and the system account can read, then registers a service that starts with Windows and restarts a minute after a failure. From an administrator prompt, `dokkit status` and `dokkit doctor` read that configuration. On other systems, `dokkit watch` runs from a systemd unit.

`dokkit scan` writes `dokkit-proposal.json` in the current folder, and each part has a `--no-` flag. `dokkit task list` and `dokkit task run` read the tasks in the current folder's `dokkit.toml` and in the folders the machine reads. A task runs in its file's folder and stops at its `timeout`, an hour when none is given.

`dokkit watch` holds a request open to the server and runs the task runs it is given, one at a time, sending output every three seconds. It refuses a task whose command in the file is not the one that was accepted. A task runs as whoever runs `dokkit watch`. The installed service runs as the system account, so it does not take work until a task can be given an ordinary account.

`dokkit propose` sends the file a scan wrote. Each minute `dokkit watch` asks the server for the checks added in the interface for its machine and runs them beside the ones in files.

Not built yet: stats, `dokkit task list` showing what is accepted, the account tasks run under, certificate pinning, and the built-in update task.
