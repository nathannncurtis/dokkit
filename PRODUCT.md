# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

The product: a Phoenix server on Postgres, a Go program on each watched machine, client libraries in eleven languages.
The website (dokkit.dev) is not in this repo yet: there is no `site/` folder. The mock of it is `gallery/brand/`.

## Users

People who build their own software, run it, and are the only one watching it: the developer or administrator of a small shop with a few servers, a NAS, a database, nightly jobs and some staff PCs. They are at a desk almost all the time and on a phone only after a page.

Visitors to the website are the same people, deciding whether to install it.

## Product Purpose

One self-hosted place that watches everything a small shop runs and says what needs a look now. It replaces the usual split across an uptime pinger, a log server, an error tracker, per-service stats pages and email.

## Positioning

- The first screen is "this needs your attention", which is not the same as "this is broken".
- An app joins by declaring itself in a `dokkit.toml` in its own repo; nothing is wired in by hand on the server.
- The program on each machine opens no port. Work reaches it over a connection it makes itself.
- Scanning a machine is offered, never required. Nobody is asked to turn off antivirus.
- Runs on a Windows box as a native service as readily as in Docker. Postgres, on your own hardware.

## Operating Context

Checks (http, tcp, process, Windows service, systemd unit, beats, jobs on a schedule, thresholds, expiry dates), job runs, logs kept twelve months live then archived, errors grouped by type and place, versions per machine, deploys, alert rules (page, push, email, iMessage, SMS, digest, webhook), an MCP endpoint with a tool for everything the API can do. A token that can do everything is made only after typing the server address to confirm. Issues have short ids (`DOK-12`) and close by themselves when the check recovers.

## Capabilities and Constraints

- Words: machine, service, check, state, issue, job run, deploy, rule, proposal. The program on each machine is "the `dokkit` program", never an "agent" or "runner".
- Licence: AGPL for the server, Apache 2.0 for the program and the libraries.
- Also accepts reports from Sentry's open-source SDKs. That is a compatibility note, never the pitch: no "alternative to", no price comparison, "not affiliated with Sentry".
- The project hands out no builds signed with anyone's certificate; whoever builds signs their own.
- Not offered: a hosted version, security monitoring, business analytics.

## Brand Commitments

- Name: Dokkit, "docket" respelled. A docket is the list of matters waiting for attention.
- Mark: a D with a dot at its top-left, used exactly as drawn (`gallery/app/app.js`, `LOGO`).
- Colour: Ember, a warm charcoal with one tangerine accent, in the interface's dark theme and on the website. The light theme keeps a teal accent. Accent and dark base are settings a person can change.
- The website is meant to be a scrolling site with a working sample of the interface in it; its mock is `gallery/brand/`.
- The website must not look like Sentry's, or like any other monitoring product's.
- Voice: plain statements, short, no hype.
- The website speaks to the builder as much as the watcher: wiring an app in is part of building it, and an AI tool can be handed the docs and a token.

## Evidence on Hand

- The working interface mock at `gallery/app/` on an invented company (Brightwater). Real screens can be shown; the data is synthetic and says so.
- The docs in `docs/`.
- No customers, testimonials, benchmarks or prices exist. None may be invented.

## Product Principles

1. Say what needs a look, not everything that is known.
2. Nothing privileged listens.
3. The app describes itself; the person decides who is told.
4. Offer, never require.
5. Plain words.
