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
| | `--service <slug>` on either | The service the job is declared under. Without it the program finds the `[[job]]` of that name in the `dokkit.toml` files it reads. |
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

**Nothing is lost when the server is unreachable.** Everything goes to a spool folder on disk first and is sent from there. A log file's read position only moves forward after the server confirms it has the lines. The spool has a size cap, 500 MB by default, set with `DOKKIT_SPOOL_MB` or `spool_mb` in the saved configuration. When it is hit, the oldest goes and the number dropped is reported to the server as a warning log line. A batch the server keeps answering with an error is set aside (renamed `.rejected`) once the server has taken others since, so it does not hold up the rest.

**`dokkit run` and `dokkit ping` work with or without `dokkit` running.** If it is running they leave their report in the spool folder. If not, they send it themselves.

**It only runs accepted, named tasks.** A task is defined on the machine, accepted in the interface, and pinned to what was accepted: the exact command, the path of the file that declares it and the contents of the script it names. The server can ask for a task by name and nothing else.

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

`dokkit` never updates itself, and never replaces its own file. The interface shows when a machine is behind the copy the server holds. A person can ask that machine to fetch the newer copy, which is a built-in task: the file is left in an `update` folder beside the spool, and the run says where it is and its SHA-256. When the machine's configuration has `update_sha256`, a fetched file with another hash is removed, and so is any copy left in the `update` folder by an earlier fetch. `dokkit enrol` keeps the `system_tasks` and `update_sha256` already in the configuration file (`config.json` in the machine's configuration folder). The update is finished on the machine by a person, as an administrator: `"<that file>" service update` stops the service, puts the newer copy in its place and starts it. A program that swaps itself for whatever a server sends it, while running as the system account, is the thing this avoids.

## Signing

The project does not hand out builds signed with anyone's certificate. Whoever builds `dokkit` for their own machines signs it with their own code-signing certificate if they have one, which is what keeps antivirus quiet about it; an unsigned build works the same. A build is never packed or compressed into a self-extracting file.

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

`dokkit service install` is for Windows. It copies the program to `Program Files\Dokkit` and the saved address, key and folders to `ProgramData\dokkit`, which only administrators and the system account can read, then registers a service that starts with Windows and restarts a minute after a failure. It refuses to install when `ProgramData\dokkit` already exists and is owned by anyone but administrators or the system account. From an administrator prompt, `dokkit status` and `dokkit doctor` read that configuration. On other systems, `dokkit watch` runs from a systemd unit.

`dokkit scan` writes `dokkit-proposal.json` in the current folder, and each part has a `--no-` flag. `dokkit task list` and `dokkit task run` read the tasks in the current folder's `dokkit.toml` and in the folders the machine reads. A task runs in its file's folder and stops at its `timeout`, an hour when none is given. On Windows a bare file name that is in that folder (`run = "backup.bat"`) is run from there; any other command is looked up on the path only. A task that exits normally while something it started keeps running counts as having exited, with its output cut off at that point. A task name that two files declare runs from neither. A task accepted for the system account is refused until the machine's own configuration has `system_tasks` set to true, which includes every system-account task accepted before that setting existed. A machine running as root on Linux cannot drop to an ordinary account, so only tasks accepted for the system account run there.

`dokkit watch` holds a request open to the server and runs the task runs it is given, one at a time, sending output every three seconds. It refuses a task whose pin (command, declaring file path and script contents) is not the one that was accepted. The installed Windows service also refuses a task whose folder is not owned by administrators or the system account, and says so in the run's result. Under a login a task runs as that person. The installed service is the system account, so it runs a task as Local Service, the account Windows keeps for programs that need no rights, unless the task was accepted with "Accept, as the system account". If it cannot get that account the task is not run. A task accepted for the system account runs only when the machine's own configuration file has `"system_tasks": true`; otherwise the run is refused and says why. Run as root on Linux, no task is dropped to an ordinary account, so only a task accepted for the system account runs. A task name declared in more than one file runs from neither. A task's environment sets `NoDefaultCurrentDirectoryInExePath=1`, and after a timeout the program waits five seconds for output and then stops waiting. A result that cannot be delivered is sent again for several minutes. The server ends a run still running after 12 hours, or still queued after a day. Running as Local Service has not been tried on a real machine yet.

`dokkit enrol` takes the server certificate's fingerprint as a third argument, saves it, and from then on trusts the certificate with that fingerprint and no other. The enrol page shows the fingerprint when the server is started with `DOKKIT_CERT` and `DOKKIT_CERT_KEY` and so serves TLS itself.

`dokkit propose` sends the file a scan wrote. Each minute `dokkit watch` asks the server for the checks added in the interface for its machine and runs them beside the ones in files.

Each minute `dokkit watch` reads the first line of the file a `version_from` names and reports it as that service's version. A `version_from` that is a command is not run: nothing has accepted that command. `version_from`, `[logs] path` and an `expiry` file must stay inside the folder of the `dokkit.toml` that names them, links followed.

Each minute it also sends the machine's processor, memory and disk use as `metric` lines and fetches the stats document of each service with a `[stats]` section, sending the key from the variable `key_env` names as `X-Stats-Key`. `key_env` must start with `DOKKIT_STATS_`; a file that names any other variable is still read, but its stats fetch sends no key and reports down. Checks and stats fetches run at once, and logs are sent on their own timer every five seconds, so one slow check holds nothing back. An `expiry` check reads its date from `date_from`: an `https` address or `host:port` for a certificate, or a file whose first line is a date. It is degraded inside 30 days and down once past; days left are shown rounded up, and a bare date lasts through that day (UTC). A certificate is not verified, so a self-signed one is read like any other; only its date is used.

The installed service starts a stopped Windows service again when its service page allows that and the service is named in the `restart` list of `ProgramData\dokkit\config.json`, at most once in ten minutes, and says so on the check. `dokkit watch` under a login never does. A check the server gives for another machine's address is not run unless that address is in the `hosts` list of the same file; this machine's own name, loopback and interface addresses always count. A refused check reports down with a note saying so. Neither list is read from anywhere else, and both stay in the file across an uninstall. On Linux and macOS the file is `/etc/dokkit/config.json`, read only when root owns it and the folder and nobody else can write to either. This has not been run against a real service yet.

`dokkit task list` asks the server which pins were accepted for this machine and says of each task whether it is accepted, not accepted yet, or changed since it was accepted, and which account tasks run as.
