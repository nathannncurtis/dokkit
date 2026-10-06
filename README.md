# Docket

One place that watches everything I run and tells me what needs my attention.

This is a personal project. It is private while it is in development and will be open source once the install-specific material listed at the bottom is out of it and there is a proper demo.

Nothing here is the product yet. This repo holds the design work so far: the decisions, a clickable mock of the interface, and the explorations that led to it.

## The pieces

| Piece | What it is | Built with |
|---|---|---|
| **Docket** | The server and the web interface. | Phoenix on Postgres |
| **Davit** | Runs on each machine. Watches what is on it, reports to Docket, and can run named tasks. | Go, one file |
| **CLI** | Part of Davit. Wraps a command and reports how it went. | Go |
| **Libraries** | For things only an app knows about itself. | Sentry's own client libraries for errors |

## Decisions

### What it is for

- The first screen is what needs my attention, which is wider than what is broken.
- Desktop first. A phone is for after a page.
- Everything is a row: every service, every machine, every outside dependency, every scheduled job.
- It finds new things by itself and shows them as "found, not watched" until I decide.
- It shows what matters now and folds the rest away, but the overview must say enough that nothing needs opening to know how it is doing.
- Out of scope: security signals and business statistics.

### Alerts

- I route each alert: page, email, or text, and who gets it.
- Paging goes through PagerDuty, because it breaks Do Not Disturb.
- Anything that does not page defaults to a quiet push or a morning digest.
- Safe services can be restarted automatically. That is allow-listed per service.

### Docket, the server

- One Phoenix application on one Postgres database. Not SQLite.
- Ships as a native Windows service and as a Docker image, both out of the box, so it can move to Linux or a cloud host later.
- Logs are kept live for 12 months. Each older month is archived as one compressed file and can be loaded back.
- Its own usernames and passwords. Reachable on the local network and over a private overlay network, never exposed publicly.
- Light and dark themes, both supported.

### Davit, on each machine

- **No open network port on a privileged process.** It keeps one outbound connection to Docket and receives work over it. It listens on localhost so apps and the CLI on that machine can hand it data, and it buffers when Docket is unreachable. A network listener is an option, off by default.
- **Docket can only ask for a named task defined on that machine.** Never an arbitrary command. A security scan or a report is a named task.
- **Scanning is an option, never a requirement.** Three levels, each a choice:

  | Level | Needs | What it does |
  |---|---|---|
  | Declared | No administrator, no scan | Checks only what is listed in a file or in the interface. |
  | User-space | No administrator | Runs under a login. Sees ports, processes, disks and readable logs. Stops at logoff and cannot restart services. |
  | Installed service | Administrator, once | Survives logoff, restarts allow-listed services, and scans when asked. |

- A scan is a command. It writes a proposal, and nothing is watched until the proposal is accepted.
- It must never require antivirus to be turned off.

### The API

Docket, Davit, the CLI and any library meet at one HTTP API. It has five jobs, and designing it is the next step:

1. **Enrol**: a machine introduces itself and gets a key.
2. **Propose**: a scan sends what it found, to be accepted.
3. **Report**: state, heartbeats, job runs, metrics and log lines come in.
4. **Take work**: Davit holds a connection open and receives named tasks.
5. **Errors**: an intake that accepts what Sentry's client libraries send.

### The look

- Sentry's grammar: a dark icon sidebar, a page header with filters and tabs, issue rows that each carry a small chart, and detail pages with a large chart and a facts rail.
- Slate dark base with a teal accent, and a light theme alongside.
- The logo is a D with a dot at its top left.
- What did not work, in order: flat hairline dashboards, soft settings-style panels with too little on them, and anything that needed a click to learn a service's state.

## What is in this repo

| Path | What it is |
|---|---|
| `gallery/app/` | The current mock. Open `index.html` through a web server. Settings switches theme, dark base and accent. `node check.js` renders every route. |
| `gallery/app/logos/` | The generated logo images. The mock uses a vector traced from `d2.png`. |
| `gallery/demo/` | An earlier clickable demo, and `data.js`, the inventory the mocks are filled from. |
| `gallery/`, `gallery/v2/` to `gallery/v5/` | Earlier explorations, kept for reference. |
| `STATS-SPEC.md` | The stats document and error-reporting contract two applications already implement. Docket will read it. |
| `questions.json`, `answers.jsonl`, `index.html`, `server.py` | The requirements interview, and the small board it was answered on. |

To look at the mock:

```
python -m http.server 7912 --directory gallery
```

Then open `http://localhost:7912/app/`.

## Before this goes public

The mocks are filled with one real install's inventory. All of it has to be replaced with invented demo data first:

- `gallery/demo/data.js`: real machine names, services, versions and ports.
- Every page under `gallery/` that names those machines and services.
- `answers.jsonl` and `questions.json`: the interview refers to the same install.
- `STATS-SPEC.md`: written for two specific applications.
