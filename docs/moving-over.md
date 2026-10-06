# Moving over from other tools

## Side by side, for as long as it takes

Nothing is switched off on a date. Each check or app reports to both the old tool and Dokkit until Dokkit has been right about it for long enough to trust, and only then is the old one removed. Paging stays with the old tool until that moment, so nothing pages twice.

## From ping-style job monitoring

A job that calls a URL when it finishes moves by calling a second one. See the ping URLs in `spec/api.md`. Where the job runs on a machine with the `dokkit` program, wrapping it in `dokkit run` reports more: the exit code, the duration and the last lines of output.

## From Seq

1. **New lines.** Apps that log to Seq write CLEF, which Dokkit reads as it is. An app moves by changing the address it sends to. See `spec/log-lines.md`.
2. **Old lines.** Seq's history is imported into Dokkit, so there is one place to search from the first day. Lines keep their original times. Where an old line only names its app inside the message text, the importer pulls the name out into the `service` field.
3. Seq is switched off once the import is checked.
