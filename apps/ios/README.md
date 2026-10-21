# Dokkit for iPhone

A read-only view of a Dokkit server, for a server that is not on the internet. It shows what needs attention and the state of every machine and service, from the sealed snapshots a relay holds. It cannot change anything on the server and sends no notifications.

The app is not on the App Store yet. Until it is, you build it and sign it with your own Apple account.

## Build and install

You need a Mac with Xcode 16 or later, an iPhone on iOS 17 or later, and an Apple ID. Build with Xcode 27.1 or later for the foldable layout below; an older Xcode builds the app without it.

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

## On a foldable

On the iPhone Duo the app follows how the phone is held.

- Folded, or open and turned 90°, it is the phone app at full width.
- Open like a book, it spreads across both pages as one app: one bar and one background over the fold, the tab's own page on the left and what it opened on the right. Home leads with the top issue on the right, or the last day and machines when everything is fine. Servers shows the chosen server's details on the right; Settings shows the groups on the left and the open group on the right.
- Where the fold and the camera sit comes from the system, so nothing is placed on the fold or under the camera.
- It rotates on a foldable only; every other iPhone stays portrait. It is the same build for every iPhone: pages are laid out by the window's size, not by the model.

Folding or unfolding does not count as leaving the app, so it does not ask to unlock again.

## Look at it without a server

Debug builds carry a made-up relay at `demo.dokkit.invalid` that seals a demo snapshot the way a server does, so the real pairing and opening code runs. Two demo servers can be paired by pasting `NORTHWIND_CODE` or `HARBOR_LAB_CODE` from `Dokkit/Debug/DemoRelay.swift`: "northwind" has things that need you, "harbor-lab" is the same estate with everything fine.

Debug builds also take launch arguments, so a simulator can be walked through every screen without typing:

| Argument | What |
|---|---|
| `-dokkitDemo YES` | Pairs both demo servers. |
| `-dokkitRoute home/machine/db-01` | Opens a screen: `home`, `home/service/<id>`, `home/machine/<id>`, `home/picking`, `home/first`, `servers`, `servers/add`, `servers/paste`, `settings/<group>`. Add `@harbor-lab` to show that server. |
| `-dokkitShowLock YES` | Shows the lock screen without asking to unlock. |

For example: `xcrun simctl launch booted to.nathancurtis.dokkit -dokkitDemo YES -dokkitRoute home/service/s-purge`. None of this is in a release build.

## What is in this folder

| Path | What |
|---|---|
| `DokkitKit/` | Swift package. `DokkitKit` holds everything that is not a screen: snapshot models, opening a sealed snapshot, pairing codes, the relay client, the Keychain and file stores, and what each screen shows. `DokkitUI` holds the SwiftUI screens. |
| `Dokkit/` | The app: `@main`, `Info.plist`, the camera scanner, the unlock gate, assets. `Dokkit/Debug/` is the demo relay and its snapshots, left out of release builds. |
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
- Asks for Face ID, Touch ID or the passcode, whichever the phone has, on every launch and every return from the background.
- Has a Settings tab for what it used to hard-code: the theme, how often it fetches, when a snapshot counts as late, when a meter turns amber, how many fine services a machine lists, the relay timeout and when to ask to unlock. Each shows the value the app always used as its default, with a Reset; they apply to this phone only.
- Keeps the phone key and fetch token in the Keychain (after first unlock, this device only, not synchronised) and the last snapshot in a file protected until first unlock and excluded from backup.
- Contacts only the paired relays, over https. No account, analytics, crash reporting or third-party packages.
- Uses Figtree, bundled under the SIL Open Font License, sized with Dynamic Type, and Phosphor icons, bundled under the MIT licence. Light and dark follow the phone unless the theme in Settings says otherwise; a chosen theme applies from launch, the lock screen included.
