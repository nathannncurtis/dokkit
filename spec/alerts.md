# Alerts

## When something becomes an issue

- A check has to fail 3 times in a row. That number can be changed per check.
- A job becomes an issue when it is later than its grace time, or runs past its maximum.
- A machine that has not reported for 3 minutes is down.
- Anything in an environment other than `production` never opens an issue that alerts.

## What stops repeats

- An open issue alerts once.
- If it recovers and fails again inside 30 minutes, that is the same issue with a higher count. It does not alert again.
- When a machine is down there is one alert for the machine. Everything on it goes quiet until it is back.
- A snoozed issue never alerts.
- Paging again when a page is not acknowledged is left to the paging service's own escalation. Dokkit does not duplicate it.

## Recovery

An issue closes itself after 3 good checks, and the page it raised is resolved automatically.

## Channels

| Channel | Delivered by |
|---|---|
| `page` | PagerDuty, high urgency. |
| `push` | A quiet phone notification, through one of: PagerDuty at low urgency, ntfy, or Pushover. |
| `email` | A mail server. |
| `text` | An address that turns mail into a text message. |
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

Every channel in the table, with one server-wide choice for `down` and one for `degraded`, each service's own routing, and rules. An issue's channel is its service's routing if it has one, else the first rule that fits, else the server-wide choice. A rule's condition is the kind of thing (a job, a check, a machine), what happened (stops, struggles) and optionally one machine. Everyone is one recipient so far: one email address and one text address in the settings.

An alert is written with its issue and sent afterwards, and a send that fails is tried again a minute later, up to five times. An alert skipped while its issue was briefly closed is sent when the issue reopens. Mail goes through the mail server in the settings, always over TLS (port 465 from the first byte, any other port by STARTTLS), and has not been sent through a real one yet. A blank setting falls back to its default. The addresses for ntfy, the webhook and the heartbeat must be https and may not point at this machine or a link-local address, and only the owner sees them. The digest holds what opened without paging, errors first seen that day from any app, and thresholds, built-in ones included, within a tenth of their limit; an alert is marked sent only when the mail that carried it went out, and a failed digest is logged and tried again.

Each machine's own disks and memory are watched without a declaration, against two limits on the Alerts page (90 and 95 percent used unless changed; blank switches one off), by the usual three-in-a-row rule. A threshold a file declares for the same number replaces the built-in one.

One suggestion is made: an issue that has opened six times or more in a month and is snoozed is offered the daily digest, on the Alerts page, and accepting sets that service's routing. Dismissing it stops the offer for that service. Email and text go to every address in their setting, written with commas between them; who receives a page or a push is decided in PagerDuty, ntfy or Pushover.
