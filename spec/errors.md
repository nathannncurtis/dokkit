# Errors

Two doors. Docket's own is the front door. The second exists so that an app in a language with no Docket library yet can still report.

## Docket's own format

`POST /api/v1/errors` with an app key.

```json
{
  "at": "2026-10-05T21:14:03.120Z",
  "service": "upload-portal",
  "release": "2.3.0",
  "environment": "production",
  "host": "host-01",
  "type": "TimeoutError",
  "handled": true,
  "frames": [
    {"file": "app/worker.py", "function": "run_job", "line": 212, "own": true},
    {"file": "site-packages/httpx/_client.py", "function": "send", "line": 914, "own": false}
  ],
  "tags": {"route": "/upload", "status": "500"}
}
```

| Field | Holds |
|---|---|
| `type` | The error's class or type name. |
| `frames` | The stack, innermost last. `own` says whether the frame is the app's own code. |
| `release` | The deployed version. Ties an error to a deploy. |
| `handled` | Whether the app caught it. |
| `tags` | A few short labels. Never free text from a request. |
| `message` | Optional, and off by default. The library does not send message text unless told to, because messages are where personal data ends up. |

Not accepted at all: request bodies, headers, cookies, local variables, user records.

Errors are grouped by `type` and the app's own frames. A group is one row in the interface.

## Reports from Sentry's open-source SDKs

Docket also accepts reports from Sentry's open-source SDKs. An SDK is given an address made from an app key and Docket's host, and sends to:

```
POST /api/<project>/envelope/
```

The path is that shape because the SDKs build it from the address they are given.

What Docket does with a report:

- **Error events are stored**, mapped onto the same fields as Docket's own format.
- **Everything else is read and dropped**: performance traces, sessions, replays, profiles, attachments. The answer is still a success, and it tells the SDK to stop sending those kinds.
- The app key is taken from the auth header, the query string or the envelope header, whichever the SDK used.
- Compressed bodies are accepted.
- Message text follows the same rule as above: kept only if the service is set to keep it.

This door is written from the published protocol. It contains no code from Sentry's server. See `docs/sentry-compatibility.md` for how the project talks about it.
