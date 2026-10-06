# Dokkit for JavaScript

One file, no packages, for Node 18 or later and for browsers. `beat`, `job`, `check`, `capture`, `log`. Types are in `dokkit.d.ts`.

## Install

Nothing is published to a registry yet. Install from a clone of the repo:

```
npm install path/to/dokkit/clients/javascript
```

## Logging

JavaScript has no logging framework, only `console`. `dokkit.patchConsole()` makes `console.log`, `info`, `debug`, `warn`, `error` and `trace` also go through `log`, and returns a function that puts the console back. `dokkit.consoleLogger()` returns a wrapped console and leaves the global one alone. Both are off until called.

## Test

`npm test`
