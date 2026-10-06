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

The `Dokkit` module is a `:logger` handler: `:logger.add_handler(:dokkit, Dokkit, %{level: :info})`.

## Test

`mix test`
