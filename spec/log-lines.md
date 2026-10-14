# Log lines

One JSON object per line.

```json
{"t": "2026-10-05T21:14:03.120Z", "level": "error", "msg": "Upload failed", "service": "upload-portal", "fields": {"route": "/upload", "status": 500}}
```

| Field | Required | Holds |
|---|---|---|
| `t` | No | When it happened. RFC 3339. A line without it, with one that cannot be read, dated in the future or a year or more back, is stamped with the time it arrived. |
| `level` | No | `trace`, `debug`, `info`, `warn`, `error` or `fatal`, in lower case. A missing or unrecognised level is stored as `info`. |
| `msg` | No | The line. A line without it is kept whole, as JSON, as its message. |
| `service` | No | The service id. Filled in from `dokkit.toml` or the app key when absent. |
| `fields` | No | Anything else, as a flat object. Searchable. |
| `environment` | No | The environment of the run. `production` or absent leaves the line on the service; another value puts it on a sibling service that never alerts, unless the service has a `dokkit.toml` declaration (`api.md`, under `POST /report`). |

A line that is not JSON is kept as `msg` with level `info` and the time it was read.

## Ways in

1. **`dokkit` reads files** named under `[logs]` in `dokkit.toml`. A file's read position only moves forward after the server confirms it has the lines, so a line can arrive twice and never goes missing. Files are recognised by their first bytes, so rotation and renames are followed. Every line is sent as the file's service; a `service` field of the line's own is kept in `fields`, or as `service_name` on a CLEF line. A line without `msg` uses `message`, then `event`, then the whole line.
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
| `@i`, `@r` | Dropped. |
| Everything else | `fields` |

### Through Seq's address

`POST /api/events/raw` (and `POST /ingest/clef`) takes what Seq clients send, so an app moves by changing its server URL and API key to Dokkit's and an app key. The key is read from `X-Seq-ApiKey` or `?apiKey=`. Both body forms are read: CLEF lines, and the older `{"Events": [...]}` form, whose `Timestamp`, `Level`, `MessageTemplate`, `RenderedMessage`, `Exception` and `Properties` are read as `@t`, `@l`, `@mt`, `@m`, `@x` and the properties of a CLEF line. The service is the app key's service; a property called `environment` is read as on any report line. Level names are read without regard to case and in their short forms: `Verbose`, `Trace`, `Silly` (trace), `Debug` (debug), `Information`, `Info` (info), `Warning`, `Warn` (warn), `Error` (error), `Fatal`, `Critical` (fatal); the one-to-three-letter forms Serilog writes (`Vrb`, `Dbg`, `Inf`, `Wrn`, `Err`, `Ftl`) are read too, and an unknown name is stored as `info`. A template is rendered with the properties, so `Saved {File}` is stored as `Saved a.pdf`; a property the template does not name stays in `fields`. A property called `service`, `at` or `type` is kept as `service_name`, `seq_at` or `seq_type`. The limits are those of `POST /report`.

## Limits

A message is kept to 64 KiB, and so are a line's `fields` taken together (over that they are dropped); the stored line is marked as cut. `dokkit` applies the same limit to a line the server will not take whole, and adds `[dokkit cut N bytes]` to the end of a cut message. A batch is at most 10,000 lines and 5 MB compressed; `dokkit` halves a batch the server answers `413` for. Lines the server refuses one by one (the `refused` list of the report answer) are kept by `dokkit` in the spool as `.rejected` with the reason, and counted in a warning log line.

## Storage

Postgres, one partition per month. Twelve months are kept live by default; the number (1 to 120) is a setting, `GET`/`PUT /logs/retention`. Each older month is archived as one compressed file and can be loaded back, or, when the setting `action` is `delete`, dropped with no file. A change acts on the next hourly sweep. Archive files that already exist stay either way.

## Not now

OpenTelemetry intake. It is the neutral standard, but its log libraries are unfinished in several languages and it carries a stack trace as one block of text. The API leaves room for it as another door later.

## Built so far

`log` lines in a `POST /report` batch, in Dokkit's format or CLEF, stored in monthly partitions, with the Logs page and each service's latest lines. A line with no `msg` is kept whole, as JSON, in its message. A line dated in the future or a year or more back is stamped with the time it arrived. `dokkit watch` reads the files named under `[logs]` every five seconds, up to 1 MB and 5,000 lines of each at a time, and knows a file by its first line together with the file's own identity (the inode, or on Windows the volume and file index), so a renamed file is still followed and two files that start with the same line keep separate positions. A rotated copy made by copying rather than renaming is a new file and is read again from the start if the `[logs] path` pattern matches it. A position saved by an earlier version, under the first line alone, is taken over by the first file that starts with that line. The libraries' log handlers send lines too, and months older than the live limit (12 months unless changed) are archived to a folder when one is set. The Settings page lists the archived months and loads one back for a week, after which it is archived again.
