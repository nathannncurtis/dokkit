# Dokkit for Python

One file, standard library only. `beat`, `job`, `check`, `capture`, `log`. See `dokkit.py`.

## Install

Nothing is published to a registry yet. Install from a clone of the repo:

```
pip install path/to/dokkit/clients/python
```

Once the repository is public, this also works:

```
pip install "git+https://github.com/nathannncurtis/dokkit#subdirectory=clients/python"
```

## Start

`dokkit.start(version="2.3.0")` reads `DOKKIT_URL` and `DOKKIT_KEY`. `dokkit.start(version="2.3.0", url=URL, key=KEY)` uses what it is given and does not read the environment: a blank `url` or `key` means off, whatever the environment holds.

Frames under the program's folder are the app's own: the executable's folder in a frozen app, otherwise the main script's. The working directory is used only when the main script is a runner inside the Python install, such as `python -m unittest` or `gunicorn`. `start(root=...)` names the folder instead.

Every `start(version=...)` sends a `deploy` line, and that is meant. The server stores the version and records a deploy only when it changes; for an app on many PCs it keeps one row per PC.
`start(announce_version=False)` leaves the line out. `dokkit.enabled()` is true once started with an address and key. A set `environment` other than `production` is on every line.

## Sending

Lines go first, then error reports. An error report the server did not answer for is kept and sent on a later pass; the newest 100 are kept. `dokkit.dropped()` is how many lines and reports were dropped. When that count grows, a `dokkit_dropped` metric line carries it. A line over 64 KB has its `msg` cut and ends in ` [cut]`; if it is still too big its `fields` are dropped. A 429 or 5xx on an error report keeps it for the next pass; any other 4xx drops it.

`dokkit.flush()` runs at exit and waits at most `dokkit.FLUSH_SECONDS`, 5 unless set. `dokkit.flush(timeout=2)` waits at most that long.

## Logging

`logging.getLogger().addHandler(dokkit.handler())` sends the standard `logging` module's records through `log`: the message, the logger's name, and what was passed as `extra=` as fields. With `exc_info` it also sends `exception` (the type name) and `stack` (one `path:line function` per line, paths relative to the app's folder), never the error's message. A value JSON cannot write is sent as its `repr`. An error report never carries the error's message; a log line carries what the app logs.

## Test

`python -m unittest test_dokkit`
