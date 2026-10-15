# Updates

A machine is updated without anyone going to it. One elevated command per machine, once, installs **the updater**. After that an update is approved in the interface and the updater does the rest. It installs only a release signed with the project's release key.

The program never replaces its own file, and its service stays an ordinary account. The updater is a separate small piece whose only job is updating.

## A release

The release workflow builds the files, then writes two more:

- `SHA256SUMS`: the first line is `version v1.2.3`, then one line per file, `<sha-256 in lower-case hex><two spaces><file name>`, the way `sha256sum` writes it. Line endings are `\n`.
- `SHA256SUMS.sig`: the Ed25519 signature of the exact bytes of `SHA256SUMS`, in base64, on one line.

The first install checks the same signature. `get.sh`, `get.ps1` and the Windows server's `install.ps1` fetch `SHA256SUMS` and `SHA256SUMS.sig` from the folder the files come from, check the signature against the public key written in the script, then check the file's SHA-256 against the signed list, and install nothing when any step fails. The signature is checked with `openssl pkeyutl -verify -rawin` where `openssl` is OpenSSL 3, otherwise with perl (`Math::BigInt`, `Digest::SHA`), otherwise with python3's standard library; macOS has only LibreSSL, which cannot verify Ed25519, and relies on its perl. `get.ps1` and `install.ps1` verify with .NET's `BigInteger` and need nothing beyond Windows PowerShell 5.1. A machine with none of them is told so and nothing is installed. Another source is `DOKKIT_RELEASE_BASE` (`DOKKIT_RELEASE_URL` for `install.ps1`); a Dokkit server's release store is `https://<server>/api/v1/releases/<version>`, which needs a machine key given as `DOKKIT_RELEASE_KEY`.

The private key is the repository secret `RELEASE_SIGNING_KEY` (PEM, PKCS#8) and exists nowhere else. The public key is 32 bytes, in base64:

```
xX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk=
```

It is a constant in the program's source. A version is `v` and three numbers. Every built file knows its version: the program prints it with `dokkit version`, and the server's is in its release.

## The server holds releases

An owner, or a token with `admin`, puts a release's files on the server. The server stores them and serves them back; it does not check them, because the updater does.

| Call | Who | What |
|---|---|---|
| `PUT /api/v1/releases/<version>/<file>` | `admin` | The body is the file, as is. Up to 200 MB. Replaces a file of that name. |
| `GET /api/v1/releases` | `read` | The versions held, each with its file names and whether it has both `SHA256SUMS` and `SHA256SUMS.sig`. |
| `DELETE /api/v1/releases/<version>` | `admin` | Removes that version's files. |
| `GET /api/v1/releases/<version>/<file>` | a machine key | The file. |

Files live in a `releases` folder beside the server's settings (`DOKKIT_RELEASES` names another place), one folder per version. A version or file name that is anything but letters, digits, dots, dashes and underscores is refused.

## Approving

Each machine has a wanted version, empty until someone asks. `POST /api/v1/machines/<id>/update` with `{"version": "v1.2.3"}` sets it (`admin`), and only to a version the server holds completely. `POST /api/v1/update-all` with the same body sets it on every machine that has an updater. In the interface these are **Update** on a machine and **Update all**, shown to the owner when the server holds a version newer than the machine reports. The machine's row says what it is on, what it was asked to move to, and the last result.

Nothing updates until someone asks. There is no automatic following of new releases.

## What the updater asks

It uses the program's own address, machine key and certificate pin, from the program's configuration.

`GET /api/v1/update?program=<version>&server=<version>&updater=<version>&os=<os>&arch=<arch>`

- `program` and `updater` are the versions installed. `server` is the server's installed version when this machine runs the server, and is left out otherwise.
- The server remembers these as what the machine is on, and that it has an updater (and whether it hosts the server).
- The answer is `204` when the machine has no wanted version or is already on it. Otherwise `200` with `{"version": "v1.2.3"}`.

`POST /api/v1/update/result` with `{"version": "v1.2.3", "ok": true, "note": "program, updater"}` or `{"version": "v1.2.3", "ok": false, "note": "<what went wrong, at most 2000 characters>"}`. The server keeps the last result for the machine and clears the wanted version when `ok` is true.

## What the updater does with an answer

1. Fetches `SHA256SUMS` and `SHA256SUMS.sig` for that version from `GET /api/v1/releases/<version>/<file>`.
2. Checks the signature with the built-in public key. If it does not check, it stops and reports that.
3. Checks the first line names the version it was told, and that the version is not older than anything installed. It never goes backwards.
4. For each part this machine has, fetches the file for its system, checks its SHA-256 against the list, and installs it:
   - **the server**, on the machine that runs it: `dokkit-windows-x64.zip`. It is unpacked into the updater's own folder and its `install.ps1` is run with no arguments, which upgrades in place. It is done when the server answers again.
   - **the program**: `dokkit-<os>-<arch>` (with `.exe` on Windows). The service is stopped, the file replaced, the service started, and it is done when the service is running. If it does not start, the old file is put back and started. On Linux and macOS the file is replaced first and the program restarted (see below).
   - **the updater itself**, last: the same program file, copied over the updater's own copy.
5. Reports the result. A result that cannot be sent, because the server it just restarted is not answering yet, is kept and sent on the next run.

A file it has fetched lives in a folder only administrators and the system account can write. Nothing in it is run before its hash is checked against the signed list.

## Starting a check early

The five-minute check stays everywhere. On top of it, setting a wanted version on a machine that has an updater (Update, Update all) queues the built-in work `dokkit:nudge` for that machine, one at a time per machine, so a connected program takes it within seconds. It carries no version and no parameters: the program asks its machine's updater to check now, answers done (or refuses with the reason it could not), and the updater asks the server what to install as always. Nothing with administrator or root rights listens on a port, and the server still cannot make a machine run anything but an approved, signed release.

- **Windows:** the program writes one entry to the Application event log, source `Dokkit`, event ID 100, message "Update requested". Any account may write to the Application log, Local Service included, and nothing else is granted to it. The task **Dokkit updater** has an event trigger on that entry (`*[System[Provider[@Name='Dokkit'] and EventID=100]]` in the Application log) beside its five-minute and start-up triggers, so Task Scheduler starts the updater as the system account. The task keeps `MultipleInstancesPolicy` `IgnoreNew`, so an entry written during a running check starts nothing. The updater registers the source `Dokkit` when it registers the task (`HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\Dokkit`, with `EventCreate.exe` as the message file; left alone when it exists), and `updater uninstall` removes it. The task has no security descriptor of its own any more: Local Service cannot start or read it. (`schtasks /run` by Local Service was refused with Access is denied on every Windows machine even with a grant for it.)
- **Linux with systemd:** a root unit `dokkit-updater.path` has `PathChanged=/var/lib/dokkit-nudge/now` and `Unit=dokkit-updater.service`. The program writes that file. The folder `/var/lib/dokkit-nudge` is owned by the program's account (mode 0700) and is the only place that account can write for this; the updater's own folders stay closed to it. The updater only creates the folder and the file when they are missing, and never opens a link in it.
- **macOS:** the LaunchDaemon `com.dokkit.updater` has `WatchPaths` on `/var/db/dokkit-nudge/now`, a folder owned the same way. The program writes that file.
- **Cron (including a QNAP):** there is no nudge. The program answers that the machine updates on its next scheduled check.
- **The 30-second rule:** a run that starts less than 30 seconds after the last run ended waits until the 30 seconds are up and then checks, so a stream of nudges makes at most one check every 30 seconds, and a nudge that lands just after a timed check is not lost.

## The updater keeps its own schedule current

A machine's task, units or plist were written by whichever updater installed them. At the end of every run (it has full rights) the updater checks they are the current ones and, if not, writes the current ones. Nothing is changed when they match, and it writes one log line when it does change something. A rehearsal never does this. A missing task or unit is not recreated: that is an uninstall.

- **Windows:** the task's description carries a marker made from the hash of the task text. When the task read back with `schtasks /query /xml` lacks the current marker, the updater registers the event source (if missing) and the task again from the current XML (`schtasks /create /xml /f`).
- **systemd:** the service, timer and path units are compared with the current text; any that differ are written, then `systemctl daemon-reload`, and `dokkit-updater.path` is enabled and started. A reload leaves the running job alone. The nudge folder is made if missing.
- **macOS:** the plist is compared and, if different, written. Loading it again stops the job that is running, which is the updater, so a helper process started in its own session does that after the run has ended (`launchctl bootout`, then `bootstrap`, with one retry). The plist keeps `AbandonProcessGroup`, so the helper outlives the job.
- **Cron:** nothing to change.

A machine whose updater is older than this one is brought forward by the ordinary five-minute check: once approved to the first version that has this, its updater replaces itself and, on its next run, brings the schedule up to date. Nobody visits the machine.

## On Windows

`dokkit updater install`, from an administrator prompt, once:

- copies the program to `Program Files\DokkitUpdater\dokkit-updater.exe`;
- makes `ProgramData\DokkitUpdater`, for administrators and the system account only, for its state, its log and fetched files;
- registers a scheduled task, **Dokkit updater**, that runs `dokkit-updater.exe updater run` as the system account every five minutes, at start-up and when the program writes its event (see Starting a check early). It is not a service and listens on nothing;
- runs it once and prints what it found.

`dokkit updater install` needs the program's service installed first (`dokkit service install`): the updater takes the server address and key from it, and without it the command changes nothing and says so.

`dokkit updater status` prints the installed versions, the last check and the last result. `dokkit updater run` is what the task runs; from an administrator prompt it does one check now. `dokkit updater uninstall` removes the task and the copied file.

`dokkit updater rehearse <folder>` does one real check against the server, with the real signature and hash checks, but installs into that folder only: no service is touched, no installer is run and no result is sent. It needs no administrator; on Windows `--server` also rehearses the server part.

## On Linux and macOS

`dokkit updater install`, as root (`sudo`), once. The program keeps running as whatever account runs it; only the updater has root.

- It finds the running `dokkit watch` and how that is kept, and records it. The ways are: a systemd system unit (the one `dokkit service install` writes, or any other), a systemd user unit, a LaunchAgent in a person's session, or a plain background process started with `dokkit watch --background`. A unit is told apart by being the main process of a service; a LaunchAgent by the label `launchctl list` gives that process's account. A program started by cron or a script is a plain process. If more than one program is running it picks the one run by a system unit, then the one run by the account that ran `sudo`, and otherwise stops and names them. If none is running it uses the installed system unit if there is one, and otherwise stops.
- It checks the program's configuration (`DOKKIT_CONFIG` of the running process, else the account's own) holds an address and key. The updater reads that file, as root, each run; it keeps no copy of the key.
- It copies the program to a folder only root can change, `/usr/local/lib/dokkit-updater/dokkit` on Linux and `/Library/Application Support/DokkitUpdater/dokkit` on macOS, and writes `config.json` beside it: the program's file, the account that runs it, how it is kept (`system-unit`, `user-unit`, `launch-agent` or `process`), the unit or label, its configuration and spool, and any of `DOKKIT_CONFIG`, `DOKKIT_SPOOL`, `DOKKIT_SPOOL_MB`, `DOKKIT_FOLDERS`, `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` that process had (read from the process on Linux only; on macOS the account own folders are assumed). That file is writable by root only and holds no key. The updater's state, log and fetched files are in `/var/lib/dokkit-updater` (Linux) or `/var/db/dokkit-updater` (macOS), mode 0700. It refuses a folder of those names that root does not own, that others can write, or that holds anything the updater did not put there.
- It sets up a timer that runs `updater run` as root every five minutes, and says which and where:
  - where systemd is running: `dokkit-updater.service` (one-shot) and `dokkit-updater.timer` in `/etc/systemd/system`, started a minute after boot and five minutes after each run ends, and `dokkit-updater.path`, which starts the service when the program writes the nudge file;
  - on macOS: the LaunchDaemon `com.dokkit.updater` in `/Library/LaunchDaemons`, `StartInterval` 300 and `WatchPaths` on the nudge file;
  - otherwise: a line ending `# dokkit-updater` in root's crontab. Where `/etc/config/crontab` exists (QNAP), that file is edited and loaded with `crontab /etc/config/crontab`. `crond` is not restarted: it rereads what is loaded, and QNAP's `crond.sh restart` rewrites and reorders the other lines of that file.
- It runs one check and prints what it found.

`updater run` does what the contract above says, with these differences:

- **The program** is replaced by writing the new file beside the old one under a name nobody else can have made (it refuses a name that already exists, including a link), flushing it, giving it the old file's owner and mode, and renaming it over the old one. The old file is kept as `.previous`, with the same owner and mode. Nothing is signed, unpacked or marked again: the file is the signed release's bytes, which is what keeps a macOS code signature valid and leaves no quarantine attribute on it.
- **The program is restarted** the way it is kept, and the update is done when it is running and still running five seconds later:
  - system unit: `systemctl restart`;
  - user unit: `systemctl --user restart`, run through `runuser` as that account with its `XDG_RUNTIME_DIR` and bus address;
  - LaunchAgent: `launchctl kickstart -k gui/<uid>/<label>`, given up to two minutes because launchd holds it until the job's throttle interval since its last start has passed;
  - plain process: the process number in `status.json` in the program's spool is stopped (`SIGTERM`, then `SIGKILL` after twenty seconds) only when that process is alive and is running the program's file (`/proc/<pid>/exe`, or `ps` on macOS); the program's file is never found by name. It is then started as the owning account with `dokkit watch --background`, with `HOME`, `USER`, `PATH` and the recorded variables, and it is done when `status.json` shows a new process running that file.
- If it does not run, the old file is put back and restarted the same way, and the failure is reported.
- **A program path that is a link, or anything but a plain file, is refused** before anything is copied or replaced.
- **The program's file is never run with root's rights.** Reading its version for the check runs it as the account that owns it.
- The server is not hosted by this updater on these systems; `server` is left out of the question, and the updater itself is replaced last, as on Windows.

**On a QNAP** (no systemd, `/etc/config/crontab` present) the root file system is memory and is emptied at every restart, while the crontab line survives. So the updater lives on the data volume that holds the program being looked after: `<volume>/.dokkit-updater/program` (its copy of the program and `config.json`) and `<volume>/.dokkit-updater/data` (state, log, fetched files). The volume is the mount point, from `/proc/mounts`, that holds the program's file; a program on the root file system is refused. `.dokkit-updater` is owned by root, mode 0700, a dot-folder at the volume's top, which QNAP does not share, and it holds only those two folders. After a restart the updater finds its folder from the path in its own crontab line.

A plain background program is started by `dokkit watch --background`, which takes a lock in the spool and holds it until the new process appears in `status.json`. The updater and a start script run from cron by the same minute therefore cannot start two.

`dokkit updater status` prints the versions, what the updater looks after and how, the last check and the last result (the last two to root only). `dokkit updater uninstall`, as root, removes the timer (the units, the plist or the crontab line), the updater's copy of the program and `config.json`. Its state, log and nudge folder are left. `dokkit updater rehearse <folder>` does one real check into a folder of its own, restarts nothing and sends no result; it needs no root.

## What a takeover can do

- **The server:** it can ask a machine to move to a version, but only a signed release installs, and never an older one.
- **The program's own account:** it cannot write the updater, its folder or its task.
- **The release workflow or its key:** it can sign anything. That is the one place to protect.
