# Dokkit

One place that watches everything I run and tells me what needs my attention.

This is a personal project. It is private while it is in development and will be open source once the install-specific material listed at the bottom is out of it and there is a proper demo.

The server and the `dokkit` program are being built, against the contract in `spec/`. What works and what does not is under "Where it stands". The repo also holds the decisions and a clickable mock of the interface.

## Where it stands

Working, with tests:

- **Jobs.** A job is added in the interface and reports with a plain web request or with `dokkit run`. A failed run opens an issue at once; a missed or overlong one within a minute.
- **Checks.** A `dokkit.toml` declares a service and its checks. `dokkit watch` runs http, tcp, process and Windows-service checks, and three failures in a row open an issue.
- **Beats.** An app sends a `beat` line from its main loop. When two are missed and a minute more passes, an issue opens: the app is up and stuck.
- **Deploys.** A service's version changing is a deploy. `dokkit watch` reads the version from the file `version_from` names, or CI says it with one request. The Deploys page lists them.
- **Errors.** An app posts an error with its type and stack. Reports are grouped by type and the app's own frames, and message text is not kept. The Errors page lists the groups.
- **Machines.** A machine enrols with a one-use token and says it is alive once a minute. Three minutes of silence opens one issue and quiets what runs on it.
- **Alerts.** A page through PagerDuty, a quiet push through ntfy, Pushover or PagerDuty, or a webhook. Once per issue, resolved when it closes.
- **Logs.** Lines in Dokkit's format or CLEF, kept in monthly partitions, searched on the Logs page. `dokkit watch` reads the log files a `dokkit.toml` names.
- **Found.** `dokkit scan` writes what is on a machine to a file and `dokkit propose` sends it. Running Windows services and listening ports wait on the Found page, and watching one adds a check that `dokkit watch` runs on that machine.
- **Tasks.** A `dokkit.toml` offers a named command. The owner accepts it on the Found page, it is run from the Tasks page, and `dokkit watch` on its machine carries it out and sends back the output. A command that changes has to be accepted again.
- **The interface.** Inbox with snooze, Everything, Jobs, service pages, Logs, Errors, Deploys, Found, Tasks, Alerts and Settings. People sign in; the first one claims the server with a setup code.
- **The API and the MCP**, for user tokens made in Settings.

Not built yet: reports from Sentry's SDKs, the Versions page, stats, metrics, email, text and the digest, alert rules and suggestions, the libraries, the installer and the Docker image.

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
| **The `dokkit` program** | Runs on each machine. Watches what is on it, reports to the server, and can run named tasks. It is also the command-line tool. | Go, one file |
| **Libraries** | For things only an app knows about itself: that it is alive inside, job progress, its own checks, errors. | Python and C# first |
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

- I route each alert: page, push, email, text, digest or webhook, and who gets it.
- Paging goes through PagerDuty, because it breaks Do Not Disturb.
- A quiet push can go through PagerDuty at low urgency, ntfy or Pushover.
- Anything that does not page defaults to a quiet push or a morning digest. The digest time is a setting, and an empty morning sends nothing.
- Three failed checks open an issue. An issue pages once. A machine that is down is one page, not one per service on it.
- Dokkit suggests changes to rules and never makes them itself.
- Safe services can be restarted automatically. That is allow-listed per service.
- The detail is in `spec/alerts.md`.

### The server

- One Phoenix application on one Postgres database. Not SQLite.
- Ships as a native Windows service and as a Docker image, both out of the box, so it can move to Linux or a cloud host later.
- The Windows installer offers to set up its own Postgres or to use one that is already there.
- It calls an outside address every minute, so something outside can page when it goes quiet.
- Running it is covered in `docs/running.md`.
- Logs are kept live for 12 months. Each older month is archived as one compressed file and can be loaded back.
- Its own usernames and passwords. Reachable on the local network and over a private overlay network, never exposed publicly.
- Light and dark themes, both supported.

### The `dokkit` program, on each machine

- **No open network port on a privileged process.** It only makes outbound requests and receives work over one it holds open. Everything it has to send goes to a folder on disk first, so nothing is lost when the server is unreachable. It listens on nothing, not even localhost.
- **The server can only ask for a named task defined on that machine.** Never an arbitrary command. A security scan or a report is a named task.
- **Scanning is an option, never a requirement.** Three levels, each a choice:

  | Level | Needs | What it does |
  |---|---|---|
  | Declared | No administrator, no scan | Checks only what is listed in a file or in the interface. |
  | User-space | No administrator | Runs under a login. Sees ports, processes, disks and readable logs. Stops at logoff and cannot restart services. |
  | Installed service | Administrator, once | Survives logoff, restarts allow-listed services, and scans when asked. |

- A scan is a command. It writes a proposal, and nothing is watched until the proposal is accepted.
- Every part of a scan can be switched off, and a scan never reads file contents, credentials, browser data or another program's memory.
- It never updates itself. The interface says when a newer one is out and the update is started from there.
- Releases are signed. It must never require antivirus to be turned off.

### The API

The server, the `dokkit` program, the libraries and the MCP meet at one HTTP API. The interface is a thin layer over the same server code, so nothing can be seen or done in it that the API cannot do. The full contract is in `spec/`.

- **Intake**: a machine enrols, state and logs and job runs come in as batches, a `dokkit.toml` is declared, a scan is proposed, deploys are marked, errors arrive, and `dokkit` asks for work.
- **Read**: everything the interface shows.
- **Act**: snooze, acknowledge, watch, route, accept, run a task.

Four kinds of key: one to enrol a machine, one per machine, one per app that can only write, and one per person with scopes.

### How an app joins

- It declares itself in a `dokkit.toml` in its own repo: what it is, how to check it, its jobs, its log files. No code change.
- It adds the library only for what it alone knows.
- A task in that file is only a proposal until it is accepted in the interface, and the server can ask for a task by name and nothing else.
- Steps are in `docs/integrating.md`.

### Errors

- Dokkit's own library and its own error format are the front door.
- Dokkit also accepts reports from Sentry's open-source SDKs, so a language without a Dokkit library can still report. How the project behaves about that is in `docs/sentry-compatibility.md`.

### The look

- Sentry's grammar: a dark icon sidebar, a page header with filters and tabs, issue rows that each carry a small chart, and detail pages with a large chart and a facts rail.
- Slate dark base with a teal accent, and a light theme alongside.
- The logo is a D with a dot at its top left.
- What did not work, in order: flat hairline dashboards, soft settings-style panels with too little on them, and anything that needed a click to learn a service's state.

## What is in this repo

| Path | What it is |
|---|---|
| `gallery/app/` | The current mock, filled with an invented company's data. Open `index.html` through a web server. Settings switches theme, dark base and accent. `node check.js` renders every route. |
| `spec/` | The contract: the API, `dokkit.toml`, alerts, log lines, errors, the `dokkit` program, the library, the MCP, and the stats document two applications already implement. |
| `docs/` | Wiring an app in, running the server, moving over from other tools, and the note on Sentry's SDKs. |
| `server/` | The server: Phoenix on Postgres. Its stylesheet and fonts, in `server/priv/static/`, are the ones the mock loads. |
| `program/` | The `dokkit` program, in Go. |

To look at the mock:

```
python -m http.server 7912 --directory gallery
```

Then open `http://localhost:7912/app/`.

## Before this goes public

The mock and the product run on invented data. What is left to do first:

- The earlier galleries and the requirements interview were filled with one real install's inventory. They are gone from the tree and still in the history, which has to be rewritten or left behind.
- `spec/stats-v1.md`: written for two specific applications.
- The interface was built with another product's layout as the reference. It mostly stays as it is; the parts that are recognisably theirs get changed, and the description under "The look" is reworded to match.
- `docs/sentry-compatibility.md` is followed everywhere the project describes itself.

## Licence

When this is public: the server is AGPL 3.0, and the `dokkit` program and the libraries are Apache 2.0.

## The name

Dokkit is one name for the whole thing: the product, the server, and the program on each machine. It is "docket" respelled: a docket is the list of what is waiting to be dealt with.
