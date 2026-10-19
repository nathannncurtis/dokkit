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
| `machines` | `read` | Lists machines. |
| `machine` | `read` | Shows one machine. |
| `issues` | `read` | Lists issues. |
| `issue` | `read` | Shows one issue with its history. |
| `deploys` | `read` | Lists recent deploys. |
| `versions` | `read` | Lists the versions of the apps Dokkit watches. |
| `rules` | `read` | Lists the alert rules. |
| `proposals` | `read` | Lists what Dokkit found and a person may accept or dismiss, each with `origin` and `why`. Leaves out the operating system's own things unless `system` is true. Always answers `{"items": [...], "next": ..., "hidden": {"total": n, "machines": {"<machine name>": n}}}`, where `hidden` counts what was left out. |
| `series` | `read` | Shows numbers over time for a service (`id`), or for a machine's own disks, memory and processor (`machine`). |
| `processes` | `read` | Shows a machine's newest process list (`machine` is its id or name): `sort`, `q`, `pid`, `limit`. |
| `process_history` | `read` | Shows the top 10 processes by memory or processor kept for a machine over up to 24 hours: `kind`, `from`, `to`. |
| `day` | `read` | Shows the last 24 hours in half hours: for each machine whether something was down, needed a look, or nothing happened, or it was not heard from, and the issues that opened. |
| `releases` | `read` | Lists the program releases the server holds and whether each is complete. |
| `certificate` | `read` | Shows the certificates the server serves itself. |
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
| `routing` | `act` | Sets where a service's issues go, one channel or a list of channels for `down` and for `degraded`. A field that is not given stays as it was. |
| `machine_routing` | `act` | Sets how a machine that stops reporting is announced: `down`, one channel or a list, and `night`. A field that is not given stays as it was. |
| `hold` | `act` | Holds a service at a version. |
| `accept_proposal` | `act` | Accepts a found service or port. A hidden one can be named by id; `all` takes only what `proposals` shows unless `system` is true. |
| `dismiss_proposal` | `act` | Dismisses a proposal, with the same rule for `all` and `system`. |
| `keep_messages` | `act` | Keeps or stops keeping the text of a service's errors. |
| `set_job_timing` | `act` | Sets when a job counts as late and as run too long. A field left out stays as it was; an empty one clears it. |
| `scan_machine` | `act` | Asks an enrolled machine to look itself over again and send what it finds to proposals. Nothing found is watched until accepted. |
| `plan_downtime` | `act` | Says an enrolled machine is going down on purpose for a length of time (`for`, such as `15m`, at most `4h`; optional `reason`): no issue opens and nothing is sent for the machine going silent or its checks failing until the time is up. A second call replaces the window; `for` of `0` ends it. |
| `end_downtime` | `act` | Ends a machine's planned downtime now. |
| `downtime_schedules` | `read` | A machine's scheduled planned downtime: each with `id`, `repeat`, `at`, `time`, `days`, `for_seconds`, `reason`, `by` and `next`. |
| `schedule_downtime` | `act` | Schedules planned downtime that the server starts by itself: `repeat` of `once` (with `at`, an RFC 3339 time), `daily` or `weekly` (with `time`, such as `02:00`, in the night time zone, and for `weekly` `days`, 1 for Monday to 7 for Sunday), `for` (such as `30m`, at most `4h`) and an optional `reason`. A window it starts is not ended early when the machine comes back. |
| `remove_scheduled_downtime` | `act` | Removes a scheduled planned downtime, by the `schedule` id from `downtime_schedules`. |
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
| `update_program` | `admin` | Asks an enrolled machine to fetch the newer `dokkit` program. |
| `update_machine` | `admin` | Asks the updater on a machine to move to a release the server holds completely. |
| `update_all` | `admin` | The same for every machine that has an updater. |
| `set_certificate` | `admin` | Puts a certificate for a real name in place. |
| `remove_certificate` | `admin` | Removes the uploaded certificate. |
| `certificate_settings` | `admin` | Shows the settings for getting and renewing the uploaded certificate. |
| `set_certificate_settings` | `admin` | Changes those settings. A setting left out stays as it was. |
| `renew_certificate` | `admin` | Gets a certificate now from the certificate authority. |
| `dokkit_name` | `admin` | Shows the name on dokkit.dev this server holds through the claim service. |
| `claim_dokkit_name` | `admin` | Claims a name on dokkit.dev with a claim code, or changes the address it points at. |
| `add_app` | `admin` | Adds an app that runs on many machines. Its key is returned once. |
| `add_dependency` | `admin` | Adds something outside that is depended on. With a check (`http` url or `tcp` address) it is put on an enrolled machine whose program runs the check; without one it belongs to the group Outside. |
| `add_job` | `admin` | Adds a job to watch. Its key and addresses are returned once. |
| `set_alert_settings` | `admin` | Changes alert settings. A setting left out stays as it was; an empty secret clears it. If the address a secret goes to changes (`ntfy_url`, `smtp_host`), send the secret again in the same call or it is cleared, and the answer says so. |
| `alert_people` | `read` | Lists the people alerts can be told with their own destinations. The ntfy address, Pushover key and routing key are only set or not set. |
| `alert_who` | `read` | Lists who is told at each level where someone is named. |
| `set_alert_person` | `admin` | Changes a person's destinations. A field not given stays; an empty one clears it. |
| `set_alert_who` | `admin` | Names who is told at one level (`default`, `rule`, `service` or `check`): person ids, or `["everyone"]`. |
| `test_alert` | `admin` | Sends a test alert by one channel, or to one person's destination with `person`. Answers sent, or one fixed reason. Four at once for each token, then one every 25 seconds; a page, or a push through PagerDuty, stays open for two minutes and then resolves itself, and costs twice as much (two at once, then one every 50 seconds). |
| `accept_suggestion` | `admin` | Sends a service's issues to the daily digest from now on. |
| `dismiss_suggestion` | `admin` | Dismisses an alert suggestion. |
| `restore_archive` | `admin` | Loads an archived month of logs back for a week. |

## Rules

- **Log contents have their own scope.** A token can be given everything except what is written in the logs.
- **A new token has no `act` scope** unless it is asked for.
- **Read tools are marked read-only**, so a client can run them without asking each time. `admin` tools are marked destructive.
- **What comes back is data.** Names, titles, notes, error text, deploy fields and output were written by machines and apps. Every answer starts with a line that says so.
- **Arguments are checked against the types the tool declares.** A wrong type is an `isError` answer, not a failure. A `null` argument is the same as one left out, and a whole number written as `5.0` is an integer. To clear a route, send an empty text.
- **Lists page by cursor.** The list tools (`find`, `jobs`, `job_runs`, `logs`, `errors`, `machines`, `issues`, `deploys`, `rules`, `proposals`, `keys`, `people`, `releases`) take the filters of their API list, `cursor` and `limit` (1 to 500, default 100). A list that fits one page answers as an array, as before; a longer one, or any call with `cursor` or `limit`, answers `{"items": [...], "next": "<cursor or null>"}`. `issues` takes `state` (`open`, `snoozed`, `closed` or `all`). `errors` with an `id` pages the group's reports the same way. `accept_proposal` and `dismiss_proposal` take `ids` or `all`. `proposals` is the one list that always answers an object, so that `hidden` has a place; it takes `system` (boolean) to include the operating system's own findings.
- **A token with `admin` can do through MCP everything a person can do in the interface,** except pairing phones, which carries a key that must not pass through an AI tool, and moving and deleting log lines of a service (`POST /services/<id>/logs/move` and `/logs/delete`), destructive actions that are the API's alone. Making such a token asks for confirmation in Settings.

## Built so far

`POST /mcp` with a user token: every tool in the table, 70 in all (25 `read`, 2 `read-logs`, 14 `act`, 29 `admin`), one for each call of the API a token can make. Making a full-control token, pairing and removing phones (`/phones`), moving log lines between services and the browser's own sign-in have no tool: they are Settings and the browser only. A tool the token may not use is not listed.

## The public MCP at mcp.dokkit.dev

A second, separate MCP for anyone writing a `dokkit.toml` or wiring a client library. It needs no account and no Dokkit server, reads none of your data, and stores nothing.

```
claude mcp add --transport http dokkit-help https://mcp.dokkit.dev/
```

It is `dokkit public-mcp --http 127.0.0.1:8090` behind a reverse proxy: streamable HTTP, JSON-RPC 2.0 by `POST /` (`initialize`, `ping`, `tools/list`, `tools/call`, the same protocol version handling as `/mcp`). `GET /` answers how to connect, as plain text.

| Tool | Takes | Does |
|---|---|---|
| `check_file` | `text` | Checks a `dokkit.toml` with the program's own code, as `dokkit check` does, without running any check. Answers `verdict` (`accepted` or `refused`); a refusal has the program's words in `error` with an `explanation` and a `fix`; an accepted file has its checks (`runs` true for those `dokkit watch` makes, false for those the app reports), jobs, log path, and in `sends` the JSON `dokkit apply` would send. |
| `example_file` | `kind` | A starting file that passes the check: `web`, `worker`, `windows`, `linux`, `job`, `dependency` or `certificate`. |
| `library_calls` | `language` | A client library's install line and its setup, start, beat, job, capture and logging calls, from `clients/`. Common other names (`ts`, `c#`, `golang`, `bash`) are understood. |
| `explain_error` | `error` | What a refusal from the checker means and how to fix it. Text the checker does not write gets a general answer. |

A request is at most 64 KB. Each address may make 60 requests a minute; `X-Forwarded-For` is believed only from a proxy on the same host. Reads and writes time out after 15 seconds.
