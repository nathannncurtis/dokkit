# Dokkit

One place that watches everything I run and tells me what needs my attention.

This is a personal project. It is private while it is in development and will be open source once there is a proper demo.

The server and the `dokkit` program are being built. What works and what does not is under "Where it stands". The repo also holds the decisions and a clickable mock of the interface.

## Where it stands

Working, with tests:

- **Jobs.** A job is added in the interface and reports with a plain web request or with `dokkit run`. A failed run opens an issue at once; a missed or overlong one within a minute.
- **Checks.** A `dokkit.toml` declares a service and its checks. `dokkit watch` runs http, tcp, process, Windows-service and systemd checks, and three failures in a row open an issue. An http check can name the status that counts as healthy, and a process check can match part of the command line and say how many there should be at least.
- **Beats.** An app sends a `beat` line from its main loop. When two are missed and a minute more passes, an issue opens: the app is up and stuck.
- **Deploys.** A service's version changing is a deploy. `dokkit watch` reads the version from the file `version_from` names, or CI says it with one request. The Deploys page lists them, and the Versions page shows which version is on which machine.
- **Errors.** An app posts an error with its type and stack. Reports are grouped by type and the app's own frames, and message text is not kept. The Errors page lists the groups. Dokkit also accepts reports from Sentry's open-source SDKs.
- **Numbers.** `dokkit watch` sends each machine's processor, memory and disk use, fetches a service's stats document, and apps can send their own metrics. A threshold check opens an issue when a number is over its limit, and an expiry check warns 30 days before a certificate or a dated file runs out. Service pages chart the last 24 hours, and a machine's page charts its own disk, memory and processor over time with the limit drawn. A disk that is filling is forecast from a week of readings. A QNAP's own firmware partitions are not counted as disks.
- **Machines.** A machine enrols with a one-use token and says it is alive once a minute. The Add a machine page asks how the machine will run, shows the commands for that with a copy button, counts the token down, lists tokens not yet used and names the machine a token became. Three minutes of silence opens one issue and quiets what runs on it. A machine, a person or a script (`dokkit quiet 20m`) can say it is going down on purpose, and nothing opens until the time is up or the machine is back; downtime can also be scheduled once or on a repeat. Each machine has its own page with everything known about it, including its process list: every process's name, path, number, memory and processor share, sent once a minute without opening any process or reading a command line, with the last day's top ten and a snapshot kept with memory, processor and stopped-service issues.
- **Alerts.** A page through PagerDuty, a quiet push through ntfy, Pushover or PagerDuty, an email, an iMessage through a Mac, an SMS through Twilio, a daily digest, or a webhook. Rules send one kind of issue somewhere else. One thing can go to several of them at once. Once per issue, resolved when it closes. A machine that stops reporting has its own channels. An alert for a service that should not wake anyone is held until the night ends, and the night is kept in a time zone. Dokkit's own row pages when it stops taking reports. Each person has their own destinations, and a check, a service, a rule or the default names who is told. An issue that keeps being snoozed is offered the daily digest. Each machine's disks and memory are watched against two limits without anything declared.
- **Logs.** Lines in Dokkit's format or CLEF, kept in monthly partitions, searched on the Logs page. `dokkit watch` reads the log files a `dokkit.toml` names. An app that logs to Seq moves by changing its address and key, and `dokkit import seq` copies a Seq server's stored events across with their own times.
- **Found.** `dokkit scan` writes what is on a machine to a file and `dokkit propose` sends it. Running services, listening ports, scheduled jobs, containers that publish a port and sites with an address wait on the Found page, and watching one adds a check or a job that `dokkit watch` runs or follows on that machine. A machine looks again once a day and when asked from the Found page. A listening port is checked at the address it listens on, on Windows, Linux and macOS. Each finding says if it is the operating system's, installed by other software or set up by a person; the operating system's are hidden until Show system services is on. The page is a list of machines beside the chosen machine's findings, in sections by kind.
- **The interface.** Inbox with snooze, Everything, Apps, machine pages, Jobs, service pages, Logs, Errors, Deploys, Found, Alerts and Settings. While machines update, one progress screen replaces the rest. People sign in, with two-step codes and one-time recovery codes if they turn them on; the first one claims the server with a setup code. Settings choose the theme, the dark base and the accent. A service page stops and starts watching, holds a version, keeps error messages or not, takes notes on its open issue, and lets the installed program start a stopped Windows service or systemd unit again. Versions lists desktop apps by how many PCs are on each version.
- **Updates.** The server holds signed releases. A person approves a version for one machine or for all, and the updater on each machine, installed once by an administrator, installs it. It has been run on Windows, Linux, macOS and a QNAP NAS. An update starts within seconds of the click: the server tells the machine's program, which pokes the updater without gaining any rights, and a five-minute check is the fallback.
- **Libraries.** For Python, .NET, JavaScript, Go, Elixir, Rust, Java, PHP, PowerShell, shell and Swift, one file each: beats, job progress, an app's own checks, errors, logs. Anything sent from an environment other than production lands on its own row and never alerts.
- **Phone apps.** Native apps for iOS and Android show whether anything needs attention and whether the hardware is up, and change nothing. A server reaches them through a relay, either one its owner runs, a mode of the `dokkit` program, or the shared one at relay.dokkit.dev, which Settings signs up to in one click: the server uploads a sealed snapshot each minute and nothing comes back in. Each release carries both apps unsigned, for whoever installs them to sign.
- **The API and the MCP**, for user tokens made in Settings. Every read and act call is there, and a token with the `admin` scope manages keys, people, rules, checks and restart.

In use: one server and eight machines (Windows, Linux, macOS and a QNAP NAS), one of them outside the office network and reporting over a private tunnel, with paging, push and mail all sent for real, and a phone paired through a relay.

What is left:

- Not yet run on a real machine: the Docker image and the install script for a VPS, and `dokkit service install` on a Mac (the one Mac sends iMessages and stays on its launchd agent; a daemon of the kind it installs has been shown to reach the server).
- The instant update start on Windows has not run for real yet: the first update after the machines take it in is its test.
- The Swift library's tests have never been run; they need Xcode.
- Upgrading the server on Windows gives its service a new internal name each time.
- Stored log lines cannot be moved from one service to another.
- On Found, the chosen machine can sit below the fold of the machine list.
- Decided against for now: learning what is normal for a number, and OpenTelemetry intake.

To run it for development, with Postgres on localhost:

```
cd server
mix setup
mix phx.server          # http://localhost:4000, and the setup code is in its output

cd program
go build -o dokkit.exe .
```

## The pieces

| Piece | What it is | Built with |
|---|---|---|
| **The server** | Takes everything in, stores it, alerts, and serves the web interface. | Phoenix on Postgres |
| **The `dokkit` program** | Runs on each machine. Watches what is on it, and reports to the server. It is also the command-line tool. | Go, one file |
| **Libraries** | For things only an app knows about itself: that it is alive inside, job progress, its own checks, errors. | Python, C#, JavaScript, Go, Elixir, Rust, Java, PHP, PowerShell, shell, Swift |
| **MCP** | Lets an AI tool ask Dokkit questions and take a few everyday actions. | Part of the server |

## Decisions

### What it is for

- The first screen is what needs my attention, which is wider than what is broken.
- Desktop first. A phone is for after a page.
- Everything is a row: every service, every machine, every outside dependency, every scheduled job.
- It finds new things by itself and shows them as "found, not watched" until I decide.
- It shows what matters now and folds the rest away, but the overview must say enough that nothing needs opening to know how it is doing.
- Out of scope: security signals and business statistics.

### Alerts

- I route each alert: page, push, email, iMessage, SMS, digest or webhook, and who gets it.
- Paging goes through PagerDuty, because it breaks Do Not Disturb.
- A quiet push can go through PagerDuty at low urgency, ntfy or Pushover.
- Anything that does not page defaults to a quiet push or a morning digest. The digest time is a setting, and an empty morning sends nothing.
- Three failed checks open an issue. An issue pages once. A machine that is down is one page, not one per service on it.
- Dokkit suggests changes to rules and never makes them itself.
- Safe services can be restarted automatically. That is allow-listed per service.

### The server

- One Phoenix application on one Postgres database. Not SQLite.
- Ships as a native Windows service and as a Docker image, both out of the box, so it can move to Linux or a cloud host later.
- The Windows installer offers to set up its own Postgres or to use one that is already there.
- It calls an outside address every minute, so something outside can page when it goes quiet.
- Running it is covered in `docs/running.md`.
- Logs are kept live for 12 months by default; it is a setting (1 to 120 months). Each older month is archived as one compressed file and can be loaded back, or deleted if that is chosen.
- Its own usernames and passwords. Reachable on the local network and over a private overlay network, never exposed publicly.
- Light and dark themes, both supported.

### The `dokkit` program, on each machine

- **No open network port on a privileged process.** It only makes outbound requests and receives work over one it holds open. Everything it has to send goes to a folder on disk first, so nothing is lost when the server is unreachable. It listens on nothing, not even localhost.
- **Scanning is an option, never a requirement.** Three levels, each a choice:

  | Level | Needs | What it does |
  |---|---|---|
  | Declared | No administrator, no scan | Checks only what is listed in a file or in the interface. |
  | User-space | No administrator | Runs under a login. Sees ports, processes, disks and readable logs. Stops at logoff and cannot restart services. |
  | Installed service | Administrator, once | Survives logoff, restarts allow-listed services, and scans when asked. |

- A scan is a command. It writes a proposal, and nothing is watched until the proposal is accepted.
- Every part of a scan can be switched off, and a scan never reads file contents, credentials, browser data or another program's memory.
- It never updates itself and never replaces its own file. The interface says when a machine is behind. A separate updater, which an administrator installs once on the machine, installs a signed release that a person has approved in the interface.
- Whoever builds it signs it with their own certificate; the project hands out no builds signed with anyone's. It must never require antivirus to be turned off.

### The API

The server, the `dokkit` program, the libraries and the MCP meet at one HTTP API. The interface is a thin layer over the same server code, so nothing can be seen or done in it that the API cannot do. The full contract is in `spec/`.

- **Intake**: a machine enrols, state and logs and job runs come in as batches, a `dokkit.toml` is declared, a scan is proposed, deploys are marked, errors arrive, and `dokkit` asks for work.
- **Read**: everything the interface shows.
- **Act**: snooze, acknowledge, watch, route, accept.

Four kinds of key: one to enrol a machine, one per machine, one per app that can only write, and one per person with scopes.

### How an app joins

- It declares itself in a `dokkit.toml` in its own repo: what it is, how to check it, its jobs, its log files. No code change.
- It adds the library only for what it alone knows.
- Steps are in `docs/integrating.md`.

### Errors

- Dokkit's own library and its own error format are the front door.
- Dokkit also accepts reports from Sentry's open-source SDKs, so a language without a Dokkit library can still report. How the project behaves about that is in `docs/sentry-compatibility.md`.

### The look

- Sentry's grammar: a dark icon sidebar, a page header with filters and tabs, issue rows that each carry a small chart, and detail pages with a large chart and a facts rail.
- Ember, a warm charcoal dark base with a tangerine accent, and a light theme with a teal accent alongside. Slate, Plum and Neutral remain as dark bases.
- The logo is a D with a dot at its top left.
- What did not work, in order: flat hairline dashboards, soft settings-style panels with too little on them, and anything that needed a click to learn a service's state.

## What is in this repo

| Path | What it is |
|---|---|
| `spec/` | `openapi.json`, which the site's API page is drawn from and the server's routes are tested against, and test cases shared by the server, the program and the phone apps. |
| `docs/` | The `dokkit.toml` format, the MCP, wiring an app in, running the server, moving over from other tools, and the note on Sentry's SDKs. |
| `server/` | The server: Phoenix on Postgres. Its stylesheet and fonts are in `server/priv/static/`. |
| `program/` | The `dokkit` program, in Go. |

To look at the mock:

```
python -m http.server 7912 --directory gallery
```

Then open `http://localhost:7912/app/`.

## Before this goes public

The mock and the product run on invented data. What is left to do first:

- The interface was built with another product's layout as the reference. It mostly stays as it is; the parts that are recognisably theirs get changed, and the description under "The look" is reworded to match.
- `docs/sentry-compatibility.md` is followed everywhere the project describes itself.

## Licence

The server (`server/`) is AGPL 3.0. The `dokkit` program (`program/`), the libraries (`clients/`) and the phone apps (`apps/`) are Apache 2.0. Each folder carries its own `LICENSE`.

## The name

Dokkit is one name for the whole thing: the product, the server, and the program on each machine. It is "docket" respelled: a docket is the list of what is waiting to be dealt with.
