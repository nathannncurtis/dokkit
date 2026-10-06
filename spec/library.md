# The client library

For what only the app knows about itself. The same five things in every language, with the same names.

| Call | Gives |
|---|---|
| `beat("name")` | The app calls it from its main loop or worker. If the beats stop while the process is still up, the service is stuck but alive, which nothing outside the app can see. |
| `job("name")` | Start, finish, failure, and progress such as "4,000 of 9,000". |
| `check("name", state, value, note)` | The app's own checks, for example "the oldest item in the queue is 14 minutes old". |
| `capture(error)` | Sends an error in the format in `errors.md`. Can also catch unhandled errors if asked to. |
| A log handler | Plugs into the language's normal logging. Optional: writing lines to a file for Davit to read works just as well. |

It can also send the stats document (`stats-v1.md`) itself, for an app Davit cannot reach, such as a desktop app or a phone app. There is one stats format and two ways to deliver it: Davit fetches it, or the library sends it.

## Rules

- **Blank configuration means off.** With no address set, every call does nothing.
- **It never breaks or slows the app it lives in.** Sending happens in the background. A failure to send is dropped, never raised.
- **It uses a fixed amount of memory.** A full queue drops the oldest and counts what it dropped.
- **It sends no personal data by default.** No error message text, no request contents, no user records.

## Configuration

Two environment variables:

| Variable | Holds |
|---|---|
| `DOCKET_URL` | The server address. |
| `DOCKET_KEY` | An app key. |

The service's id and version come from the app key and from what the app passes at start.

## Machines with no Davit

An app using the library reports its host name. The host shows up in Docket as a machine of the `seen` kind, with its last-seen time, the app's version on it, and its errors. This is how staff PCs become rows without installing anything extra on them.

## Languages

Python and C# first. Any other language can use the plain API or the ping URLs in `api.md` until it has a library.
