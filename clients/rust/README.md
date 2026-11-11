# Dokkit for Rust

One file and one package, `ureq`. `beat`, `job`, `check`, `metric`, `capture`, `log`, `stats`, `deploy`.

## Install

Nothing is published to a registry yet. In `Cargo.toml`, point at a clone of the repo:

```
dokkit = { path = "path/to/dokkit/clients/rust" }
```

Once the repository is public, this also works:

```
dokkit = { git = "https://github.com/nathannncurtis/dokkit" }
```

## Start

`dokkit::start("2.3.0")` reads `DOKKIT_URL`, `DOKKIT_KEY` and `DOKKIT_ENV`; `start_with(version, url, key)` uses what it is given, and a blank address or key means off. `dokkit::environment("staging")`, called before start, names the environment instead of `DOKKIT_ENV`; any value but `production` is put on every line sent.

Start sends a `deploy` line with the version from the sender thread, once per process. The server records a deploy only when the version changes. `dokkit::announce_version(false)`, called before start, turns the line off.

## Sending

Lines go first, then error reports. A report the server did not answer for (no answer, 5xx, 429) is kept and sent on a later pass, at most 100; one it refuses with another 4xx is dropped and counted in `dokkit::dropped()`.

`dokkit::flush()` waits at most 5 seconds, or `dokkit::flush_timeout(duration)`. A panic seen by `dokkit::catch_unhandled()` is an error report of type `panic` with the file, line and backtrace frames of where it happened, never its message, and is flushed with that limit. A line over 64 KB loses the end of its `msg` (ending ` [cut]`), then its fields.

`dokkit::set_interval(duration)` (or the environment variable `DOKKIT_INTERVAL_SECS`, read by `start`) sets how long the sender sleeps between sends, 2 seconds unless set and at least 100 ms. While nothing is queued the sender does no work, so an app that logs a few lines now and then can use a long interval and call `dokkit::flush()` when it finishes a batch. A full batch (500 lines), an error report and `flush` send at once whatever the interval, and a failed send is retried within 2 seconds. The sender keeps one connection between sends while the server allows it.

`dokkit::log_fields("info", "paid", &[("order", 42.into()), ("who", "x".into())])` sends fields as a flat object.

Frame paths: a file under the working directory is relative to it, a dependency keeps its path inside its crate, any other file is its name only. Rust has no program folder, so the working directory stands in for it.

Report bodies are not gzipped. `ureq` compresses nothing it sends, and `flate2` would be a new dependency.

## A small resident service

`dokkit::start_manual("2.3.0")` (or `start_manual_with(version, url, key)`) starts no thread. Lines and checks wait in memory, and `dokkit::flush()` sends them on the calling thread: lines first, then error reports. A batch that fails is held and tried again on the next `flush`, not before. The version line goes out on the first `flush`. Each request takes at most `flush_timeout` (5 seconds unless set), so one `flush` takes at most about twice that when the server is down. `set_interval` and `DOKKIT_INTERVAL_SECS` do nothing in this mode.

Nothing is set up at start: no network, no TLS, no hostname lookup. The first `flush` builds one agent for the process. The server address is looked up once and kept; it is looked up again only after a connection fails. In manual mode no connection is kept open between sends. TLS session tickets are kept, so a reconnect resumes the earlier session instead of a full handshake (checked against a local TLS 1.3 server: the first request was a new session, the next two were resumed).

How often to flush: only a `beat` keeps a service from showing down. A check or a log line does not count. `dokkit::beat(name, S)` declares that a beat is due every S seconds, and the server marks it down when none has arrived for more than 2 x S + 60 seconds (`beat_misses` 2 and `beat_slack_seconds` 60, settings on the server). Pass S as the time between your flushes, call `beat` once before each `flush`, and flush at least every S seconds. For example `beat("worker", 300)` with a flush every 5 minutes shows down after 11 minutes of silence. See `server/lib/dokkit/intake.ex` (the `beat` line) and `server/lib/dokkit/watch.ex` (`verdict` for beats).

## Logging

With the `log` feature, `dokkit::Logger` implements the `log` crate's `Log` trait. The feature is off by default.

```
dokkit = { path = "path/to/dokkit/clients/rust", features = ["log"] }
```

The logger ignores whatever is logged on the thread that is sending, `ureq`'s own lines included, so its own sending is never logged back into it. A crate of yours with any name is logged. Record key-values are not sent.

```
log::set_logger(&dokkit::Logger).unwrap();
log::set_max_level(log::LevelFilter::Info);
```

## Test

`cargo test` and `cargo test --features log`
