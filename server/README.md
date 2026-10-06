# The Dokkit server

Phoenix on Postgres. The contract it implements is in `../spec/`.

```
mix setup        # dependencies, database, assets
mix phx.server   # http://localhost:4000
mix test
```

The database address for development is in `config/dev.exs`.
