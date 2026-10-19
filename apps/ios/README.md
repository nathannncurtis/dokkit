# Dokkit for iPhone

A read-only view of a Dokkit server, for a server that is not on the internet. It shows what needs attention and the state of every machine and service, from the sealed snapshots a relay holds. It cannot change anything on the server and sends no notifications.

The app is not on the App Store yet. Until it is, you build it and sign it with your own Apple account.

## Build and install

You need a Mac with Xcode 16 or later, an iPhone on iOS 17 or later, and an Apple ID.

1. Install XcodeGen: `brew install xcodegen`.
2. In this folder run `xcodegen generate`. It writes `Dokkit.xcodeproj`.
3. Open `Dokkit.xcodeproj` in Xcode.
4. Select the Dokkit target, then Signing & Capabilities. Choose your Team (your Apple ID works) and change the bundle identifier from `dev.dokkit.phone` to one of your own, such as `com.yourname.dokkit`. Or, before step 2, put both in a file `Local.xcconfig` in this folder, as `DEVELOPMENT_TEAM = ...` and `PRODUCT_BUNDLE_IDENTIFIER = ...`. Git ignores that file and it survives `xcodegen generate`.
5. On the iPhone turn on Developer Mode (Settings, Privacy & Security, Developer Mode) and connect it to the Mac.
6. Choose the iPhone as the run destination and press Run.
7. The first time, trust your developer profile on the phone (Settings, General, VPN & Device Management).

An app signed with a free Apple ID stops opening after seven days. Run it from Xcode again to renew it. A paid developer account lasts a year.

## Pair it

1. In the Dokkit web interface open Settings, Phones, Add a phone. A QR code is shown once, for two minutes.
2. In the app choose Servers, Add a server, and point the camera at it. If the camera is off, paste the code into the box under it.

Several servers can be paired. Remove one from Servers and its key, token and saved snapshot are deleted from the phone.

## What is in this folder

| Path | What |
|---|---|
| `DokkitKit/` | Swift package. `DokkitKit` holds everything that is not a screen: snapshot models, opening a sealed snapshot, pairing codes, the relay client, the Keychain and file stores, and what each screen shows. `DokkitUI` holds the SwiftUI screens. |
| `Dokkit/` | The app: `@main`, `Info.plist`, the camera scanner, the unlock gate, assets. |
| `project.yml` | XcodeGen description of the app target. |
| `sync-fixtures.sh` | Copies the spec's test fixtures into the package. |

## Checks

`DokkitKit/Tests/DokkitChecks` is a command-line program that opens the spec's sealed snapshots, refuses what must be refused, decodes the example snapshot, and exercises the relay client and the stores against a stub. It runs on a Mac with Swift 6 and needs no Xcode:

```
cd DokkitKit
swift run DokkitChecks
```

It exits non-zero when a check fails. The fixtures it reads are copies of `spec/phone-cases/sealing.json` and `snapshot.json`. Run `./sync-fixtures.sh` after the spec's fixtures change.

## What the app does and does not do

- Fetches when opened, when the screen is pulled down, and every 30 seconds while in front. Nothing runs in the background.
- Shows the age of the snapshot at the top of each screen; past five minutes it is a warning. With no network, or when the relay answers an error, the last snapshot stays on screen and the message says what happened.
- Refuses a snapshot whose counter is lower than the newest it has opened.
- Asks for Face ID or the passcode on every launch and every return from the background.
- Keeps the phone key and fetch token in the Keychain (after first unlock, this device only, not synchronised) and the last snapshot in a file protected until first unlock and excluded from backup.
- Contacts only the paired relays, over https. No account, analytics, crash reporting or third-party packages.
- Uses the system fonts, so Dynamic Type works everywhere.
