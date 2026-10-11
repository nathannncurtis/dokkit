# Dokkit for JavaScript

One file, no packages, for Node 18 or later and for browsers. `beat`, `job`, `check`, `capture`, `log`. Types are in `dokkit.d.ts`.

## Install

Nothing is published to a registry yet. Install from a clone of the repo:

```
npm install path/to/dokkit/clients/javascript
```

## Start

`start({ version })` sends one `deploy` line per process, in the background; `announceVersion: false` turns it off. The server records a deploy only when the version changes. A non-production `environment` (option or `DOKKIT_ENV`) is put on every line. A line over 64 KB (bytes) loses its fields and has its `msg` cut, ending in ` [cut]`. Report bodies are gzipped where `CompressionStream` exists (Node 18 and current browsers), plain otherwise. Stack paths are relative to the working folder; files outside it carry only their name, or what follows `node_modules`.

## Logging

JavaScript has no logging framework, only `console`. `dokkit.patchConsole()` makes `console.log`, `info`, `debug`, `warn`, `error` and `trace` also go through `log`, and returns a function that puts the console back. `dokkit.consoleLogger()` returns a wrapped console and leaves the global one alone. Both are off until called. An argument is cut at 2000 characters and 200 keys while it is written, so a large object in a hot path is never serialised whole. Console calls made while the library's own request is being started are not queued.

## Test

`npm test`
