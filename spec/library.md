# The client library

For what only the app knows about itself. The same five things in every language, with the same names.

| Call | Gives |
|---|---|
| `beat("name")` | The app calls it from its main loop or worker. If the beats stop while the process is still up, the service is stuck but alive, which nothing outside the app can see. |
| `job("name")` | Start, finish, failure, and progress such as "4,000 of 9,000". |
| `check("name", state, value, note)` | The app's own checks, for example "the oldest item in the queue is 14 minutes old". |
| `capture(error)` | Sends an error in the format in `errors.md`. Can also catch unhandled errors if asked to. |
| A log handler | Plugs into the language's normal logging. Optional: writing lines to a file for `dokkit` to read works just as well. |

It can also send the stats document (`stats-v1.md`) itself, for an app `dokkit` cannot reach, such as a desktop app or a phone app. There is one stats format and two ways to deliver it: `dokkit` fetches it, or the library sends it.

## Rules

- **Blank configuration means off.** With no address set, every call does nothing.
- **It never breaks or slows the app it lives in.** Sending happens in the background. A failure to send is dropped, never raised.
- **It uses a fixed amount of memory.** A full queue drops the oldest and counts what it dropped.
- **It sends no personal data by default.** No error message text, no request contents, no user records.

## Configuration

Two environment variables:

| Variable | Holds |
|---|---|
| `DOKKIT_URL` | The server address. |
| `DOKKIT_KEY` | An app key. |

The service's id and version come from the app key and from what the app passes at start.

## Machines with no `dokkit`

An app using the library reports its host name. The host shows up in Dokkit as a machine of the `seen` kind, with its last-seen time, the app's version on it, and its errors. This is how staff PCs become rows without installing anything extra on them.

## Languages

Python, C#, JavaScript, Go, Elixir, Rust, Java, PHP, PowerShell, shell and Swift. Any other language can use the plain API or the ping URLs in `api.md` until it has a library.

## Built so far

`clients/python/dokkit.py`: one file, standard library only. `start`, `beat`, `job`, `check`, `metric`, `stats`, `capture`, `catch_unhandled` and `handler` for the logging module.

`clients/dotnet/Dokkit/Dokkit.cs`: one file for .NET Standard 2.0, no packages. `Start`, `Beat`, `Job`, `Check`, `Metric`, `Stats`, `Log`, `Capture` and `CatchUnhandled`. It has no provider for `Microsoft.Extensions.Logging` yet; an app that writes Serilog's compact format to a file can have `dokkit` read it.

`clients/javascript/dokkit.js`: one file, no packages, for Node 18 or later and for browsers. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `catchUnhandled`. `dokkit.d.ts` beside it gives TypeScript the types.

`clients/go/dokkit.go`: one file, standard library only. `Start`, `Beat`, `Job`, `Check`, `Metric`, `Stats`, `Log`, `Capture`, `Recover` for panics, and `Handler` for `log/slog`. Go keeps no stack with an error, so a report carries the stack of the place that reported it.

`clients/elixir/lib/dokkit.ex`: one file, no packages, Elixir 1.18 or later. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture`, and the module is itself a `:logger` handler.

`clients/rust/src/lib.rs`: one file and one package, `ureq`, for HTTPS. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `catch_unhandled` for panics. A report carries one frame, the file and line that reported it, and lines carry no time of their own: the server stamps them when they arrive.

`clients/java/Dokkit.java`: one file, no packages, Java 11 or later. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture`, `catchUnhandled`, and `handler` for `java.util.logging`. Kotlin and Scala use it as it is.

`clients/php/Dokkit.php`: one file, no packages or extensions, PHP 8.0 or later. `Dokkit::start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `catchUnhandled`. PHP has no background thread, so lines are sent when the request or script ends, after the response has gone out where PHP allows it.

`clients/powershell/Dokkit.psm1`: one file, for Windows PowerShell 5.1 and PowerShell 7. `Start-Dokkit`, `Send-DokkitBeat`, `Invoke-DokkitJob`, `Send-DokkitProgress`, `Send-DokkitCheck`, `Send-DokkitMetric`, `Write-DokkitLog`, `Send-DokkitError` and `Send-Dokkit`. Lines are sent when a job ends or when `Send-Dokkit` is called.

`clients/shell/dokkit.sh`: one file to source, needing only curl. `dokkit_beat`, `dokkit_job`, `dokkit_check`, `dokkit_metric` and `dokkit_log`. Each call sends its one line straight away and waits at most five seconds. It does not report errors; a failed job carries its exit code.

`clients/swift/Dokkit.swift`: one file, Foundation only, for iOS 13 and macOS 10.15 or later. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `flush`. Swift keeps no stack with an error, so a report carries the stack of the place that reported it. It has not been compiled or run yet.

All of them send the host name, and the server records that host as a machine that was seen. When that host is not the machine the service lives on, the version the app starts with is kept for that host and is not a deploy, and the Versions page lists each such app with how many hosts are on each version.
