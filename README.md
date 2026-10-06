# Docket

One place that watches everything I run and tells me what needs my attention.

This is a personal project. It is private while it is in development and will be open source once the install-specific material listed at the bottom is out of it and there is a proper demo.

Nothing here is the product yet. This repo holds the design work so far: the decisions, the contract every piece will be built against, a clickable mock of the interface, and the explorations that led to it.

## The pieces

| Piece | What it is | Built with |
|---|---|---|
| **Docket** | The server and the web interface. | Phoenix on Postgres |
| **Davit** | Runs on each machine. Watches what is on it, reports to Docket, and can run named tasks. | Go, one file |
| **CLI** | Part of Davit. Wraps a command and reports how it went. | Go |
| **Libraries** | For things only an app knows about itself: that it is alive inside, job progress, its own checks, errors. | Python and C# first |
| **MCP** | Lets an AI tool ask Docket questions and take a few everyday actions. | Served by Docket |

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

- **No open network port on a privileged process.** It only makes outbound requests and receives work over one it holds open. Everything it has to send goes to a folder on disk first, so nothing is lost when Docket is unreachable. It listens on nothing, not even localhost.
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

Docket, Davit, the CLI, the libraries and the MCP meet at one HTTP API. The interface is a thin layer over the same server code, so nothing can be seen or done in it that the API cannot do. The full contract is in `spec/`.

- **Intake**: a machine enrols, state and logs and job runs come in as batches, a `docket.toml` is declared, a scan is proposed, deploys are marked, errors arrive, and Davit asks for work.
- **Read**: everything the interface shows.
- **Act**: snooze, acknowledge, watch, route, accept, run a task.

Four kinds of key: one to enrol a machine, one per machine, one per app that can only write, and one per person with scopes.

### How an app joins

- It declares itself in a `docket.toml` in its own repo: what it is, how to check it, its jobs, its log files. No code change.
- It adds the library only for what it alone knows.
- A task in that file is only a proposal until it is accepted in the interface, and the server can ask for a task by name and nothing else.
- Steps are in `docs/integrating.md`.

### Errors

- Docket's own library and its own error format are the front door.
- Docket also accepts reports from Sentry's open-source SDKs, so a language without a Docket library can still report. How the project behaves about that is in `docs/sentry-compatibility.md`.

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
| `spec/` | The contract: the API, `docket.toml`, log lines, errors, Davit and the CLI, the library, the MCP, and the stats document two applications already implement. |
| `docs/` | Wiring an app in, and the note on Sentry's SDKs. |
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
- `spec/stats-v1.md`: written for two specific applications.
- The interface needs its own identity. The mock was built with another product's layout as the reference; one pass to change whatever is recognisably theirs, and the description under "The look" reworded to match.
- `docs/sentry-compatibility.md` is followed everywhere the project describes itself.
