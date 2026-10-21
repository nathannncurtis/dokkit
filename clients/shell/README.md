# Dokkit for shell

One file to source, needing only curl. `dokkit_beat`, `dokkit_job`, `dokkit_check`, `dokkit_metric`, `dokkit_capture`, `dokkit_log`.

## Install

Nothing is published to a registry yet. Copy `dokkit.sh` from a clone of the repo and source it:

```
. path/to/dokkit.sh
```

`dokkit_capture <type> <message>` sends an error. The message is not sent, and the report carries no stack.

`dokkit_stats <file or JSON object>` sends a stats document. `dokkit_deploy <version>` sends a deploy line. When `DOKKIT_VERSION` is set, the first report of a process carries one; `DOKKIT_ANNOUNCE_VERSION=0` turns that off. The server records a deploy only when the version changes.

A `DOKKIT_ENV` other than `production` goes on every line. A line over 64 KB is cut in bytes, with ` [cut]` at the end of its message. A report body of 1 KB or more is gzipped when `gzip` is installed, and sent plain when it is not. An error report is sent again only when curl could not resolve or connect (nothing reached the server); a timeout or a 5xx is not repeated, because the server cannot tell a repeat from a new error.

## Logging

Shell has no logging framework, so there is no handler. Call `dokkit_log`.

## Test

`node --test`
