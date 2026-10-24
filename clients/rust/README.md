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

`dokkit::log_fields("info", "paid", &[("order", 42.into()), ("who", "x".into())])` sends fields as a flat object.

Frame paths: a file under the working directory is relative to it, a dependency keeps its path inside its crate, any other file is its name only. Rust has no program folder, so the working directory stands in for it.

Report bodies are not gzipped. `ureq` compresses nothing it sends, and `flate2` would be a new dependency.

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
