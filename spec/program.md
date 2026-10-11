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
| | `dokkit folder add <path>`, `remove <path>`, `list` | Sets the folders `dokkit watch` reads `dokkit.toml` files from. With the service installed it changes the service's list, which needs an administrator or root; otherwise it changes the signed-in person's own. |
| | `dokkit imessage on`, `off`, `status`, `test <recipient> [words]` | Lets this Mac send iMessages when the server asks, or sends one now to try it. |
| | `dokkit startup on`, `off` | Starts `dokkit watch --background` each time this person signs in. No administrator. |
| | `dokkit service install`, `uninstall`, `update`, `start`, `stop` | Runs as a service. Needs an administrator once. |

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

**It only does what it is told by name.** The server can ask the program to fetch the newer copy of itself, and a Mac to send an iMessage, and nothing else.

**It sends an iMessage only from a Mac told it may.** Alerts by iMessage go out through a Mac signed in to Messages. The server asks with a built-in piece of work, `dokkit:imessage`, naming the recipients and the text; each is sent through the Messages app with `osascript`, the recipient and text passed as arguments and never as part of the script, and the run gets one line per recipient. `dokkit imessage on` records in the saved configuration (`imessage`) that this Mac may, and it is off by default; without it, on any other system, or with no recipient or text, the machine refuses the work. A recipient that is not a phone number or an email address is not sent to, and a text is cut at 1000 characters. `dokkit imessage test <recipient>` sends one from this Mac without the server. The first send makes macOS ask once, on the Mac's screen, whether `dokkit` may control Messages; a signed build is needed for macOS to remember the answer.

**It never asks for antivirus to be turned off.** The declared and user-space levels exist so that getting started never needs an exception.

**A scan writes a proposal.** Nothing a scan finds is watched until it is accepted.

## What a scan looks at

| Part | Finds |
|---|---|
| Services | Installed services and their state. |
| Ports | What is listening, and which program owns it. |
| Containers | Running containers and their images. |
| Sites | Sites configured in a web server. |
| Disks | Volumes and free space. |
| Declarations | `dokkit.toml` files in the allowed folders. |

Each part can be switched off with a flag. The proposal file shows everything found before anything is sent.

A scan never reads file contents, credentials, browser data, or another program's memory.

## Updates

`dokkit` never updates itself, and never replaces its own file. Under the Windows service the built-in update fetches nothing either, for the same reason as on Linux: an administrator puts the newer `dokkit.exe` on the machine and runs it with `service update`. Under the Linux service the built-in update fetches nothing: a file the `dokkit` user could write is not one root should run, so the run says to install the newer program as root (run `get.sh` again) and then run `dokkit service update`. A `dokkit watch` under a login fetches only to its own user-owned copy and says the same about the service: an administrator runs `get.sh` as root, then `dokkit service update`; it never tells root to run a file a login owns. That is the only way an installed Linux service is updated; `service update` also works when `get.sh` has already put the new file in `/usr/local/bin`, and restarts the service. The interface shows when a machine is behind the copy the server holds. A person can ask that machine to fetch the newer copy, the file is left in an `update` folder beside the spool, and the run says where it is and its SHA-256. When the machine's configuration has `update_sha256`, a fetched file with another hash is removed, and so is any copy left in the `update` folder by an earlier fetch. `dokkit enrol` keeps the `update_sha256` already in the configuration file (`config.json` in the machine's configuration folder). The update is finished on the machine by a person, as an administrator: `"<that file>" service update` stops the service, puts the newer copy in its place and starts it. A program that swaps itself for whatever a server sends it, while running as the system account, is the thing this avoids.

`dokkit updater install|uninstall|run|status` installs and drives a separate updater that moves the program, and on Windows the server on the machine that hosts it, to a signed release a person approved in the interface. It works on Windows (a scheduled task), Linux (a systemd timer, or a root crontab line where there is no systemd) and macOS (a LaunchDaemon); on Linux and macOS it is installed by root, finds how the program is kept (system or user unit, LaunchAgent, or a plain `watch --background`) and restarts it that way, and the program keeps running as its own account. The program itself still never replaces its own file. `dokkit version` prints the version a build was made as. The whole design is in [updates.md](updates.md).

## Signing

The project does not hand out builds signed with anyone's certificate. Whoever builds `dokkit` for their own machines signs it with their own code-signing certificate if they have one, which is what keeps antivirus quiet about it; an unsigned build works the same. A build is never packed or compressed into a self-extracting file.

## Configuration

`dokkit`'s own configuration lives outside any app repo and is only editable by an administrator on an installed service. It holds:

- the server address, the certificate fingerprint and the machine key
- the folders `dokkit` may read `dokkit.toml` files from
- the spool folder and its size cap

## Not in this design

A listener on localhost. Earlier notes had `dokkit` listening on localhost so apps and the CLI could hand it data. The spool folder covers the CLI, and libraries send straight to the server, so nothing here needs it. It stays possible, and off.

## Built so far

In `program/`: `dokkit init`, `run`, `ping`, `check`, `apply`, `enrol`, `watch`, `folder`, `status`, `doctor`, `service` and `scan`. With `DOKKIT_URL` and `DOKKIT_KEY` set they use that key; otherwise they use the address and machine key that `dokkit enrol` saved in the user's configuration folder.

`dokkit watch` reads `dokkit.toml` files from the folders in `DOKKIT_FOLDERS` or in the saved configuration, and from the folders directly inside them. It declares each file, runs its `http`, `tcp`, `process`, `windows-service` and `systemd` checks on their own timing, sends the log files it names, says the machine is alive once a minute, and re-reads a file when it changes. `dokkit status` shows what `watch` last wrote down: the files it reads, when the spool was last emptied, and how much is waiting.

`dokkit watch --background` starts the same program detached, writing to `watch.log` in the spool folder, and does nothing when one is already running (a recorded process number counts only while that process is alive). `dokkit startup on` is for Windows and adds it to the signed-in person's own startup programs. `dokkit status` shows the process number to stop it by.

An `http` check with `slow` set reports `degraded`, with the time in milliseconds as its value and a note such as "answered in 2.4 s, slower than 2 s", when the answer succeeds but takes longer than `slow`. The server decides when that becomes an issue. `slow` is refused unless the check is `http`, it is more than zero, and it is less than the check's `timeout` (5 seconds when not set). `dokkit check` prints such an answer as `slow` and does not count it as a failure.

`dokkit help`, `dokkit --help` and `dokkit -h` print the command list. `--help` or `-h` after a known command prints that command's help, unless a `--` comes first, and so does the bare word `help` right after any command except `run` and `ping`, so `dokkit scan help` prints help and runs nothing. For `run` and `ping` only the first argument counts, and only as `--help` or `-h`, so a job named `help` is a job.

`dokkit service` works on Windows and on Linux with systemd; on macOS it says it is not built yet. `dokkit service install` on Linux needs root. It uses the address and key saved by the account named in `SUDO_USER`, or else root's own, says which file it used and which address, and when neither has one says what to run. `get.sh` run without root installs to `~/.local/bin`, which `sudo` does not search, so it prints the `sudo` line with the full path. A failed install removes the unit file and the address and key it had written, so it can be run again, and an uninstall carries on past a `systemctl` step that fails and also clears a half install. It makes a system user named `dokkit` with `useradd` (with no login and no home), or stops and says so when `useradd` is not there. It copies the program to `/usr/local/bin/dokkit`, writes the saved address, key and folders to `/etc/dokkit/config.json` (owned by root, readable by the `dokkit` group), writes `/etc/systemd/system/dokkit.service` to run `dokkit watch` as the `dokkit` user with its spool in `/var/lib/dokkit`, then runs `systemctl daemon-reload` and `systemctl enable --now dokkit.service`. The folders in the configuration must be readable by the `dokkit` user, folders above them searchable by it. Install warns about a folder that looks closed to it, and `dokkit status` and the service's log name each folder it cannot list, since it would otherwise find no `dokkit.toml` and say nothing. `uninstall` stops and disables it, removes the unit file, and removes the address and key from the config, keeping the two lists. It does not tell the server: the machine stays enrolled there and shows as stopped reporting until its key is revoked, and `uninstall` says so. As root, or in the `dokkit` group, `dokkit status` and `dokkit doctor` read the service's configuration and spool. `start`, `stop` and `update` run the matching `systemctl` call; `update` first copies the newer program into place. This has not been run on a real machine yet.

`dokkit service install` on Windows copies the program to `Program Files\DokkitProgram` and the saved address, key and folders to `ProgramData\DokkitProgram`, which only administrators and the system account can change, then registers a service that starts with Windows, runs as Local Service and restarts a minute after a failure. Local Service may read that folder and write only the spool and the log inside it. It cannot read another account's profile folder, so a `dokkit.toml` kept under `C:\Users\<someone>` is not seen by the service; it starts a stopped service only when that service's own permissions let Local Service. `service install` waits for the service to be running and prints the end of its log when it is not. It refuses to install when `ProgramData\DokkitProgram` already exists and is owned by anyone but administrators or the system account, or holds anything but `config.json`, `spool`, `dokkit.log` and `update`, and says what it found. These folders are the program's alone: the server's installer uses `Program Files\Dokkit` and `ProgramData\Dokkit`, which an earlier program used too. `service install` and `service update` find a program installed there (an administrator-owned `config.json` and `dokkit.exe`), copy only its `config.json`, `spool` and `dokkit.log` to the new folder, point the service at the new `dokkit.exe`, and leave everything in the old folders as it was, saying where the old copies are. The folder is set once, with inheritance off and no `/T`, and what is inside is then reset to inherit from it. From an administrator prompt, `dokkit status` and `dokkit doctor` read that configuration. On other systems, `dokkit watch` runs from a systemd unit.

`dokkit scan` writes `dokkit-proposal.json` in the current folder, and each part has a `--no-` flag.

`dokkit watch` holds a request open to the server and does the work it is given, one run at a time. A name it does not know is answered with a refusal. A result that cannot be delivered is sent again for several minutes. The server ends a run still running after 12 hours, or still queued after a day.

`dokkit enrol` takes the server certificate's fingerprint as a third argument, saves it, and from then on trusts the certificate with that fingerprint and no other. The enrol page shows the fingerprint when the server is started with `DOKKIT_CERT` and `DOKKIT_CERT_KEY` and so serves TLS itself.

`dokkit propose` sends the file a scan wrote. Each minute `dokkit watch` asks the server for the checks added in the interface for its machine and runs them beside the ones in files.

Each minute `dokkit watch` reads the first line of the file a `version_from` names and reports it as that service's version. A `version_from` that is a command is not run: nothing has accepted that command. `version_from`, `[logs] path` and an `expiry` file must stay inside the folder of the `dokkit.toml` that names them, links followed.

Each minute it also sends the machine's processor, memory and disk use as `metric` lines and fetches the stats document of each service with a `[stats]` section, sending the key from the variable `key_env` names as `X-Stats-Key`. `key_env` must start with `DOKKIT_STATS_`; a file that names any other variable is still read, but its stats fetch sends no key and reports down. Checks and stats fetches run at once, and logs are sent on their own timer every five seconds, so one slow check holds nothing back. An `expiry` check reads its date from `date_from`: an `https` address or `host:port` for a certificate, or a file whose first line is a date. It is degraded inside 30 days and down once past; days left are shown rounded up, and a bare date lasts through that day (UTC). A certificate is not verified, so a self-signed one is read like any other; only its date is used.

The installed service starts a stopped Windows service again, and restarts a stopped `systemd` unit (the check's `name`, state from `systemctl show`) with `systemctl restart`, when its service page allows that and the service or unit is named in the `restart` list of `ProgramData\DokkitProgram\config.json`, at most once in ten minutes, and says so: the check's good answer carries the note, and a warning log line for the service says it, since the next good answer replaces the note. The unit's state comes from `systemctl show` (`ActiveState`, `SubState`, `Result`, `NRestarts`) and standard output only. A unit that is `activating`, `reloading` or `deactivating` is reported `degraded` and never restarted, but a unit that is `activating` with `SubState=auto-restart` or a failed `Result` is down (systemd is restarting it after a failure, so nothing is restarted from here), and so is one still busy on the third consecutive check. A restart that takes over 30 seconds is abandoned by the program, and no restart holds up the other checks. `nginx` and `nginx.service` count as one unit. `dokkit watch` under a login never restarts anything; on Linux only the unit that `service install` writes does (the program tells it by `INVOCATION_ID` and `DOKKIT_CONFIG`). A check the server gives for another machine's address is not run unless that address is in the `hosts` list of the same file; this machine's own name, loopback and interface addresses always count. A refused check reports down with a note saying so. Neither list is read from anywhere else, and both stay in the file across an uninstall. On Linux and macOS the file is `/etc/dokkit/config.json`, read only when root owns it and the folder and nobody else can write to either. This has not been run against a real service or unit yet. The Linux service runs as the `dokkit` user, and systemd refuses that user a restart unless a polkit rule allows it, so a `systemd` check restarts a unit only where `dokkit` runs as root or has such a rule; otherwise it reports down.


`dokkit folder add <path>` puts a folder in the list `dokkit watch` reads (`dokkit.toml` files in it and in the folders directly inside it), `remove <path>` takes one out and `list` shows them. The path is made absolute and for `add` must exist; adding one twice changes nothing. The list is in `folders` in the configuration the watching program reads: the installed service's (`/etc/dokkit/config.json`, or `ProgramData\DokkitProgram\config.json`) when one is installed, otherwise the signed-in person's own. Changing the service's list needs an administrator or root, and without one the command prints the exact `sudo` line with the program's full path; the rest of the file is kept and, on Linux, it stays owned by root and readable by the `dokkit` group. On Linux, `add` warns when the `dokkit` user cannot read the folder. `dokkit watch` reads the list again each minute, so a change needs no restart; `DOKKIT_FOLDERS` still overrides it. The installed service reads `folders` only while the file and its folder cannot be written by anyone but root (an administrator on Windows), the same test the `restart` and `hosts` lists pass, and ignores the list otherwise. `dokkit init` ends with the `dokkit folder add <this folder>` line, with `sudo` and the full path when the service is installed. `dokkit status` run by a member of the `dokkit` group, who cannot read the service's `status.json`, says to run it with `sudo`.
