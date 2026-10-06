# Dokkit for Swift

One file, Foundation only, for iOS 13 and macOS 10.15 or later. `Dokkit.beat`, `job`, `check`, `capture`, `log`. It has not been compiled or run yet.

## Install

Nothing is published to a registry yet. Add a local package from a clone of the repo:

```
.package(path: "path/to/dokkit/clients/swift")
```

## Logging

There is no log handler. Swift's logging frameworks are packages (swift-log), and the library takes no dependency. Call `Dokkit.log` directly.
