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

What this machine watches and when it last reported. Shows the files dokkit watch reads, when the spool was last emptied, how much is waiting, and the process number of a watch left running.


### `dokkit doctor`

Checks the server can be reached and the clock is right. Says whether the server answers, whether its certificate matches the one saved at enrol, and whether this machine's clock agrees with the server's.


## Finding things


### `dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]`

Looks over this machine and writes a proposal file. Lists what is on the machine that could be watched and writes it to a proposal file. Sends nothing. Each --no- flag leaves one kind of thing out.


### `dokkit propose`

Sends the proposal file to be accepted. Sends what a scan wrote. Nothing in it is watched until a person accepts it in the interface.


## Staying running


### `dokkit watch [--background]`

Watches this machine, as an ordinary program. Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved configuration, and from the folders directly inside them. Runs their checks, sends the log files they name, and says the machine is alive once a minute. No administrator, no service. --background leaves it running with no window.


### `dokkit startup on|off`

Starts dokkit watch each time you sign in. On Windows, adds dokkit watch --background to your own startup programs, or takes it out. No administrator.


### `dokkit service install|uninstall|update|start|stop`

Runs it as a service. Needs an administrator once. Installs dokkit as a service that starts with the machine, so it keeps watching with nobody signed in and may restart the services its configuration names.


## Tasks


### `dokkit task list`

The tasks on this machine and whether each is accepted. Says of each task whether it is accepted, not accepted yet, or changed since it was accepted, and which account tasks run as.


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
