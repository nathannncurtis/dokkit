# Dokkit for shell

One file to source, needing only curl. `dokkit_beat`, `dokkit_job`, `dokkit_check`, `dokkit_capture`, `dokkit_log`.

## Install

Nothing is published to a registry yet. Copy `dokkit.sh` from a clone of the repo and source it:

```
. path/to/dokkit.sh
```

`dokkit_capture <type> <message>` sends an error. The message is not sent, and the report carries no stack.

## Logging

Shell has no logging framework, so there is no handler. Call `dokkit_log`.

## Test

`node --test`
