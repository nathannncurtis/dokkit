# The Dokkit server

Phoenix on Postgres. The contract it implements is in `../spec/`.

```
mix setup        # dependencies, database, assets
mix phx.server   # http://localhost:4000
mix test
```

The database address for development is in `config/dev.exs`.

A server with no account prints a setup code when it starts. The first visit asks for it and creates the owner. Until the interface can add things, `mix dokkit.job MACHINE NAME --schedule "0 1 * * *"` adds a job to watch and prints its ping addresses.
