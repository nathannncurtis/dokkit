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

Dokkit connects with its time zone set to UTC, and a migration re-bounds any log month made under another zone.

Log months older than a year are archived as compressed files to a folder that is a setting. Those files are the archive, not a backup of the live database.

## First start

The first visit to the interface creates the owner account. It asks for a setup code that the server printed when it started, so nobody else on the network can claim it first.

## Who watches Dokkit

Dokkit cannot page about itself when it is down, so two things cover it:

1. **An outside heartbeat.** Dokkit calls an address every minute. The address is a setting and must be https. Point it at any service that alerts when the calls stop. That also covers the whole site losing power or its connection.
2. **Its own row.** Dokkit watches whether it is taking reports, how full its database is, and whether archiving worked, and shows itself as a service like any other. How that alerts is a choice. The default is a quiet push, and a page only when it can no longer take in or store reports.

## Upgrades

- Windows: run the newer installer over the old one. It stops the service, updates the database, and starts it again.
- Docker: pull the newer image.
- A server works with the `dokkit` program one version behind it, so machines do not have to be updated at the same moment.

## On a cloud VPS

On a fresh Debian or Ubuntu machine whose domain already points at it:

```
curl -fsSL https://dokkit.dev/install.sh | sudo sh -s -- dokkit.example.com
```

That form applies once the image (`ghcr.io/nathannncurtis/dokkit:latest`) and the site are published. Neither is yet. What works today is the same script from a checkout of this repository, which builds the image from the checkout:

```
sudo sh server/install.sh dokkit.example.com
```

It installs Docker and the compose plugin if they are missing and makes `/opt/dokkit/.env`. Piped, it fetches `compose.yml` from `https://dokkit.dev/compose.yml` (`DOKKIT_COMPOSE_URL` changes the address) and pulls the image, which `DOKKIT_IMAGE` can name instead; from a checkout it uses `server/compose.yml` there. It starts three containers: Postgres 17, the Dokkit server, and Caddy, which gets and renews the certificate for the domain by itself. It waits until the server answers over https, then prints the address and the setup code for the first visit.

- **Ports.** Only 80 and 443 are published. The server and Postgres are reachable inside the compose network only. Ports 80 and 443 must be open to the internet for the certificate.
- **Secrets.** `/opt/dokkit/.env`, readable by root only, holds the Postgres password, the key that signs sessions and the domain. They are made once and never changed.
- **Data.** The Postgres volume `dokkit_dokkit-db` and Caddy's certificates in `dokkit_caddy-data`, both under `/var/lib/docker/volumes`.
- **Upgrading.** Run the same command again. Piped, it fetches `compose.yml` again and pulls the image; from a checkout, update it first (`git pull`) and it rebuilds. The server restarts and brings the database up to date as it starts. The secrets and the volumes are left alone. An image named with `DOKKIT_IMAGE` is remembered in `.env` and pulled from then on, even from a checkout.
- **Backups.** Backing up the Postgres volume is the owner's job; see Backups above.

It refuses to run without root, without a domain, or on a system that is not Debian or Ubuntu, and says what to do by hand.

## Reaching it

Its own usernames and passwords. It is meant for a local network or a private overlay network, and is not meant to be exposed to the internet.

## Built so far

**The packaged server.** `mix release` in `server/` builds it, and it has been started and stopped on Windows that way. It reads `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` and `PORT`, and `bin/dokkit eval Dokkit.Release.migrate` brings the database up to date before a start.

**Docker.** `server/Dockerfile` and `server/compose.yml`, with Postgres 17 beside it. Neither has been built or run yet: this was written on a machine with no Docker. The base images are pinned by digest, the image has a health check that speaks plain HTTP, so it reports unhealthy when `DOKKIT_CERT` makes the server serve https, and the server listens on plain HTTP on port 4000 for a proxy that holds the certificate. Compose publishes no port unless a `compose.override.yml` adds one; its `caddy` profile adds a Caddy container that holds the certificate. `PHX_HOST` and a Postgres password of letters and digits (`openssl rand -hex 24`) are required.

**VPS installer.** `server/install.sh` is described under "On a cloud VPS". It has had `bash -n` run on it and nothing else: it has not been run, in either form, Docker is not installed on the machine it was written on, and neither the Dockerfile nor the compose file has been built or validated. The image and dokkit.dev are not published.

**Windows, in one line.** From an administrator PowerShell, `irm https://dokkit.dev/install.ps1 | iex` fetches the newest release and, on a first install, Postgres's own Windows binaries from EnterpriseDB, then runs the installer described next with a Postgres of its own. It applies once a release and the site are published, and it has not been run. Each download is checked against a SHA-256 before anything is unpacked: Postgres against the one written in the script, the release against the `.sha256` file published beside it. `DOKKIT_RELEASE_URL` names another release (with its `.sha256` beside it); `DOKKIT_POSTGRES_URL` names another Postgres and needs `DOKKIT_POSTGRES_SHA256` with it. For any other choice (an existing database, a certificate, another folder), unpack a release and run its `install.ps1` with the settings below.

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

**Who watches Dokkit.** The outside heartbeat is an https address set on the Alerts page. Dokkit's own row is a service called Dokkit with a check that the database answers, a chart of the database's size, a check that goes bad when every enrolled machine has been quiet for ten minutes at once, and, when an archive folder is set, a check that the folder can be written to (it writes an empty file called `.dokkit-write-check` there each minute). It routes to a quiet push.

**The program for machines to fetch.** With `DOKKIT_PROGRAMS` set to a folder holding `version.txt` and files named like `dokkit-windows-amd64.exe`, the Versions page lists the machines behind that version and can ask each to fetch the newer copy.

**Archiving.** With `DOKKIT_ARCHIVE` set to a folder, each log month older than a year is written there as `logs-YYYY-MM.ndjson.gz` and dropped from the database, checked once an hour. `Dokkit.Logs.restore/1` loads a file back. A month whose file is already there is dropped without rewriting the file. Without the setting every month stays.
