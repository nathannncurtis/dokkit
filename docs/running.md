# Running the server

This is how it is meant to work. So far the server runs from its source (see the README), signs people in with the setup code described below, and is not yet packaged as a Windows service or a Docker image. The outside heartbeat and its own row are not built yet.

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
