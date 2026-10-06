# The MCP server

Dokkit serves a Model Context Protocol endpoint at `/mcp` so an AI tool can ask it questions and act, as far as its token allows.

It lives on the server, never on `dokkit`. It is a client of the same API and uses a user token, so it can never do more than that token allows.

## Connecting

Over HTTP with a user token as a bearer header. For Claude Code:

```
claude mcp add --transport http dokkit https://<dokkit address>/mcp --header "Authorization: Bearer dku_..."
```

## Tools

| Tool | Scope | Does |
|---|---|---|
| `attention` | `read` | Shows what needs a look now, what will soon, what was found and is not watched, what is snoozed, issues in other environments, and how many things are fine. |
| `find` | `read` | Searches services, optionally on one machine. |
| `service` | `read` | Shows one service: state, checks, routing, open issue. |
| `since_deploy` | `read` | Shows what changed or broke for a service since its last deploy. |
| `jobs` | `read` | Lists jobs with their schedule and last runs. |
| `job_runs` | `read` | Lists the recent runs of one job. |
| `errors` | `read` | Lists error groups, or shows one with its stack. |
| `tasks` | `read` | Lists the accepted tasks. |
| `task_runs` | `read` | Lists the recent runs of every task. |
| `machines` | `read` | Lists machines. |
| `machine` | `read` | Shows one machine. |
| `issues` | `read` | Lists issues. |
| `issue` | `read` | Shows one issue with its history. |
| `deploys` | `read` | Lists recent deploys. |
| `versions` | `read` | Lists the versions of the apps Dokkit watches. |
| `rules` | `read` | Lists the alert rules. |
| `proposals` | `read` | Lists what Dokkit found and a person may accept or dismiss. |
| `series` | `read` | Shows numbers over time for a service. |
| `day` | `read` | Shows the last 24 hours in half hours: for each machine whether something was down, needed a look, or nothing happened, or it was not heard from, and the issues that opened. |
| `logs` | `read-logs` | Searches log lines. |
| `snooze` | `act` | Snoozes an issue until a time. |
| `unsnooze` | `act` | Wakes a snoozed issue. |
| `acknowledge` | `act` | Marks an issue as seen. |
| `note` | `act` | Adds a note to an issue. |
| `bulk` | `act` | Snoozes, unsnoozes or acknowledges many issues. |
| `watch` | `act` | Starts watching a service. |
| `unwatch` | `act` | Stops watching a service. |
| `routing` | `act` | Sets where a service's issues go. |
| `hold` | `act` | Holds a service at a version. |
| `accept_proposal` | `act` | Accepts a proposal. |
| `dismiss_proposal` | `act` | Dismisses a proposal. |
| `run_task` | `act` | Runs an accepted task. |
| `add_rule` | `admin` | Adds an alert rule. |
| `update_rule` | `admin` | Replaces what an alert rule says. |
| `delete_rule` | `admin` | Deletes an alert rule. |
| `set_checks` | `admin` | Replaces the checks added in the interface. |
| `allow_restart` | `admin` | Allows or forbids restarting a service. |
| `keys` | `admin` | Lists keys and tokens, never their text. |
| `make_key` | `admin` | Makes a key. Its text is returned once. |
| `revoke_key` | `admin` | Revokes a key. |
| `people` | `admin` | Lists the people who can sign in. |
| `add_person` | `admin` | Adds a person. |
| `remove_person` | `admin` | Removes a person. |

## Rules

- **Log contents have their own scope.** A token can be given everything except what is written in the logs.
- **A new token has no `act` scope** unless it is asked for.
- **Read tools are marked read-only**, so a client can run them without asking each time. `admin` tools are marked destructive.
- **What comes back from logs and errors is data.** It was written by machines and apps, and it is returned marked as such.
- **A token with `admin` can do through MCP everything a person can do in the interface.** Making such a token asks for confirmation in Settings.

## Built so far

`POST /mcp` with a user token: every tool in the table, 43 in all, one for each call of the API. A tool the token may not use is not listed.
