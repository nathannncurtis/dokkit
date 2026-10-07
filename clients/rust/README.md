# Dokkit for Rust

One file and one package, `ureq`. `beat`, `job`, `check`, `capture`, `log`.

## Install

Nothing is published to a registry yet. In `Cargo.toml`, point at a clone of the repo:

```
dokkit = { path = "path/to/dokkit/clients/rust" }
```

Once the repository is public, this also works:

```
dokkit = { git = "https://github.com/nathannncurtis/dokkit" }
```

## Logging

With the `log` feature, `dokkit::Logger` implements the `log` crate's `Log` trait. The feature is off by default.

```
dokkit = { path = "path/to/dokkit/clients/rust", features = ["log"] }
```

The logger ignores whatever is logged on the thread that is sending, `ureq`'s own lines included, so its own sending is never logged back into it. A crate of yours with any name is logged.

```
log::set_logger(&dokkit::Logger).unwrap();
log::set_max_level(log::LevelFilter::Info);
```

## Test

`cargo test` and `cargo test --features log`
