# The `dokkit` command line

One program on each watched machine, also used in an app's repo. `dokkit help` prints this list and `dokkit help <command>` says more about one.


## In an app's repo


### `dokkit init`

Asks what the app is and writes dokkit.toml. Asks a few questions and writes a dokkit.toml in this folder: what the app is, and how to tell it is healthy. Nothing is sent.


### `dokkit check [dokkit.toml]`

Runs the checks it can once and prints what would be sent. Checks the file's schema, service id and each check's fields. Runs the http, tcp, process, windows-service, systemd and expiry checks that can run here, once, and prints exactly what would be sent. Checks the app reports itself are listed as not run. A check aimed at another host does make its request. Needs no server and sends nothing to it. A slow answer shows as slow, not as a failure.


### `dokkit apply [dokkit.toml]`

Sends the file to the server. Declares the file to the server, for a file dokkit watch does not read. It needs this machine's key from dokkit enrol; the server refuses an app key. Sending the same file twice changes nothing.


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


### `dokkit doctor`

A rough check of the server and the clock. Says whether the server answers and knows this key, whether this machine's clock is within 30 seconds of the server's (a slow answer counts as clock difference, up to 10 seconds), and whether reports are waiting. A certificate that is not the one saved at enrol shows as the server not answering.


## Finding things


### `dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]`

Looks over this machine and writes a proposal file. Lists what is on the machine that could be watched and writes it to dokkit-proposal.json in this folder. Sends nothing. Each --no- flag leaves one kind of thing out.


### `dokkit propose`

Sends the proposal file to be accepted. Sends dokkit-proposal.json, which a scan wrote. Nothing in it is watched until a person accepts it in the interface, or a token allowed to act accepts it through the API.


## Staying running


### `dokkit watch [--background]`

Watches this machine, as an ordinary program. Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved configuration, and from the folders directly inside them. Runs their checks, sends the log files they name, runs the tasks a person accepted, and says the machine is alive once a minute. No administrator, no service. --background leaves it running after this window closes. Run like this, it never restarts a service or unit; only the installed service does.


### `dokkit folder add|remove <path>`

Sets which folders dokkit watch reads dokkit.toml files from. Adds a folder to the list dokkit watch reads dokkit.toml files from, or takes one out. It reads the dokkit.toml in the folder and in the folders directly inside it. The path is made absolute, and for add the folder must exist. Adding one twice changes nothing. A running watch picks up the change within a minute, with no restart. When the service is installed this changes the service's list, which needs an administrator, or root on Linux, and it prints the exact line to run. Otherwise it changes your own list. On Linux, it warns when the dokkit user cannot read the folder.


### `dokkit folder list`

Shows those folders. Lists the folders dokkit watch reads dokkit.toml files from: the installed service's when there is one, otherwise your own, and any it cannot read.


### `dokkit imessage on|off|status`

Lets this Mac send iMessages when the server asks. Alerts by iMessage go out through a Mac that is signed in to Messages. Nothing is sent unless this Mac was told it may: on records that it may, off takes it back, and status says which. Off is the default, and on works on a Mac only. A running dokkit watch picks the change up with no restart. When the service is installed this changes the service's configuration, which needs an administrator, or root, and it prints the exact line to run.


### `dokkit imessage test <recipient> [words...]`

Sends one iMessage from this Mac now, to prove Messages works. Sends the words, or a short test message, to a phone number or an email address through Messages on this Mac, without the server, and prints sent to <recipient> or the reason it was not. It works whether or not on was run. The first send makes macOS ask once, on this Mac's screen, whether dokkit may control Messages; allow it, or switch it on under System Settings, Privacy & Security, Automation. macOS remembers the answer only for a signed build of dokkit. A message is cut at 1000 characters.


### `dokkit startup on|off`

Starts dokkit watch each time you sign in. Windows only. Works on Windows only so far. Adds dokkit watch --background to your own startup programs, or takes it out. No administrator. On Linux, use dokkit service, or add dokkit watch --background to your desktop's startup programs. On macOS, add it to a launchd job.


### `dokkit service install|uninstall|update|start|stop`

Runs it as a service, on Windows or Linux. Needs an administrator or root. Works on Windows and on Linux with systemd; not on macOS yet. Installs dokkit as a service that starts with the machine, so it keeps watching with nobody signed in. On Windows it runs as Local Service, an account with no rights of its own, and reads only what that account can read, which leaves out other people's profile folders. On Linux it runs as a user named dokkit, which is made if useradd is there, and it reads only the folders that user can read. It may restart only the services or units that this machine's own configuration names, and only where the machine lets its account: on Windows the service's own permissions, on Linux root or systemd. On Windows it keeps to Program Files\DokkitProgram and ProgramData\DokkitProgram, and install refuses a data folder that holds anything but config.json, spool, dokkit.log and update. A program installed in the older Program Files\Dokkit and ProgramData\dokkit is moved by install or update: its config.json, spool and dokkit.log are copied, the service is pointed at the new copy, and the old files are left where they are. Needs an administrator prompt on Windows and root on Linux. On Linux, run through sudo, it uses the enrolment of the account that ran sudo, and root's own when that account has none, and says which file it used. update puts this copy in place of the installed one and restarts the service. uninstall leaves the machine enrolled on the server.


### `dokkit updater install|uninstall|run|status`

Updates the program, and the server on the machine that runs it, when asked. Windows only so far. Windows only so far. install, from an administrator prompt, once: copies this program to Program Files\DokkitUpdater, makes ProgramData\DokkitUpdater for administrators and the system account only, registers the scheduled task Dokkit updater (system account, every five minutes and at start-up), and runs one check. It needs the program's service installed first. run is what the task runs: it asks the server whether this machine has been told to move to a version, and only installs a release whose list is signed with the project's release key and whose files match it. It never installs an older version. status prints the installed versions, the last check and the last result. uninstall removes the task and the copied file.


## This machine


### `dokkit version`

Prints the version of this build. Prints the version this build was made as, such as v1.2.3. A build made by hand says v0.0.0-dev.


## Tasks


### `dokkit task list`

The tasks on this machine and whether each is accepted. Lists the tasks in this folder and in the folders this machine reads. When the server answers, says of each whether it is accepted, not accepted yet, or changed since it was accepted. When it lists any tasks, says which account you are running as.


### `dokkit task run <name>`

Runs a task here to try it. Runs the task on this machine now. The server can only ask for a task a person accepted, pinned to the exact command accepted.


## Trying it with no server

```
$ dokkit check
dokkit.toml: upload-portal, 2 check(s)
  ok   http           http://localhost:8080/healthz
       would send {"at":"2026-10-06T22:08:58.1420895Z","check":"http","service":"upload-portal","state":"ok","type":"state","value":10}
  ok   tcp            port 5432
       would send {"at":"2026-10-06T22:08:58.1432929Z","check":"tcp","service":"upload-portal","state":"ok","type":"state","value":1}
```
