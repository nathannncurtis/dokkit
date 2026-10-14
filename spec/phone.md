# The phone app

A read-only view of a Dokkit server on an iPhone or an Android phone, for a server that is not on the internet. Nothing here is built yet. This is the contract to build against.

## What it is and is not

- The Dokkit server stays where it is: on a local network, never exposed publicly.
- The app reads. It shows what needs attention and the state of every machine and service. It cannot snooze, acknowledge, start planned downtime or change anything. Anything that changes something is done in the web interface.
- The app sends no notifications. Alerts keep going out through the channels in `alerts.md` (a page, a push, an email and the rest).
- The project runs no service for anyone. Each person who wants the app runs their own relay.

## The words

| Word | Meaning |
|---|---|
| **Relay** | A small program on a public host that holds the newest snapshot for a server and hands it to that server's phones. It is one more mode of the `dokkit` program. |
| **Mailbox** | One server's place on a relay. A relay can hold several. |
| **Snapshot** | What the app shows, written by the server about once a minute and sealed before it leaves. |
| **Phone** | One paired device. Each has its own key and its own slot in the mailbox. |
| **Pairing** | Giving a phone its key, by a QR code shown once in the web interface. |

## One direction

Data only leaves the server. The server makes an outbound HTTPS request to the relay to upload a snapshot. A phone makes an outbound HTTPS request to the relay to download it. No request from a phone or from the relay ever reaches the Dokkit server, so a lost phone, a taken-over relay or a fault in the app can at most read snapshots. None of them can ask the server anything.

The only things that come back to the server are the relay's answer to an upload: a status, and for each slot the time it was last fetched.

Because nothing is asked on demand, the app answers no question the snapshot was not packed for. Searching logs and a service's full history stay in the web interface. When the server or its network is down, the app still shows the last snapshot and how old it is.

## Sealing

The relay holds only what it cannot open.

- Each phone has one key: 32 random bytes made by the server at pairing. The server keeps it (encrypted with the server's own secret, like other stored secrets) and the phone keeps it in the system key store (Keychain on iOS, Keystore on Android), set so it is not included in backups and is not readable while the phone is locked before first unlock.
- For each snapshot the server makes a fresh 32-byte content key, compresses the snapshot JSON with gzip, and encrypts it with AES-256-GCM under the content key with a random 12-byte nonce.
- For each phone it encrypts the content key with AES-256-GCM under that phone's key, with its own random nonce. The additional data for both encryptions is the mailbox id, the slot id and the snapshot's counter, so a sealed part cannot be moved to another mailbox, slot or time.
- A phone opens its own wrapped content key, then the body. A body that does not open is treated as no snapshot. The relay has no key, so it cannot read a snapshot or make one a phone will accept.
- Every snapshot carries a counter that only goes up. A phone refuses a snapshot whose counter is lower than the newest it has opened, so an old one cannot be played back to it.

Only primitives every platform ships are used: AES-256-GCM and a random source. Neither app needs a cryptography library of its own.

## The relay

`dokkit relay` is a mode of the `dokkit` program. It is the one mode that listens on a port. It runs under an ordinary account on a public host, apart from any `dokkit watch`, and holds nothing but sealed files.

| Command | What it does |
|---|---|
| `dokkit relay add <name>` | Makes a mailbox. Prints its address and its upload key, once. The name is only a label on the relay's host. |
| `dokkit relay list`, `dokkit relay remove <name>` | Shows the mailboxes with the time of the last upload and each slot's last fetch; removes one and its file. |
| `dokkit relay serve --name relay.example.com` | Serves on 443 with a certificate it gets and renews itself from Let's Encrypt for that name. |
| `dokkit relay serve --http 127.0.0.1:8080` | Serves plain HTTP for a reverse proxy that already has the certificate. |

Mailboxes exist only when made on the relay's host. There is no sign-up call.

### Keys

| Key | Prefix | Held by | Can do |
|---|---|---|---|
| Upload key | `dkr_` | The Dokkit server | Replace that mailbox's snapshot. |
| Fetch token | `dkf_` | One phone | Download that phone's slot of that mailbox. |

Both follow the rules for keys in `api.md`: a recognisable prefix, a checksum, shown once. The relay stores a hash of the upload key. Fetch tokens are made by the server; the relay only ever sees their hashes, inside an upload.

### Calls

| Call | Who | What |
|---|---|---|
| `PUT /m/<mailbox>` | Upload key | The body is one snapshot envelope (below), at most 2 MB. Replaces the one held, atomically. Refused with `409` when its counter is not higher than the one held. Answers `{"ok": true, "slots": {"<slot>": "<last fetch time or null>"}}`. |
| `GET /m/<mailbox>/<slot>` | That slot's fetch token | That slot's part of the envelope: the counter, the wrapped content key and the sealed body. Sends an `ETag` that is the counter, and answers `304` to `If-None-Match` with the same one. `404` when the mailbox, the slot or the token is not known, with no difference between them. |

Everything else answers `404`. A mailbox takes at most 4 uploads a minute and a slot at most 30 fetches a minute; more answers `429` with `Retry-After`.

### The envelope

```json
{
  "schema": 1,
  "counter": 184223,
  "made_at": "2026-10-14T03:20:00Z",
  "slots": {
    "<slot id>": {"token_sha256": "<hex>", "nonce": "<base64>", "key": "<base64, the wrapped content key>"}
  },
  "nonce": "<base64>",
  "body": "<base64, the sealed snapshot>"
}
```

A slot that is not in the newest envelope no longer exists: its token stops working at that upload.

The relay keeps one envelope per mailbox, in a file, and its own access log (time, mailbox, slot, status). It keeps no history of snapshots.

## The server

Settings gets a **Phones** section, for the owner.

- **The relay**: its address and the upload key from `dokkit relay add`. Saving it makes one upload and says whether the relay took it.
- **Add a phone**: asks for a name ("Work iPhone") and shows a QR code once, for two minutes. The code holds the relay's address, the mailbox id, the slot id, the fetch token and the phone's key. Nothing else pairs a phone: the server never learns whether the code was scanned except by the slot's first fetch.
- **The phones**: each with its name, when it was added, when it last fetched, and Remove. Remove drops the slot from the next upload, which is made at once.
- Changing the relay's address or upload key keeps the phones only when the mailbox is the same one; otherwise each phone is paired again.

The server uploads once a minute, in the sweep it already runs, and at once when an issue opens or closes. An upload is skipped while no phone is paired. When uploads have failed for five minutes, Dokkit's own row says so at the level of its lesser troubles (`self_degraded`), with the relay's answer.

The API has the same three things under `admin`: `GET /phones`, `POST /phones` (answers the QR's contents, once) and `DELETE /phones/<id>`, and `GET`/`PUT /phones/relay`. Like keys and people, adding a phone is not offered through the MCP.

## The snapshot

JSON, built from the same server code as the web interface, with `schema: 1` and room to grow by adding fields.

| Part | Holds |
|---|---|
| `server` | Its name, its version, `made_at` and the counter. |
| `inbox` | What the first screen shows: Needs you, Soon, Snoozed and Not watched, each issue with its short id, title, service, machine, state, since-time, count, whether it is snoozed or seen, and whether its alert is held for the night. |
| `machines` | Each with its state, last-seen time, its vitals (processor, memory, each disk), planned downtime now and the next scheduled window. |
| `services` | Each with its machine, kind, state, version, environment, its checks with their last result and note, and the last 24 hourly points of the chart its row shows. |
| `issues` | Each open issue's history: the last 20 events (opened, alerted, snoozed, noted, closed) with their times and notes. |
| `jobs` | Each with its schedule, last run, last good run and next expected run. |
| `logs` | For each service with an open issue, its last 20 log lines, as the Logs page shows them. |

It holds no keys, no people's destinations and no settings. Log lines travel as they were stored, with whatever customer and job details they carry.

## The apps

Two native apps, one in Swift for iOS and one in Kotlin for Android, with the same screens. Their source is in this repository. The project publishes neither in a store: whoever uses the app builds it and signs it with their own account, as with the `dokkit` program.

| Screen | Shows |
|---|---|
| **Needs you** | The inbox, in the web interface's order, with the age of the snapshot at the top. |
| **Everything** | Machines, each opening to its services, with state and the small chart. |
| **A service** | Its checks, version, open issue with its history, its day chart, and its last log lines while it has an open issue. |
| **Servers** | The paired servers, and Add a server, which opens the camera for a QR code. |

Rules for both:

- Read-only. There is no control that changes anything on the server.
- The app fetches when it is opened, when the screen is pulled down, and every 30 seconds while it is in front. It does nothing in the background.
- The age of the snapshot is always on screen. Past five minutes it is shown as a warning, since the server, its network or the relay is not delivering.
- Several servers can be paired, each with its own relay.
- The last snapshot of each server is kept on the phone, encrypted by the system, and removed when the server is removed from the app.
- Opening the app asks for the phone's own unlock (Face ID, fingerprint or passcode).
- No account, no analytics, no crash reporting to a third party, no network request to anything but the paired relays.
- Light and dark, following the phone, in the product's own colours.

## Losing a phone

Remove it under Phones. The next upload, made at once, has no slot for it: its token stops working and no later snapshot is sealed to its key. Snapshots it already downloaded stay readable on that phone, log lines included, which is why a snapshot holds no keys or settings.

## Not in this version

- Anything asked on demand: log search, a service's full history, job output.
- Actions of any kind.
- Notifications from the app.
- A relay run by the project, and storage buckets as a relay.
- Builds in the App Store or Play Store.
