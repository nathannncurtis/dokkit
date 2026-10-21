# Dokkit for Elixir

One file, no packages, Elixir 1.18 or later. `Dokkit.beat`, `job`, `check`, `metric`, `capture`, `log`, `stats`.

## Install

Nothing is published to a registry yet. In `mix.exs`, point at a clone of the repo:

```
{:dokkit, path: "path/to/dokkit/clients/elixir"}
```

Once the repository is public, this also works:

```
{:dokkit, git: "https://github.com/nathannncurtis/dokkit", sparse: "clients/elixir"}
```

## Options

`Dokkit.start(version: "2.3.0")` announces the version once as a deploy line; the server records a deploy only when the version changes. `announce_version: false` turns that off. An `environment:` other than `production` (or `DOKKIT_ENV`) is put on every line. Report bodies are gzipped. A log line over 64 KB is cut and ends with ` [cut]`. Stack paths are relative to the folder the app was started from; files outside it carry only their name, or the part from `deps/`.

## Logging

The `Dokkit` module is a `:logger` handler: `:logger.add_handler(:dokkit, Dokkit, %{level: :info})`. It leaves out what the sender process logs, and what the HTTP and TLS libraries log while one of its sends is running or has just ended (or when the record carries `dokkit: true`), so sending cannot feed itself. Your own failed TLS or HTTP calls at any other time are logged.

## Test

`mix test`
