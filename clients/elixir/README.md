# Dokkit for Elixir

One file, no packages, Elixir 1.18 or later. `Dokkit.beat`, `job`, `check`, `capture`, `log`.

## Install

Nothing is published to a registry yet. In `mix.exs`, point at a clone of the repo:

```
{:dokkit, path: "path/to/dokkit/clients/elixir"}
```

Once the repository is public, this also works:

```
{:dokkit, git: "https://github.com/nathannncurtis/dokkit", sparse: "clients/elixir"}
```

## Logging

The `Dokkit` module is a `:logger` handler: `:logger.add_handler(:dokkit, Dokkit, %{level: :info})`. It leaves out what the sender process logs, and what the HTTP and TLS libraries log while one of its sends is running or has just ended (or when the record carries `dokkit: true`), so sending cannot feed itself. Your own failed TLS or HTTP calls at any other time are logged.

## Test

`mix test`
