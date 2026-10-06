# Dokkit for Rust

One file and one package, `ureq`. `beat`, `job`, `check`, `capture`, `log`.

## Install

Nothing is published to a registry yet. In `Cargo.toml`:

```
dokkit = { git = "https://github.com/nathannncurtis/dokkit" }
```

## Logging

With the `log` feature, `dokkit::Logger` implements the `log` crate's `Log` trait. The feature is off by default.

```
dokkit = { git = "https://github.com/nathannncurtis/dokkit", features = ["log"] }
```

```
log::set_logger(&dokkit::Logger).unwrap();
log::set_max_level(log::LevelFilter::Info);
```

## Test

`cargo test` and `cargo test --features log`
