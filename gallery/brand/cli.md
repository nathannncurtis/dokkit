# The `dokkit` command line

One program on each watched machine, also used in an app's repo. `dokkit help` prints this list and `dokkit help <command>` says more about one.


## In an app's repo


### `dokkit init`

Asks what the app is and writes dokkit.toml. Asks a few questions and writes a dokkit.toml in this folder: what the app is, and how to tell it is healthy. Nothing is sent.


### `dokkit check [dokkit.toml]`

Runs every check once and prints what would be sent. Validates the file, runs each of its checks once on this machine and prints exactly what would be sent. Needs no server and sends nothing.


### `dokkit apply [dokkit.toml]`

Sends the file to the server. Declares the file to the server, for use from CI or anywhere dokkit watch does not read the folder. Sending the same file twice changes nothing.


## Jobs


### `dokkit run [--service <slug>] --job <name> -- <command> [arguments]`

Runs a command and reports how it went. Runs the command and reports its start, finish, exit code, duration and last lines of output. Exits with the command's own exit code. A job declared in a dokkit.toml is found by name; --service says which service when it is not.


### `dokkit ping [--service <slug>] <name> [start|ok|fail]`

Reports a job that cannot be wrapped. Reports one event for a job: start, ok (the default) or fail.


## This machine


### `dokkit enrol <address> <token> [sha256:<certificate fingerprint>]`

Joins this machine to a server. Trades a one-time token for this machine's key and saves it. Given a fingerprint, it trusts the certificate with that fingerprint and no other.


### `dokkit status`

What this machine watches and when it last reported. Shows the files dokkit watch reads, when it last sent, and how many reports are waiting. It says a watch is running only while that watch has written down in the last three minutes, and then gives its process number.


### `dokkit doctor`

A rough check of the server and the clock. Says whether the server answers and knows this key, whether this machine's clock is within 30 seconds of the server's, and whether reports are waiting. A certificate that is not the one saved at enrol shows as the server not answering.


## Finding things


### `dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]`

Looks over this machine and writes a proposal file. Lists what is on the machine that could be watched and writes it to dokkit-proposal.json in this folder. Sends nothing. Each --no- flag leaves one kind of thing out.


### `dokkit propose`

Sends the proposal file to be accepted. Sends dokkit-proposal.json, which a scan wrote. Nothing in it is watched until a person accepts it in the interface.


## Staying running


### `dokkit watch [--background]`

Watches this machine, as an ordinary program. Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved configuration, and from the folders directly inside them. Runs their checks, sends the log files they name, runs the tasks a person accepted, and says the machine is alive once a minute. No administrator, no service. --background leaves it running after this window closes.


### `dokkit startup on|off`

Starts dokkit watch each time you sign in. Windows only. Works on Windows only so far. Adds dokkit watch --background to your own startup programs, or takes it out. No administrator. Elsewhere, use dokkit service, or add dokkit watch --background to your desktop's startup programs.


### `dokkit service install|uninstall|update|start|stop`

Runs it as a service, on Windows or Linux. Needs an administrator or root. Works on Windows and on Linux with systemd; not on macOS yet. Installs dokkit as a service that starts with the machine, so it keeps watching with nobody signed in. On Windows it runs as the system account. On Linux it runs as a user named dokkit, which is made if useradd is there. It may restart only the services or units that this machine's own configuration names. On Linux that needs dokkit to run as root or systemd to allow it. Needs an administrator prompt on Windows and root on Linux.


## Tasks


### `dokkit task list`

The tasks on this machine and whether each is accepted. Lists the tasks in this folder and in the folders this machine reads. When the server answers, says of each whether it is accepted, not accepted yet, or changed since it was accepted. Says which account you are running as.


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
