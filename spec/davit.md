# Davit and the CLI

One Go binary, `davit`. The same file is the command-line tool and the thing that stays running on a machine.

## Commands

| Group | Command | Does |
|---|---|---|
| In an app repo | `davit init` | Asks what the app is and writes `docket.toml`. |
| | `davit check` | Validates the file, runs every check once on this machine, prints exactly what would be sent. Needs no server. |
| | `davit apply` | Sends the file to Docket. |
| Jobs | `davit run --job <name> -- <command>` | Runs the command and reports start, finish, exit code, duration and the last lines of output. Exits with the command's own exit code. |
| | `davit ping <name> [start, ok or fail]` | For a job that cannot be wrapped. |
| This machine | `davit enrol <address> <token>` | Trades a one-time token for this machine's key and stores the server's certificate fingerprint. |
| | `davit status` | What this machine is watching and when it last reported. |
| | `davit doctor` | Can it reach the server, does the certificate match, is the clock right. |
| Discovery | `davit scan` | Looks at what is on the machine and writes a proposal file. Sends nothing. |
| | `davit propose` | Sends the proposal file to be accepted in the interface. |
| Staying running | `davit agent` | Runs in the foreground under a login. |
| | `davit service install`, `uninstall`, `start`, `stop` | Runs as a service. Needs an administrator once. |
| Tasks | `davit task list` | The tasks defined on this machine and whether each is accepted. |
| | `davit task run <name>` | Runs a task locally to try it. |

## Three levels

Each is a choice. None is a requirement for the next.

| Level | Needs | What it does |
|---|---|---|
| Declared | No administrator, no scan | Checks only what is listed in `docket.toml` files or added in the interface. |
| User-space | No administrator | `davit agent` under a login. Sees ports, processes, disks and readable logs. Stops at logoff and cannot restart services. |
| Installed service | Administrator, once | Survives logoff, restarts allow-listed services, and scans when asked. |

## How it behaves

**No open port, at any level.** Davit only makes outbound requests. Work arrives over a request it holds open to the server.

**Nothing is lost when the server is unreachable.** Everything goes to a spool folder on disk first and is sent from there. A log file's read position only moves forward after the server confirms it has the lines. The spool has a size cap, 500 MB by default. When it is hit, the oldest goes and the number dropped is reported.

**`davit run` and `davit ping` work with or without Davit running.** If it is running they leave their report in the spool folder. If not, they send it themselves.

**It only runs accepted, named tasks.** A task is defined on the machine, accepted in the interface, and pinned to the exact command accepted. The server can ask for a task by name and nothing else.

**It never asks for antivirus to be turned off.** Releases are signed and not packed. The declared and user-space levels exist so that getting started never needs an exception.

**A scan writes a proposal.** Nothing a scan finds is watched until it is accepted.

## Configuration

Davit's own configuration lives outside any app repo and is only editable by an administrator on an installed service. It holds:

- the server address, the certificate fingerprint and the machine key
- the folders Davit may read `docket.toml` files from
- the spool folder and its size cap
- the account tasks run under

## Not in this design

A listener on localhost. Earlier notes had Davit listening on localhost so apps and the CLI could hand it data. The spool folder covers the CLI, and libraries send straight to the server, so nothing here needs it. It stays possible, and off.
