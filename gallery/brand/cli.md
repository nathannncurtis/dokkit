# The `dokkit` command line

One program on each watched machine, also used in an app's repo. `dokkit help` prints this list and `dokkit help <command>` says more about one.


## In an app's repo


### `dokkit init`

Asks what the app is and writes dokkit.toml. Asks a few questions and writes a dokkit.toml in this folder: what the app is, and how to tell it is healthy. Nothing is sent.


### `dokkit check [dokkit.toml]`

Runs the checks it can once and prints what would be sent. Checks the file's schema, service id and each check's fields. Runs the http, tcp, process, windows-service, systemd and expiry checks that can run here, once, and prints exactly what would be sent. Checks the app reports itself are listed as not run. A check aimed at another host does make its request. Needs no server and sends nothing to it. A slow answer shows as slow, not as a failure.


### `dokkit apply [dokkit.toml]`

Sends the file to the server. Declares the file to the server, for a file dokkit watch does not read. It sends DOKKIT_KEY when that is set, otherwise this machine's key from dokkit enrol. A machine key may declare any service on its machine; an app key only its own service. Sending the same file twice changes nothing.


## Jobs


### `dokkit run [--service <slug>] --job <name> -- <command> [arguments]`

Runs a command and reports how it went. Runs the command and reports its start, finish, exit code, duration and last lines of output. Exits with the command's own exit code. With this machine's key, a job declared in a dokkit.toml in the folders of the saved configuration is found by name, and --service says which service when it is not. With an app key, --service is ignored.


### `dokkit ping [--service <slug>] <name> [start|ok|fail]`

Reports a job that cannot be wrapped. Reports one event for a job: start, ok (the default) or fail.


## This machine


### `dokkit enrol <address> <token> [sha256:<certificate fingerprint>]`

Joins this machine to a server. Trades a one-time token for this machine's key and saves it. Given a fingerprint, it trusts the certificate with that fingerprint and no other.


### `dokkit status`

What this machine watches and when it last reported. Shows the files dokkit watch reads, when it last sent, and how many reports are waiting, and any folder it cannot read. It says a watch is running only while that watch has written down in the last three minutes, and then gives its process number. On Linux it shows the installed service when root, or the dokkit group, can read its files; the service's status itself can be read only with sudo.


### `dokkit quiet <length> [reason]`

Tells the server this machine is going down on purpose. Sends what is waiting in the spool, then tells the server this machine will be down for the length given (such as 90s, 15m or 4h; at most 4h), with an optional reason. For that long the server opens no issue and sends nothing for the machine going silent or its checks failing; when the time is up, or the machine has reported again and each of its checks has, the usual rules resume, and a machine still silent then is reported as stopped. It prints one line and exits 0 once the server has answered, and prints why and exits 1 when it could not be told, so a script can decide whether to go ahead. A second call replaces the window. Uses this machine's key.


### `dokkit quiet end`

Ends the planned downtime now. Tells the server the wait is over: the usual rules apply from this moment.


### `dokkit doctor`

Checks the server, the key and the clock, and says what to do. Says whether the server answers and knows this key, whether this machine's clock is within 30 seconds of the server's (a slow answer counts as clock difference, up to 10 seconds), and whether reports are waiting. Each way it can fail reads differently and ends with the one thing to do: a name that does not resolve, a port nothing listens on, no answer in time, a certificate that is not the one saved at enrol (a pin mismatch), one no authority signed, a key the server does not know, a clock off by over 30 seconds. On a Mac whose background copy runs but cannot send to a server on the local network while this terminal can, it says macOS's local network privacy is the likely cause and what to allow.


## Finding things


### `dokkit scan [--no-services] [--no-ports] [--no-containers] [--no-sites] [--no-disks] [--no-jobs] [--no-declarations]`

Looks over this machine and writes a proposal file. Lists what is on the machine that could be watched and writes it to dokkit-proposal.json in this folder. Sends nothing. Each --no- flag leaves one kind of thing out. Jobs are scheduled work: Task Scheduler tasks on Windows, cron entries and systemd timers on Linux, cron entries and launchd jobs on macOS. Each is listed with its schedule, last run and command line, to be watched, never run. A scan uses the machine's own listings, takes a few seconds and changes nothing. dokkit watch does the same on its own shortly after it starts and once a day, and when the Found page asks it to look again.


### `dokkit propose`

Sends the proposal file to be accepted. Sends dokkit-proposal.json, which a scan wrote. Nothing in it is watched until a person accepts it in the interface, or a token allowed to act accepts it through the API.


## Staying running


### `dokkit watch [--background]`

Watches this machine, as an ordinary program. Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved configuration, and from the folders directly inside them. Runs their checks, sends the log files they name, and says the machine is alive once a minute. No administrator, no service. --background leaves it running after this window closes. Run like this, it never restarts a service or unit; only the installed service does.


## Finding things


### `dokkit import seq --from <seq address> [--seq-key <key>] [--to <address>] [--key <app key>] [--default-service <id>] [--map <file>] [--service-property <names>] [--app-pattern <regex>] [--state <file>] [--since <time>] [--until <time>] [--rate <lines a second>] [--filter <expression>] [--dry-run]`

Copies a Seq server's stored events into Dokkit, oldest first. Reads the events with Seq's read API and sends them through the server's normal log intake, each with its original time. --seq-key (or SEQ_API_KEY) is a Seq key that may read. --to (or DOKKIT_URL) is the Dokkit server; --key (or DOKKIT_KEY) is the app key of the service that takes events with no service of their own, named by --default-service. --service-property lists the Seq properties, in order, that hold an event's app (default Application). --app-pattern is a regular expression with one group, used on the message when none of those is set. --map is a JSON file from each such value to {"service": "<id>", "key": "<app key>"}. The last event sent is kept in --state, so a stopped import continues and a second run adds only what is new. Events more than 364 days old are counted and not sent, because the server stamps a line that old with its arrival. --dry-run reads and counts per service and per month and writes nothing. --since and --until bound the times read. --rate caps the lines a second (default no cap). It retries a refused or lost connection to Seq or the server for at least ten minutes, prints a progress line a minute, and says on stderr which side failed if it stops; run it again to continue. --filter is a Seq filter expression.


## Staying running


### `dokkit folder add|remove <path>`

Sets which folders dokkit watch reads dokkit.toml files from. Adds a folder to the list dokkit watch reads dokkit.toml files from, or takes one out. It reads the dokkit.toml in the folder and in the folders directly inside it. The path is made absolute, and for add the folder must exist. Adding one twice changes nothing. A running watch picks up the change within a minute, with no restart. When the service is installed this changes the service's list, which needs an administrator, or root on Linux, and it prints the exact line to run. Otherwise it changes your own list. On Linux, it warns when the dokkit user cannot read the folder.


### `dokkit folder list`

Shows those folders. Lists the folders dokkit watch reads dokkit.toml files from: the installed service's when there is one, otherwise your own, and any it cannot read.


### `dokkit imessage on|off|status`

Lets this Mac send iMessages when the server asks. Alerts by iMessage go out through a Mac that is signed in to Messages. Nothing is sent unless this Mac was told it may: on records that it may, off takes it back, and status says which. Off is the default, and on works on a Mac only. A running dokkit watch picks the change up with no restart. When the service is installed this changes the service's configuration, which needs an administrator, or root, and it prints the exact line to run.


### `dokkit imessage test <recipient> [words...]`

Sends one iMessage from this Mac now, to prove Messages works. Sends the words, or a short test message, to a phone number or an email address through Messages on this Mac, without the server, and prints sent to <recipient> or the reason it was not. It works whether or not on was run. The first send makes macOS ask once, on this Mac's screen, whether dokkit may control Messages; allow it, or switch it on under System Settings, Privacy & Security, Automation. macOS remembers the answer only for a signed build of dokkit. A message is cut at 1000 characters.


### `dokkit relay add <name>`

Makes a mailbox on this relay. Makes a mailbox in the relay's data folder (DOKKIT_RELAY_DIR, else relay inside dokkit's configuration folder) and prints its address and its upload key once. The name is only a label on this host.


### `dokkit relay list`

Shows the mailboxes. Shows each mailbox with its name, id, the time of the last upload and each slot's last fetch.


### `dokkit relay remove <name>`

Removes a mailbox and its files. Removes the mailbox with that name and the envelope it holds.


### `dokkit relay serve --http <address>`

Serves the relay over plain HTTP, for a reverse proxy. Serves PUT /m/<mailbox> (upload key) and GET /m/<mailbox>/<slot> (a phone's fetch token) on the address, such as 127.0.0.1:8080, and writes one access line per request to standard output. It never opens or logs a sealed part.


### `dokkit startup on|off`

Starts dokkit watch each time you sign in. Windows only. Works on Windows only so far. Adds dokkit watch --background to your own startup programs, or takes it out. No administrator. On Linux, use dokkit service, or add dokkit watch --background to your desktop's startup programs. On macOS, add it to a launchd job.


### `dokkit service install|uninstall|update|start|stop`

Runs it as a service, on Windows, Linux or macOS. Needs an administrator or root. Works on Windows, on Linux with systemd and on macOS. Installs dokkit as a service that starts with the machine, so it keeps watching with nobody signed in. On Windows it runs as Local Service, an account with no rights of its own, and reads only what that account can read, which leaves out other people's profile folders. On Linux it runs as a user named dokkit, which is made if useradd is there, and it reads only the folders that user can read. It may restart only the services or units that this machine's own configuration names, and only where the machine lets its account: on Windows the service's own permissions, on Linux root or systemd. On Windows it keeps to Program Files\DokkitProgram and ProgramData\DokkitProgram, and install refuses a data folder that holds anything but config.json, spool, dokkit.log and update. A program installed in the older Program Files\Dokkit and ProgramData\dokkit is moved by install or update: its config.json, spool and dokkit.log are copied, the service is pointed at the new copy, and the old files are left where they are. On macOS it is a LaunchDaemon, dev.dokkit.service, run as a hidden account named _dokkit that has no login and no rights; it keeps its files in /Library/Application Support/Dokkit and /var/db/dokkit, and install moves the waiting reports of your own setup, turns your own dokkit LaunchAgent off (its file is left, and the line to turn it on again is printed) and stops a plain background copy. A Mac that sends iMessages stays on its LaunchAgent, because only a signed-in user's session can drive Messages; install says so and stops. Needs an administrator prompt on Windows and root on Linux and macOS. On Linux and macOS, run through sudo, it uses the enrolment of the account that ran sudo, and root's own when that account has none, and says which file it used. update puts this copy in place of the installed one and restarts the service. uninstall leaves the machine enrolled on the server.


### `dokkit updater install|uninstall|run|status|rehearse <folder>`

Updates the program, and the server on the machine that runs it, when asked. install, once, from an administrator prompt on Windows or as root on Linux and macOS, sets up a separate updater that runs every five minutes with full rights, while the program keeps running as it does now. On Windows it copies this program to Program Files\DokkitUpdater, makes ProgramData\DokkitUpdater for administrators and the system account only, registers the scheduled task Dokkit updater (system account, every five minutes and at start-up), and needs the program's service installed first. On Linux and macOS it finds the running dokkit watch and how it is kept (a systemd system or user unit, a LaunchAgent, or a plain background process), copies this program to /usr/local/lib/dokkit-updater (Linux) or /Library/Application Support/DokkitUpdater (macOS), records what it found in config.json beside it, and sets up the timer: a systemd timer where systemd runs, a LaunchDaemon on macOS, otherwise a root crontab line (/etc/config/crontab on a QNAP). It prints what it installed and where. install runs one check. run is what the timer runs: it asks the server whether this machine has been told to move to a version, and only installs a release whose list is signed with the project's release key and whose files match it. It never installs an older version. On Linux and macOS it replaces the program's file with a rename that keeps its owner and mode, keeps the old one as .previous, restarts the program the way it is kept, checks it is running, and puts the old file back if it is not. status prints the installed versions, the last check and the last result. uninstall removes the timer and the updater's own files. rehearse <folder> does one real check with the real signature and hash checks but installs into that folder only: no service is touched, no installer is run and no result is sent; it needs no administrator.


## This machine


### `dokkit version`

Prints the version of this build. Prints the version this build was made as, such as v1.2.3. A build made by hand says v0.0.0-dev.


## or the address and machine key that dokkit enrol saved.


## Trying it with no server

```
$ dokkit check
dokkit.toml: upload-portal, 2 check(s)
  ok   http           http://localhost:8080/healthz
       would send {"at":"2026-10-06T22:08:58.1420895Z","check":"http","service":"upload-portal","state":"ok","type":"state","value":10}
  ok   tcp            port 5432
       would send {"at":"2026-10-06T22:08:58.1432929Z","check":"tcp","service":"upload-portal","state":"ok","type":"state","value":1}
```
