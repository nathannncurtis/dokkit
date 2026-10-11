# Dokkit for Swift

One file, Foundation only, for iOS 13 and macOS 10.15 or later. `Dokkit.beat`, `job`, `check`, `capture`, `log`. It builds with Swift 6.4 on macOS.

## Install

Nothing is published to a registry yet. Add a local package from a clone of the repo:

```
.package(path: "path/to/dokkit/clients/swift")
```

## Logging

There is no log handler. Swift's logging frameworks are packages (swift-log), and the library takes no dependency. Call `Dokkit.log` directly. The library logs nothing of its own, so nothing it does can be queued back into itself.

## Options

- `announceVersion: false` on `start` keeps the one deploy line (sent once per process, in the background) from being sent. The server records a deploy only when the version changes.
- `environment` (or `DOKKIT_ENV`), when set and not `production`, goes on every line sent. Unset or `production` adds nothing.
- A line over 65,536 bytes is cut: its message is shortened and ends with ` [cut]`. A line with no message to cut (a very large stats document) is dropped and counted in `Dokkit.dropped`.
- A failed error report (network error, timeout, 5xx, 429) is kept and sent again on the next pass, up to 100; a refusal (other 4xx) is dropped and counted. Error reports and log lines are sent independently.
- Error frames carry the image name, the function and whether it is the app's own, never a file path.
- Report bodies are sent plain. Foundation has no public gzip call on every platform.

## Tests

`swift test` runs `Tests/DokkitTests` against a stub registered on the URL loading system, which needs XCTest (Xcode, not the command line tools alone).
