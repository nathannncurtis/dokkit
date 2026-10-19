# The Dokkit server

Phoenix on Postgres.

```
mix setup        # dependencies, database, assets
mix phx.server   # http://localhost:4000
mix test
```

The database address for development is in `config/dev.exs`.

`mix run --no-start priv/sample.exs` starts the server on invented data in its own database, `dokkit_sample`, at port 4010 (sign in as `sample` with `sample-password-1`). `DOKKIT_SAMPLE_DB` and `DOKKIT_SAMPLE_PORT` name another database and port.

A server with no account prints a setup code when it starts. The first visit asks for it and creates the owner. Jobs are added on the Jobs page, which shows their ping addresses once.
