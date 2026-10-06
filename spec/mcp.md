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
| `alert_settings` | `read` | Shows the alert settings. Addresses, user names and secrets are only `set` or `not set`. |
| `alert_suggestions` | `read` | Lists issues that keep opening, which the daily digest could take instead. |
| `logs` | `read-logs` | Searches log lines. |
| `archives` | `read-logs` | Lists the archived months of logs that can be loaded back. |
| `snooze` | `act` | Snoozes an issue until a time. |
| `unsnooze` | `act` | Wakes a snoozed issue. |
| `acknowledge` | `act` | Marks an issue as seen. |
| `note` | `act` | Adds a note to an issue. |
| `bulk` | `act` | Snoozes, unsnoozes or acknowledges many issues. |
| `watch` | `act` | Starts watching a service. |
| `unwatch` | `act` | Stops watching a service. |
| `routing` | `act` | Sets where a service's issues go. A field that is not given stays as it was. |
| `hold` | `act` | Holds a service at a version. |
| `accept_proposal` | `act` | Accepts a found service or port. A task is accepted with `accept_task`. |
| `dismiss_proposal` | `act` | Dismisses a proposal. |
| `run_task` | `act` | Runs an accepted task. |
| `keep_messages` | `act` | Keeps or stops keeping the text of a service's errors. |
| `set_job_timing` | `act` | Sets when a job counts as late and as run too long. A field left out stays as it was; an empty one clears it. |
| `add_rule` | `admin` | Adds an alert rule. |
| `update_rule` | `admin` | Changes an alert rule. A field left out stays as it was; an empty one clears it. |
| `delete_rule` | `admin` | Deletes an alert rule. |
| `set_checks` | `admin` | Replaces the checks added in the interface. |
| `allow_restart` | `admin` | Allows or forbids restarting a service. |
| `keys` | `admin` | Lists keys and tokens, never their text. |
| `make_key` | `admin` | Makes a key. Its text is returned once. |
| `revoke_key` | `admin` | Revokes a key. |
| `people` | `admin` | Lists the people who can sign in. |
| `add_person` | `admin` | Adds a person. |
| `remove_person` | `admin` | Removes a person. |
| `accept_task` | `admin` | Accepts a waiting task, so its machine may run the command. Takes the command and pin that `proposals` shows. |
| `dismiss_task` | `admin` | Dismisses a waiting task. |
| `update_program` | `admin` | Asks an enrolled machine to fetch the newer `dokkit` program. |
| `add_job` | `admin` | Adds a job to watch. Its key and addresses are returned once. |
| `set_alert_settings` | `admin` | Changes alert settings. A setting left out stays as it was; an empty secret clears it. If the address a secret goes to changes (`ntfy_url`, `smtp_host`), send the secret again in the same call or it is cleared, and the answer says so. |
| `test_alert` | `admin` | Sends a test alert by one channel. Answers sent, or one fixed reason. Four at once for each token, then one every 25 seconds. |
| `accept_suggestion` | `admin` | Sends a service's issues to the daily digest from now on. |
| `dismiss_suggestion` | `admin` | Dismisses an alert suggestion. |
| `restore_archive` | `admin` | Loads an archived month of logs back for a week. |

## Rules

- **Log contents have their own scope.** A token can be given everything except what is written in the logs.
- **A new token has no `act` scope** unless it is asked for.
- **Read tools are marked read-only**, so a client can run them without asking each time. `admin` tools are marked destructive.
- **What comes back is data.** Names, titles, notes, error text, deploy fields and output were written by machines and apps. Every answer starts with a line that says so.
- **Arguments are checked against the types the tool declares.** A wrong type is an `isError` answer, not a failure. A `null` argument is the same as one left out, and a whole number written as `5.0` is an integer. To clear a route, send an empty text.
- **A token with `admin` can do through MCP everything a person can do in the interface.** Making such a token asks for confirmation in Settings.

## Built so far

`POST /mcp` with a user token: every tool in the table, 57 in all (21 `read`, 2 `read-logs`, 14 `act`, 20 `admin`), one for each call of the API a token can make. Making a full-control token and the browser's own sign-in have no tool: they are Settings and the browser only. A tool the token may not use is not listed.
