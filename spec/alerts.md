# Alerts

## When something becomes an issue

- A check has to fail 3 times in a row. That number can be changed per check.
- A job becomes an issue when it is later than its grace time, or runs past its maximum.
- A run that is still going past its maximum is `down` ("has run too long") and takes the down route. A run that finished over its maximum is `soon` ("ran long"): it lists under Soon and never pages.
- A disk or memory over its limit on the Alerts page is `degraded` and takes the degraded route (a push unless changed). From 98 percent used it is `down`. A limit a `dokkit.toml` declares for a number is `down` as soon as it is passed.
- A disk heading for its limit within 14 days is `soon`, and stays soon until the line is more than 16 days away. The forecast runs every 30 minutes; it closes when the limit is switched off or the readings stop.
- A job found by a scan and watched waits for its first report, and is not judged late until it has reported once. Only `dokkit run --job <name> -- <command>` can report it.
- A machine that has not reported for 3 minutes is down.
- Anything in an environment other than `production` never opens an issue that alerts.

## What stops repeats

- An open issue alerts once.
- If it recovers and fails again inside 30 minutes, or falls back to the state it had, that is the same issue with a higher count. It always has a live alert: if the page was resolved in between, it pages again, because the resolve closed the incident. If nothing was resolved (the resolve was never sent, or the channel has nothing to resolve) nobody is told twice. Flapping every minute for ten minutes pages five times when each resolve went out before the next failure, and nobody when the alerts were not sent between flaps.
- When a machine is down there is one alert for the machine. Everything on it goes quiet until it is back.
- A snoozed issue never alerts. An alert held for the night is dropped if its issue was snoozed or marked as seen meanwhile.
- A warning that becomes a failure (soon to not soon, degraded to down) closes the old issue, which resolves what it sent, and opens a new one that alerts by its own route. A failure that becomes a warning does the same the other way. The new issue keeps the number (`DOK-n`) and the notes of the old one. It also keeps an unexpired snooze and the seen mark, unless it is an escalation (a warning or soon becoming down): that always comes back and alerts.
- A `soon` issue never pages and never follows a rule. If its route is `page` it is sent as a push; with no push destination set, the send fails, is shown as failed and is tried five times.
- Paging again when a page is not acknowledged is left to the paging service's own escalation. Dokkit does not duplicate it.

## Night

One night is set for the whole server on the Alerts page: a start hour, an end hour and the hours from UTC (22, 7 and 0 unless changed). No time zone database is installed, so the night is a fixed offset and does not follow daylight saving.

Each service has a switch, "Wake me at night for this", on by default. When it is off and an alert for that service would go out during the night, Dokkit holds it and sends it when the night ends, if the issue is still open. An issue that closed in the meantime sends nothing. A held alert is a row in the database, so it survives a restart, and the once-a-minute sweep sends it. Whether an alert is held follows the server's clock when the report arrives, never the time the sender wrote. The first screen says "Held until 07:00 UTC+2" for it, in the night's own offset. Turning the switch on sends what is held for that service, except for an issue that is snoozed or seen. Turning the switch back on sends what is held for that service at once. The daily digest is not held.

## Recovery

An issue closes itself after 3 good checks, and the page it raised is resolved automatically.

## Channels

| Channel | Delivered by |
|---|---|
| `page` | PagerDuty, high urgency. |
| `push` | A quiet phone notification, through one of: PagerDuty at low urgency, ntfy, or Pushover. |
| `email` | A mail server. |
| `imessage` | One enrolled Mac that is signed in to Messages. The server hands that Mac a built-in piece of work, `dokkit:imessage`, with the recipients and the one-line summary; the alert counts as sent only when the Mac answers with exit code 0. For people who do not want to register a phone number for automated texts. |
| `sms` | A Twilio account: one request to Twilio for each recipient, sent from the Twilio number in the settings. |
| `digest` | One email a day. |
| `webhook` | A plain web request to an address. |

## Rules

A rule is a condition, a channel, and who receives it. Each service also has its own routing for `down` and for `degraded`, which a `dokkit.toml` can suggest and the interface decides.

## The digest

Sent once a day at a time that is a setting. It holds:

- errors from desktop apps, by machine and app
- issues that opened or closed without paging
- anything about to cross a limit

A day with nothing to say sends nothing.

## Suggestions

Dokkit notices patterns in how alerts are handled, for example an alert that fired six times and was snoozed every time, and offers a change. A suggestion is accepted or dismissed by a person. Dokkit never changes a rule itself.

## Not now

Learning what normal looks like and flagging the unusual. Limits are fixed numbers that a person sets.

## Built so far

Every channel in the table, with one server-wide choice for `down` and one for `degraded`, each service's own routing, and rules. An issue's channel is its service's routing if it has one, else the first rule that fits, else the server-wide choice. A rule's condition is the kind of thing (a job, a check, a machine), what happened (stops, struggles) and optionally one machine. Everyone is one recipient so far: the email, iMessage and SMS addresses in the settings.

An iMessage goes out through the Mac named in `imessage_machine`, an enrolled machine whose os is `darwin`, to the phone numbers and email addresses in `imessage_to`. An opening alert queues one run of `dokkit:imessage` for that Mac alone. The alert is `sending` until the Mac answers: exit code 0 makes it sent, a refusal or any other exit makes it failed with the refusal or the program's output lines as the reason. If the Mac has not answered after 5 minutes (not connected, asleep) the alert fails with "The Mac that sends iMessages, <name>, did not pick it up." The run stays, so a late success still marks the alert sent, and a retry waits on that run instead of queuing a second message; a retry after a failed answer queues a new run. A close sends nothing. Choosing `imessage` while no Mac is chosen is allowed and the Alerts page says it will not send. The Mac must have been told it may send (`dokkit imessage on`, run on that Mac), and macOS asks once on its screen.

SMS goes through `POST https://api.twilio.com/2010-04-01/Accounts/<sid>/Messages.json` with the settings `twilio_sid`, `twilio_token` (a secret) and `twilio_from`, to each number in `sms_to`. A 2xx is sent; anything else fails the alert with Twilio's `message` when it gave one. An alert recorded as `text` before this existed reads as "Texted"; every stored choice of `text` became `sms`.

An alert is written with its issue and sent afterwards, and a send that fails is tried again a minute later, up to five times. An alert skipped while its issue was briefly closed is sent when the issue reopens. Mail goes through the mail server in the settings, always over TLS (port 465 from the first byte, any other port by STARTTLS), and has not been sent through a real one yet. A blank setting falls back to its default. The addresses for ntfy, the webhook and the heartbeat must be https, and only the owner sees them. The digest holds what opened without paging, errors first seen that day from any app, and thresholds, built-in ones included, within a tenth of their limit; an alert is marked sent only when the mail that carried it went out, and a failed digest is logged and tried again.

Each machine's own disks and memory are watched without a declaration, against two limits on the Alerts page (90 and 95 percent used unless changed; blank switches one off), by the usual three-in-a-row rule. A threshold a file declares for the same number replaces the built-in one.

One suggestion is made: an issue that has opened six times or more in a month and is snoozed is offered the daily digest, on the Alerts page, and accepting sets that service's routing. Dismissing it stops the offer for that service. The settings, the test send and the suggestions are on the API and the MCP as well (`GET` and `PUT /alerts`, `POST /alerts/test`, `/alerts/suggestions`), and a secret or an address is never returned, only `set` or `not set`. Email, iMessage and SMS go to every address in their setting, written with commas between them; who receives a page or a push is decided in PagerDuty, ntfy or Pushover.

## Where an alert may be sent

A server on a private network sends to hosts on it: an internal ntfy, an internal mail relay. So private ranges are allowed. What is refused, for every destination (ntfy, webhook, heartbeat, the mail server), is loopback (127.0.0.0/8, `::1`, `localhost`), link-local (169.254.0.0/16 with the cloud metadata address, `fe80::/10`) and the unspecified address. The name is looked up once and every address it gives is checked, and the connection goes to the address that was checked. `DOKKIT_ALLOW_LOCAL_ALERTS=1` in the server's environment allows them.

The mail server may use ports 25, 465, 587 and 2525 only. The host is not looked up for mail exchangers.

A secret goes only to the host it was saved for. If `ntfy_url` or `smtp_host` changes in a save and its secret (`ntfy_token`, `smtp_password`) is not sent in the same save, the secret is cleared and the answer says so. A secret is cleared on its own by sending it empty; in the interface, by ticking Clear beside it.

A test send answers sent, or one fixed reason: "Dokkit could not deliver it there. The server log has the reason." Nothing the far end said (a banner, a body, a status) is shown; the log has it. Each token or person may send four tests at once, then one every 25 seconds.
