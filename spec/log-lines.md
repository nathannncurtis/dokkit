# Log lines

One JSON object per line.

```json
{"t": "2026-10-05T21:14:03.120Z", "level": "error", "msg": "Upload failed", "service": "upload-portal", "fields": {"route": "/upload", "status": 500}}
```

| Field | Required | Holds |
|---|---|---|
| `t` | Yes | When it happened. RFC 3339. |
| `level` | Yes | `trace`, `debug`, `info`, `warn`, `error` or `fatal`. |
| `msg` | No | The line. A line without it is kept whole, as JSON, as its message. |
| `service` | No | The service id. Filled in from `dokkit.toml` or the app key when absent. |
| `fields` | No | Anything else, as a flat object. Searchable. |

A line that is not JSON is kept as `msg` with level `info` and the time it was read.

## Ways in

1. **`dokkit` reads files** named under `[logs]` in `dokkit.toml`. A file's read position only moves forward after the server confirms it has the lines, so a line can arrive twice and never goes missing. Files are recognised by their first bytes, so rotation and renames are followed.
2. **The library's log handler** plugs into the language's normal logging and sends lines in batches.
3. **Anything else** can put `log` lines in a `POST /report` batch.

## The CLEF format

Dokkit also reads the Compact Log Event Format, the open line format written by Serilog and read by Seq (`@t`, `@l`, `@m`, `@mt`, `@x`). An app that already writes it can move by changing an address and nothing else.

| CLEF | Becomes |
|---|---|
| `@t` | `t` |
| `@l` | `level`. Absent means `info`. |
| `@m`, or `@mt` rendered | `msg` |
| `@x` | `fields.exception` |
| Everything else | `fields` |

## Storage

Postgres, one partition per month. Twelve months are kept live. Each older month is archived as one compressed file and can be loaded back.

## Not now

OpenTelemetry intake. It is the neutral standard, but its log libraries are unfinished in several languages and it carries a stack trace as one block of text. The API leaves room for it as another door later.

## Built so far

`log` lines in a `POST /report` batch, in Dokkit's format or CLEF, stored in monthly partitions, with the Logs page and each service's latest lines. A line with no `msg` is kept whole, as JSON, in its message. A line dated in the future or a year or more back is stamped with the time it arrived. `dokkit watch` reads the files named under `[logs]` every five seconds, up to 1 MB and 5,000 lines of each at a time, and knows a file by its first line. The libraries' log handlers send lines too, and months older than a year are archived to a folder when one is set. The Settings page lists the archived months and loads one back for a week, after which it is archived again.
