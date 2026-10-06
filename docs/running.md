# Running the server

This is how it is meant to work. What exists so far is under "Built so far" at the end.

## Two forms

| Form | For |
|---|---|
| A native Windows service | A Windows machine with no containers. An installer sets it up. |
| A Docker image | Linux, a cloud host, or anywhere containers already run. A compose file is included. |

Both are the same server and can be moved between.

## The database

Postgres, always.

- **On Windows** the installer asks one question: set up a private Postgres for Dokkit, or use one that already exists. The first installs Postgres as its own Windows service, and later installers keep it up to date. The second takes a connection address.
- **In Docker** the compose file includes Postgres. A connection address can replace it.

## Backups

Dokkit does not back up its own database. Whoever runs it does, with whatever they already use for Postgres. The plain way is a nightly `pg_dump` to another machine, wrapped in `dokkit run` so the backup shows up as a job like any other.

Log months older than a year are archived as compressed files to a folder that is a setting. Those files are the archive, not a backup of the live database.

## First start

The first visit to the interface creates the owner account. It asks for a setup code that the server printed when it started, so nobody else on the network can claim it first.

## Who watches Dokkit

Dokkit cannot page about itself when it is down, so two things cover it:

1. **An outside heartbeat.** Dokkit calls an address every minute. The address is a setting. Point it at any service that alerts when the calls stop. That also covers the whole site losing power or its connection.
2. **Its own row.** Dokkit watches whether it is taking reports, how full its database is, and whether archiving worked, and shows itself as a service like any other. How that alerts is a choice. The default is a quiet push, and a page only when it can no longer take in or store reports.

## Upgrades

- Windows: run the newer installer over the old one. It stops the service, updates the database, and starts it again.
- Docker: pull the newer image.
- A server works with the `dokkit` program one version behind it, so machines do not have to be updated at the same moment.

## Reaching it

Its own usernames and passwords. It is meant for a local network or a private overlay network, and is not meant to be exposed to the internet.

## Built so far

**The packaged server.** `mix release` in `server/` builds it, and it has been started and stopped on Windows that way. It reads `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` and `PORT`, and `bin/dokkit eval Dokkit.Release.migrate` brings the database up to date before a start.

**Docker.** `server/Dockerfile` and `server/compose.yml`, with Postgres 17 beside it. Neither has been built or run yet: this was written on a machine with no Docker. It listens on plain HTTP on port 4000 for a proxy that holds the certificate.

**Windows.** No installer yet. By hand: build the release, set the four variables for the machine, run the migrate line above, then `bin\dokkit.bat install` and `bin\dokkit.bat start`, which register and start it as a Windows service. That last step has not been run.

**Its own TLS.** With `DOKKIT_CERT` and `DOKKIT_CERT_KEY` set to a certificate and its key, the server serves HTTPS itself and the enrol page shows the fingerprint for machines to pin.

**Who watches Dokkit.** The outside heartbeat is a setting on the Alerts page. Dokkit's own row is a service called Dokkit with one check, that the database answers, and a chart of the database's size. It routes to a quiet push.

**Archiving.** With `DOKKIT_ARCHIVE` set to a folder, each log month older than a year is written there as `logs-YYYY-MM.ndjson.gz` and dropped from the database, checked once an hour. `Dokkit.Logs.restore/1` loads a file back. Without the setting every month stays.

Not built yet: the installer and its private Postgres, and the rest of its own row (whether it is taking reports, whether archiving worked).
