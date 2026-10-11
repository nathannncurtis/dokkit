# Errors

Two doors. Dokkit's own is the front door. The second exists so that an app in a language with no Dokkit library yet can still report.

## Dokkit's own format

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
| `environment` | `production` when left out. Another value files the error under that environment's own service, which never alerts. The rule is in `api.md`, under `POST /report`. For Sentry's SDKs it is the event's `environment`. |
| `handled` | Whether the app caught it. |
| `tags` | A few short labels. Never free text from a request. |
| `message` | Optional, and off by default. The library does not send message text unless told to, because messages are where personal data ends up. |

Not accepted at all: request bodies, headers, cookies, local variables, user records.

Errors are grouped by `type` and the app's own frames. A group is one row in the interface.

## Reports from Sentry's open-source SDKs

Dokkit also accepts reports from Sentry's open-source SDKs. An SDK is given an address made from an app key and Dokkit's host, and sends to:

```
POST /api/<project>/envelope/
```

The path is that shape because the SDKs build it from the address they are given.

What Dokkit does with a report:

- **Error events are stored**, mapped onto the same fields as Dokkit's own format.
- **Everything else is read and dropped**: performance traces, sessions, replays, profiles, attachments. The answer is still a success, and it tells the SDK to stop sending those kinds.
- The app key is taken from the auth header, the query string or the envelope header, whichever the SDK used.
- Compressed bodies are accepted.
- Message text follows the same rule as above: kept only if the service is set to keep it.

This door is written from the published protocol. It contains no code from Sentry's server. See `docs/sentry-compatibility.md` for how the project talks about it.

## Built so far

`POST /api/v1/errors` in Dokkit's own format, the Errors page, `GET /errors` and the `errors` tool. Message text is dropped unless the service's page is set to keep it, and then it is kept from that moment on, up to 2,000 characters, for reports through either door. The libraries never send it. A group stores its first hundred reports and then one in a hundred; the count is exact. The door for Sentry's SDKs takes gzip or plain envelopes and keeps their error events. An error does not open an issue or alert anyone.
