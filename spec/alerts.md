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

An alert is written with its issue and sent afterwards, and a send that fails is tried again each minute, five times. Mail goes through the mail server in the settings and has not been sent through a real one yet. The digest holds what opened without paging, errors first seen that day from any app, and thresholds within a tenth of their limit.

Not built yet: suggestions, and more than one recipient.
