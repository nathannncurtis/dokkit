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

**Docker.** `server/Dockerfile` and `server/compose.yml`, with Postgres 17 beside it. Neither has been built or run yet: this was written on a machine with no Docker. The base images are pinned by digest, the image has a health check that speaks plain HTTP, so it reports unhealthy when `DOKKIT_CERT` makes the server serve https, and the server listens on plain HTTP on port 4000 for a proxy that holds the certificate. Compose publishes the port on this machine only; `PHX_HOST` and a Postgres password of letters and digits (`openssl rand -hex 24`) are required.

**Windows.** `install.ps1` ships in the release folder and is run from an administrator PowerShell. It copies the server to `Program Files\Dokkit`, writes its settings to `ProgramData\Dokkit\settings.env` where only administrators and the system account can read them, brings the database up to date, and registers and starts a Windows service. The server reads that settings file itself, because a Windows service is not started through a script that could set variables.

The database is one of two, chosen the first time:

- `.\install.ps1 -Postgres <folder>` sets up a Postgres for Dokkit alone. The folder is Postgres's unpacked Windows binaries, the one holding `bin\initdb.exe`. It becomes a Windows service called `dokkit-postgres` that runs as Network Service, keeps its data in `ProgramData\Dokkit\pgdata`, and listens on this machine only, on port 54329.
- `.\install.ps1 -DatabaseUrl 'ecto://user:password@host/dokkit'` uses a Postgres that is already there.

Run again from a newer release with no arguments, it stops the service, copies, updates the database, registers the service again with the new paths and starts it. Settings that were given before are kept; any given again replace them. Given `-Postgres` again with a newer folder, it also stops Dokkit's Postgres, puts the newer binaries in place and starts it. It refuses a folder of a different major version of Postgres, which needs a dump and a restore.

The service runs as Local Service, starts with Windows after `dokkit-postgres`, and Erlang's service wrapper restarts it if it stops. It reads its settings from `ProgramData\Dokkit\settings.env` and writes its log to `ProgramData\Dokkit\log\dokkit.log`, a folder only administrators, the system account and Local Service can reach; the installer prints the setup code from it. The Erlang node's distribution port listens on this machine only, and its cookie is made at install time; it is kept in a file and in the service's registry key, both readable by administrators, the system account and Local Service only. The Erlang port mapper (port 4369) listens on every interface, so a firewall should keep it closed. The installer refuses a `ProgramData\Dokkit` folder that is owned by anyone but administrators. A folder given as `-Archive` is created and made writable by Local Service.

`-Cert` and `-CertKey` are a certificate and its key as PEM files. The installer copies them into `ProgramData\Dokkit` and the server serves https itself on the port. Without them it serves plain HTTP, and any machine but this one is sent to https, so it needs a certificate or a proxy that holds one.

`settings.env` may start with a byte order mark and may have spaces after values; both are ignored. `PHX_HOST` is required.

The script has not been run yet. The Postgres commands in it were tried by hand, apart from registering the service.

**Its own TLS.** With `DOKKIT_CERT` and `DOKKIT_CERT_KEY` set to a certificate and its key, the server serves HTTPS itself and the enrol page shows the fingerprint for machines to pin.

**Who watches Dokkit.** The outside heartbeat is a setting on the Alerts page. Dokkit's own row is a service called Dokkit with a check that the database answers, a chart of the database's size, a check that goes bad when every enrolled machine has been quiet for ten minutes at once, and, when an archive folder is set, a check that the folder can be written to. It routes to a quiet push.

**The program for machines to fetch.** With `DOKKIT_PROGRAMS` set to a folder holding `version.txt` and files named like `dokkit-windows-amd64.exe`, the Versions page lists the machines behind that version and can ask each to fetch the newer copy.

**Archiving.** With `DOKKIT_ARCHIVE` set to a folder, each log month older than a year is written there as `logs-YYYY-MM.ndjson.gz` and dropped from the database, checked once an hour. `Dokkit.Logs.restore/1` loads a file back. Without the setting every month stays.
