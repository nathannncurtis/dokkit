# Client library conformance

Runs the smallest program of each client library against a real local Dokkit server and checks the rows the server stored: the version, a beat, a job run that ended ok, a check, a metric, a log line, its fields (where the library sends them) and an error report of type ConformanceError. Each program runs twice, once as production and once with DOKKIT_ENV=dev. The dev run must land on the sibling service `conformance~dev` and leave the main service untouched.

Run it from a clone with the server's dependencies fetched:

    python clients/conformance/run.py --server-dir server --deps-path server/deps

`--only python,go` limits the languages. A language whose toolchain is not installed is skipped and listed. The script starts the server on port 4491 (`--port`) with its own database `dokkit_conformance`, which it drops and recreates, then stops it by pid. `--no-server --url URL --key KEY [--app SLUG]` uses a server that is already running instead. The table of language by check is printed, and the exit code is non-zero on any failure.

Requirements: Python 3, Elixir and Erlang for the server, PostgreSQL on localhost (user and password `postgres`; `--pguser`, `--pgpass`, `--pghost` change that) with `psql` on the path, and whichever of node, go, cargo, dotnet, javac, php, pwsh, bash with curl, and elixir you want checked. Build output goes to a folder under the system temp directory.
