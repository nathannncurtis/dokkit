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

- **On Windows** the installer takes one of two choices the first time: set up a private Postgres for Dokkit (`-Postgres <folder>`), or use one that already exists (`-DatabaseUrl`, a connection address). The first installs Postgres as its own Windows service, and a later installer given a newer folder keeps it up to date.
- **In Docker** the compose file includes Postgres. A connection address can replace it.

## Backups

Dokkit does not back up its own database. Whoever runs it does, with whatever they already use for Postgres. The plain way is a nightly `pg_dump` to another machine, wrapped in `dokkit run` so the backup shows up as a job like any other.

Dokkit connects with its time zone set to UTC, and a migration re-bounds any log month made under another zone.

Log months older than the live limit (12 months unless changed in Settings under Logs, or by `PUT /api/v1/logs/retention`) are archived as compressed files to a folder that is a setting, or deleted if that is chosen. Those files are the archive, not a backup of the live database.

## First start

The first visit to the interface creates the owner account. It asks for a setup code that the server printed when it started, so nobody else on the network can claim it first.

## Who watches Dokkit

Dokkit cannot page about itself when it is down, so two things cover it:

1. **An outside heartbeat.** Dokkit calls an address every minute. The address is a setting and must be https. Point it at any service that alerts when the calls stop. That also covers the whole site losing power or its connection.
2. **Its own row.** Dokkit watches whether it is taking reports, how full its database is, and whether archiving worked, and shows itself as a service like any other. How that alerts is a choice. The default is a quiet push, and a page only when it can no longer take in or store reports.

## Upgrades

- Windows: run the newer installer over the old one. It stops the service, updates the database, and starts it again. On a machine with the updater installed, the Update button in the interface does this with the signed release.
- Docker: pull the newer image.
- A server works with the `dokkit` program one version behind it, so machines do not have to be updated at the same moment.

## On a cloud VPS

On a fresh Debian or Ubuntu machine whose domain already points at it:

```
curl -fsSL https://dokkit.dev/install.sh | sudo sh -s -- dokkit.example.com
```

That form applies once the site serves the script. It does not yet. The release workflow pushes the image (`ghcr.io/nathannncurtis/dokkit-server:latest`) on every tag. What works today is the same script from a checkout of this repository, which builds the image from the checkout:

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

## Releases

Pushing a tag that starts with `v` runs `.github/workflows/release.yml`. Releases `v0.1.0` to `v0.1.10` exist. It builds and publishes:

- The server image, as `ghcr.io/nathannncurtis/dokkit-server:<version>` and `:latest`.
- The `dokkit` program for Windows, Linux and macOS, each on amd64 and arm64, as release assets named `dokkit-<os>-<arch>` (`.exe` on Windows), each with a `.sha256` file beside it, and `SHA256SUMS` with its Ed25519 signature `SHA256SUMS.sig` listing them all. The signature is made with the repository secret `RELEASE_SIGNING_KEY` and checked once before it is published; without that secret the release has no signature and the updater cannot install it.
- The Windows server as `dokkit-windows-x64.zip` with its `.sha256`, holding `bin\dokkit.bat` and `install.ps1` at the top.

The release is created with a one-line note, and only when all 14 files were built: a build that fails does not fail the run, and the release is then not published. The macOS files are code-signed in the workflow when the repository holds the signing certificate secrets, and are published unsigned with a warning otherwise; the Windows and Linux files are not signed. `.github/workflows/test.yml` runs by hand only (`workflow_dispatch`), not on a push: it runs the server's `mix test` against a Postgres 17 service, and the program's `go vet ./...` and `go test ./...` on Ubuntu and Windows.

## Getting the program

On a machine to watch, Linux or macOS:

```
curl -fsSL https://dokkit.dev/get.sh | sh
```

Windows, in PowerShell, no administrator needed:

```
irm https://dokkit.dev/get.ps1 | iex
```

Each downloads `SHA256SUMS` and `SHA256SUMS.sig` from the latest release, checks the signature against the release key written in the script (OpenSSL 3, else perl, else python3 on Linux and macOS; .NET inside PowerShell on Windows), downloads the right file, checks its SHA-256 against the signed list and installs it, and installs nothing when any of those fail: `/usr/local/bin/dokkit` as root or `~/.local/bin/dokkit` otherwise, and `%LOCALAPPDATA%\Programs\dokkit\dokkit.exe` on Windows, which is added to the user's Path. Then `dokkit enrol <address> <token>`. `DOKKIT_RELEASE_BASE` (or `--from <address>` on Linux and macOS) names another folder that holds the release's files; a Dokkit server that holds the release serves it at `https://<server>/api/v1/releases/<version>`, with `DOKKIT_RELEASE_KEY` set to a machine key or an enrolment token not yet used. The Add a machine page shows the Linux and macOS command.

For Windows the Add a machine page gives one line instead, `irm https://<server>/add/<token> | iex`, to paste in a PowerShell opened as administrator, and the same script as a file, `dokkit-add-<name>.ps1`, for a machine where the line cannot be used (a server whose certificate Windows does not trust, or one whose security software blocks downloaded scripts). Neither needs anything from dokkit.dev. The address hands out the script only while its token is unused. It holds the server's address, the certificate fingerprint when one is needed, the newest release the server holds and a one-use enrolment token that runs out in 24 hours. Run from a PowerShell opened as administrator (`powershell -ExecutionPolicy Bypass -File .\dokkit-add-<name>.ps1`), it fetches the program from the server with that token, checks the release signature and the file's SHA-256 as `get.ps1` does, enrols, runs `dokkit service install` and `dokkit updater install`, runs `dokkit doctor` against the installed service, and then offers to delete itself. On a machine that already has the service it only installs the updater and checks. With `-Check` it only downloads and checks, needs no administrator and spends nothing. `POST /api/v1/add-script` makes the same script.

dokkit.dev does not serve them yet, so neither has been run from there.

## Serving the scripts

`install.sh`, `install.ps1`, `compose.yml`, `get.sh` and `get.ps1` must be served from the root of dokkit.dev. dokkit.dev does not serve them yet, so none of the commands above work until it does.

## Reaching it

Its own usernames and passwords. It is meant for a local network or a private overlay network, and is not meant to be exposed to the internet.

## Built so far

**The packaged server.** `mix release` in `server/` builds it, and it has been started and stopped on Windows that way. It reads `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` and `PORT`, and `bin/dokkit eval Dokkit.Release.migrate` brings the database up to date before a start.

**Docker.** `server/Dockerfile` and `server/compose.yml`, with Postgres 17 beside it. The release workflow builds the image on a tag; no container has been run from it, and the compose file has not been run. The base images are pinned by digest, the image has a health check that speaks plain HTTP, so it reports unhealthy when `DOKKIT_CERT` makes the server serve https, and the server listens on plain HTTP on port 4000 for a proxy that holds the certificate. Compose publishes no port unless a `compose.override.yml` adds one; its `caddy` profile adds a Caddy container that holds the certificate. `PHX_HOST` and a Postgres password of letters and digits (`openssl rand -hex 24`) are required.

**VPS installer.** `server/install.sh` is described under "On a cloud VPS". It has had `bash -n` run on it and nothing else: it has not been run, in either form, and the compose file has not been validated. dokkit.dev does not serve it.

**Windows, in one line.** From an administrator PowerShell, `irm https://dokkit.dev/install.ps1 | iex` fetches the newest release and, on a first install, Postgres's own Windows binaries from EnterpriseDB, then runs the installer described next with a Postgres of its own. It applies once the site serves the script, and it has not been run from there. Each download is checked against a SHA-256 before anything is unpacked: Postgres against the one written in the script, the release against the SHA-256 in `SHA256SUMS`, which must carry a valid signature from the release key, fetched from the same folder as the zip. `DOKKIT_RELEASE_URL` names another release's zip (with `SHA256SUMS` and `SHA256SUMS.sig` in its folder, and `DOKKIT_RELEASE_KEY` for a server that needs a key); `DOKKIT_POSTGRES_URL` names another Postgres and needs `DOKKIT_POSTGRES_SHA256` with it. For any other choice (an existing database, a certificate, another folder), unpack a release and run its `install.ps1` with the settings below.

**Windows.** `install.ps1` ships in the release folder and is run from an administrator PowerShell. It copies the server to `Program Files\Dokkit`, writes its settings to `ProgramData\Dokkit\settings.env` where only administrators and the system account can read them, brings the database up to date, and registers and starts a Windows service. The server reads that settings file itself, because a Windows service is not started through a script that could set variables.
 The program's own Windows service keeps to `Program Files\DokkitProgram` and `ProgramData\DokkitProgram`, so both can be installed on one machine in either order. `install.ps1` refuses, and changes nothing, when `ProgramData\Dokkit` holds a program installed by an older release and no server: run `service update` from a current copy of the program, which moves it, then delete the old `config.json`, `spool`, `dokkit.log` and `dokkit.exe` and run the installer again.

The database is one of two, chosen the first time:

- `.\install.ps1 -Postgres <folder>` sets up a Postgres for Dokkit alone. The folder is Postgres's unpacked Windows binaries, the one holding `bin\initdb.exe`. It becomes a Windows service called `dokkit-postgres` that runs as Network Service, keeps its data in `ProgramData\Dokkit\pgdata`, and listens on this machine only, on port 54329.
- `.\install.ps1 -DatabaseUrl 'ecto://user:password@host/dokkit'` uses a Postgres that is already there.

Run again from a newer release with no arguments, it stops the service, copies, updates the database, registers the service again with the new paths and starts it. Settings that were given before are kept; any given again replace them. Given `-Postgres` again with a newer folder, it also stops Dokkit's Postgres, puts the newer binaries in place and starts it. It refuses a folder of a different major version of Postgres, which needs a dump and a restore.

Releases for the updaters are kept in a `releases` folder beside `settings.env`, one folder per version, so `ProgramData\Dokkit\releases` on Windows; the installer makes it writable by the service only. `DOKKIT_RELEASES` names another place, and the folder is made when the first file arrives. In development and tests it is a folder under the system temporary directory.

The service runs as Local Service, starts with Windows after `dokkit-postgres`, and Erlang's service wrapper restarts it if it stops. It reads its settings from `ProgramData\Dokkit\settings.env` and writes its log to `ProgramData\Dokkit\log\dokkit.log`, a folder only administrators, the system account and Local Service can reach; the installer prints the setup code from it. The Erlang node's distribution port listens on this machine only, and its cookie is made at install time; it is kept in a file and in the service's registry key, both readable by administrators, the system account and Local Service only. The Erlang port mapper (port 4369) listens on every interface, so a firewall should keep it closed. The installer refuses a `ProgramData\Dokkit` folder that is owned by anyone but administrators. A folder given as `-Archive` is created and made writable by Local Service. With `-Cert`, the installer adds a Windows Firewall rule named Dokkit that lets the port in.

`-Cert` and `-CertKey` are a certificate and its key as PEM files. The installer copies them into `ProgramData\Dokkit` and the server serves https itself on the port. Without them it serves plain HTTP, and any machine but this one is sent to https, so it needs a certificate or a proxy that holds one.

`settings.env` may start with a byte order mark and may have spaces after values; both are ignored. `PHX_HOST` is required.

`install.ps1` has been run on a real Windows machine.

**Its own TLS.** With `DOKKIT_CERT` and `DOKKIT_CERT_KEY` set to a certificate and its key, the server serves HTTPS itself and the enrol page shows the fingerprint for machines to pin.

A second certificate, for a real name with a publicly trusted certificate, can be put in place with `PUT /api/v1/certificate` or in Settings under Certificate, with no restart and nothing to run on the server. The server serves it to clients that ask for one of its names (a name it covers, or a `*.` wildcard for one label) and serves the installed certificate to every other client, including one that connects by address, so machines pinned to the first certificate are not affected. The files are kept in the `tls` folder beside the settings (`DOKKIT_TLS` names another place). Once there is one, its first name is the address Dokkit shows and links to, the enrol command carries no fingerprint when that name is covered by a certificate that is not self-signed, and Dokkit's own row warns 21 days before it runs out.

**Renewing it by itself.** With a name (`acme_name`) and a Cloudflare API token that may edit DNS in the name's zone (`acme_cloudflare_token`) set in Settings under Certificate, or through `PUT /api/v1/certificate/settings`, the server gets the certificate itself from Let's Encrypt and renews it when 30 days or fewer are left. It proves the name with a TXT record at `_acme-challenge.<name>`, which it adds at Cloudflare, waits to see through Cloudflare's own DNS, and removes again whatever happens. The account key is kept in the `tls` folder. Once a day it checks; after a failure it tries again no sooner than twelve hours later, and the failure shows beside the settings, in `GET /api/v1/certificate` and on Dokkit's own row. **Get a certificate now** does it at once. `acme_directory` points it at Let's Encrypt's staging directory (`https://acme-staging-v02.api.letsencrypt.org/directory`) to try it out. The server needs to reach `api.cloudflare.com`, `cloudflare-dns.com` and the directory over https.

**Who watches Dokkit.** The outside heartbeat is an https address set on the Alerts page. Dokkit's own row is a service called Dokkit with a check that the database answers, a chart of the database's size, a check that goes bad when every enrolled machine has been quiet for ten minutes at once, and, when an archive folder is set, a check that the folder can be written to (it writes an empty file called `.dokkit-write-check` there each minute). It routes to a quiet push.

**The program for machines to fetch.** With `DOKKIT_PROGRAMS` set to a folder holding `version.txt` and files named like `dokkit-windows-amd64.exe`, the Versions page lists the machines behind that version and can ask each to fetch the newer copy. The file is only fetched; finishing the update on the machine is what the updater does (see below).

**Updates.** Releases for the updater are put on the server with `PUT /api/v1/releases/<version>/<file>`, and the interface's Update and Update all buttons approve a version for a machine. The updater runs on Windows, Linux, macOS and a QNAP NAS.

**Archiving.** With `DOKKIT_ARCHIVE` set to a folder, each log month older than the live limit (12 months unless changed) is written there as `logs-YYYY-MM.ndjson.gz` and dropped from the database, checked once an hour. With the setting `delete`, the month is dropped with no file and no folder is needed; files already there stay and can be loaded back. `Dokkit.Logs.restore/1` loads a file back. A month whose file is already there is dropped without rewriting the file. Without the setting every month stays.
