# Moving over from other tools

## Side by side, for as long as it takes

Nothing is switched off on a date. Each check or app reports to both the old tool and Dokkit until Dokkit has been right about it for long enough to trust, and only then is the old one removed. Paging stays with the old tool until that moment, so nothing pages twice.

## From ping-style job monitoring

A job that calls a URL when it finishes moves by calling a second one. See the ping URLs in `spec/api.md`. Where the job runs on a machine with the `dokkit` program, wrapping it in `dokkit run` reports more: the exit code, the duration and the last lines of output.

## From Seq

Dokkit answers at the address Seq clients post to, and `dokkit import seq` copies what Seq has stored. Two steps, in this order, with Seq left running until both are checked.

### 1. Move an app

An app that logs to Seq keeps its logging code. Only two settings change.

1. In Dokkit, get an app key for the app's service: `POST /api/v1/keys` with `{"kind": "app", "service": "<service id>"}` (`spec/api.md`) makes one, shown once. A service added as an app has one already. The key starts `dka_`.
2. In the app, set the Seq server URL to the Dokkit server's address, such as `https://your.domain.com`, and the Seq API key to that app key.

Seq clients post to `/api/events/raw` (CLEF or Seq's JSON events) and newer ones to `/ingest/clef`. Dokkit takes both, and the key in the `X-Seq-ApiKey` header or the `apiKey` query value. seqlog was run against a capture server and both of its forms (CLEF and the JSON events) are tested with what it sent. Serilog.Sinks.Seq and the pino, winston and bunyan Seq transports send CLEF or the same JSON events; they are tested with bodies built from Seq's documented formats, not by a run of each. The tests are in `server/test/dokkit_web/controllers/seq_controller_test.exs`.

What the app sees: `201` with `{"MinimumLevelAccepted": null}`, as Seq answers; Dokkit asks for no minimum level. What Dokkit stores: each event as a log line of the key's service, with the same limits as `POST /api/v1/report` (10,000 events and 5 MB a request). The level is mapped to trace, debug, info, warn, error or fatal. The message template is filled in from the properties. Properties are kept as fields and an exception as `fields.exception`. The Logs page and `GET /api/v1/logs` show them with the app's other lines.

To keep the app logging to Seq for a while as well, add Dokkit as a second sink; nothing here stops Seq receiving.

### 2. Bring the history

`dokkit import seq` runs from any machine that can reach both servers. It needs no enrolment and no key beyond the ones it names: a Seq API key that may read, and a Dokkit app key for each service that takes lines. It sends through the same intake as step 1, so nothing needs an administrator on the Dokkit server.

```
dokkit import seq --from http://seq.example:5341 --seq-key <seq read key> --dry-run \
    --service-property app_name --app-pattern '^\[([^|\]]+?) *\|' --default-service misc
```

The dry run reads Seq and prints how many events would go to each service and each month, and which app names have no entry yet. It writes nothing and needs no Dokkit address.

Which service an event belongs to is decided in this order:

1. The first of the properties named by `--service-property` (comma separated, default `Application`) that holds text.
2. The first group of `--app-pattern` matched against the message, for old events that only name their app in the text. A message such as `[Invoice Sync | eu] Started` gives `Invoice Sync`.
3. Neither: the default service.

The name found is looked up, ignoring case, in the `--map` file, a JSON object from that name to a Dokkit service and its app key:

```json
{"Invoice Sync": {"service": "invoice-sync", "key": "dka_..."},
 "Order Fetcher": {"service": "order-fetcher", "key": "dka_..."}}
```

A name with no entry, and every event with no name, goes to `--default-service` using `--key` (or `DOKKIT_KEY`); the name found is kept in the line's `service_name` field. With no default and no entry the event is counted as not imported. Then the real run, the same command without `--dry-run` and with the Dokkit address:

```
dokkit import seq --from http://seq.example:5341 --seq-key <seq read key> --to https://your.domain.com \
    --key <default app key> --default-service misc --map map.json \
    --service-property app_name --app-pattern '^\[([^|\]]+?) *\|'
```

- It reads Seq's `GET /api/events` an hour at a time and sends oldest first, in batches of 1,000 lines, each with the time Seq stored. Each batch carries a `Dokkit-Batch` id made from what it holds, so a batch sent twice is stored once.
- It writes the last event it sent to the `--state` file (default `dokkit-import-seq-<address>.json` in the current folder). A stopped import continues from there when run again, and a second run later adds only what Seq has stored since. Use another `--state` file for another Seq server.
- `--rate` is the most lines a second it sends (default 200), and it waits when the server answers `429`. Run it with a rate under the 100 a second an app key refills at if the same key is logging live. `--since` and `--until` bound the times read, and `--filter` takes a Seq filter expression.
- Events more than 364 days old are counted by month and not sent. Dokkit keeps twelve months live and stamps a line a year or more old with the time it arrived, so sending them would put them in the wrong month. The count is printed at the end.
- A time in the future is stamped with the arrival time, as for every line.

### 3. Switch Seq off

Check the Logs page for the apps that moved against Seq for the same hour, and the per-service counts of the import against Seq's own. Then remove Seq.
