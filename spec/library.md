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
- **It uses a fixed amount of memory.** A full queue drops the oldest and counts what it dropped. The queue is bounded by bytes as well as by lines. A batch that fails to send is kept for one more try with the same batch id, and counted as dropped if that fails too.
- **It sends no personal data by default.** No error message text, no request contents, no user records.
- **It does not send secrets in the clear.** An `http://` address to a host other than this machine keeps the library off, with one line to stderr, unless `DOKKIT_INSECURE=1` is set. The server must use a certificate the machine already trusts; libraries do not pin certificates.
- **Stack frames carry paths relative to the app's folder.** Files outside it carry only their name, or the part after `site-packages`, `node_modules` or `vendor`. Where a language has no app folder, the working directory stands in (Rust, Go, JavaScript) or frames carry no path (Java and .NET send the type and method, Swift the module and symbol, shell no stack); each README says which.
- **A line is at most 64 KB.** A longer line is cut by the library, never sent whole: `msg` is shortened and ends with ` [cut]`, and if the line is still too long its `fields` are dropped. A line without `msg` that is still too long is dropped and counted.
- **A failed error report is kept and retried.** An error post that gets no answer, a 5xx or a 429 stays queued (at most 100) and is tried again on the next pass; any other 4xx is dropped and counted. Error reports and log batches are separate: a failure of one never stops the other from being sent in the same pass, and the order between them does not matter. The shell library repeats an error post only when the connection could not be made, because a timeout or a 5xx may have stored it.
- **The library's own sending is never logged back into itself.** Whatever its HTTP client logs while it sends is not queued by its log handler or console patch.
- **Report bodies are gzip-compressed** (`Content-Encoding: gzip`) wherever the platform's standard library can do it: Python, .NET, Go, Elixir, Java, JavaScript (where `CompressionStream` exists), PowerShell, PHP (with zlib) and shell (with `gzip`). Rust (`ureq` 2 would need a direct compression dependency) and Swift (Foundation has no gzip) send plain bodies.
- **The environment goes on every line.** When an environment is set (the `environment` start option or `DOKKIT_ENV`) and is not `production`, every line carries `environment`, as the server reads it: a missing or `production` value reaches the key's own service, any other value reaches a sibling service that never alerts. When it is unset or `production`, nothing extra is sent. Error reports carry `environment` as before.
- **Dropped lines are counted and reported.** The Python library counts every dropped line and error report under its lock and, when the count has grown, sends one `metric` line named `dokkit_dropped` with the running total. The other libraries keep the count (where they have one) without sending it.

## The deploy line

`start` with a version sends a `deploy` line with that version, once per process, from the background sender: `start` never waits for it and nothing retries it on its own. The server records a deploy only when the version differs from the service's current one: a line with the same version changes nothing and writes no row (`Dokkit.Deploys.record/3`), and for an app reporting from a host other than its service's machine the line only updates that host's installed version (`Dokkit.Deploys.installed/4`, one row per service and machine). A short-lived tool that starts hundreds of times a day therefore adds no deploy records. A start option turns the line off: `announce_version` in Python, Rust and Elixir, `announceVersion` in JavaScript, Java, Swift and PHP, `AnnounceVersion` in .NET and Go, `-AnnounceVersion $false` in PowerShell, and `DOKKIT_ANNOUNCE_VERSION=0` in shell. Shell sends the line with the first report of a process.

## Configuration

Environment variables:

| Variable | Holds |
|---|---|
| `DOKKIT_URL` | The server address. |
| `DOKKIT_KEY` | An app key. |
| `DOKKIT_INSECURE` | `1` allows an `http://` address to a host other than this machine. The browser library takes an `insecure` option for the same. |

`DOKKIT_ENV` names the environment of a run, such as `dev`. A library sends it on its error reports, and a line it sends may carry it too. What the server does with it is in `api.md`, under `POST /report`: a run in another environment shows up as its own service and never alerts, and the production service is left as it was.

The service's id and version come from the app key and from what the app passes at start.

## Machines with no `dokkit`

An app using the library reports its host name. The host shows up in Dokkit as a machine of the `seen` kind, with its last-seen time, the app's version on it, and its errors. This is how staff PCs become rows without installing anything extra on them.

## Languages

Python, C#, JavaScript, Go, Elixir, Rust, Java, PHP, PowerShell, shell and Swift. Any other language can use the plain API or the ping URLs in `api.md` until it has a library.

## Built so far

`clients/python/dokkit.py`: one file, standard library only. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture`, `catch_unhandled` and `handler` for the logging module.

`clients/dotnet/Dokkit/Dokkit.cs`: one file for .NET Standard 2.0, no packages. `Start`, `Beat`, `Job`, `Check`, `Metric`, `Stats`, `Log`, `Capture` and `CatchUnhandled`. `clients/dotnet/Dokkit.Logging` is a second small project with the one package it needs, a provider for `Microsoft.Extensions.Logging`: `builder.Logging.AddDokkit()`. An app that writes Serilog's compact format to a file can have `dokkit` read it instead.

`clients/javascript/dokkit.js`: one file, no packages, for Node 18 or later and for browsers. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `catchUnhandled`. `patchConsole` makes `console` also send through `log`, and `consoleLogger` gives a wrapped console; both are opt-in. `dokkit.d.ts` beside it gives TypeScript the types.

`clients/go/dokkit.go`: one file, standard library only. `Start`, `Beat`, `Job`, `Check`, `Metric`, `Stats`, `Log`, `Capture`, `Recover` for panics, and `Handler` for `log/slog`. Go keeps no stack with an error, so a report carries the stack of the place that reported it.

`clients/elixir/lib/dokkit.ex`: one file, no packages, Elixir 1.18 or later. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture`, and the module is itself a `:logger` handler.

`clients/rust/src/lib.rs`: one file and one package, `ureq`, for HTTPS. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `catch_unhandled` for panics. With the `log` cargo feature, off by default, `Logger` implements the `log` crate's `Log` trait. A report carries one frame, the file and line that reported it, and lines carry no time of their own: the server stamps them when they arrive.

`clients/java/src/main/java/dev/dokkit/Dokkit.java`: one file in the package `dev.dokkit`, no dependencies, Java 11 or later. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture`, `catchUnhandled`, and `handler` for `java.util.logging`. Kotlin and Scala use it as it is.

`clients/php/Dokkit.php`: one file, no packages or extensions, PHP 8.0 or later. `Dokkit::start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `catchUnhandled`. `DokkitLogger` has the PSR-3 methods and implements `Psr\Log\LoggerInterface` when `psr/log` is loaded. PHP has no background thread, so lines are sent when the request or script ends, after the response has gone out where PHP allows it.

`clients/powershell/Dokkit.psm1`: one file, for Windows PowerShell 5.1 and PowerShell 7. `Start-Dokkit`, `Send-DokkitBeat`, `Invoke-DokkitJob`, `Send-DokkitProgress`, `Send-DokkitCheck`, `Send-DokkitMetric`, `Write-DokkitLog`, `Send-DokkitError` and `Send-Dokkit`. Lines are sent when a job ends or when `Send-Dokkit` is called.

`clients/shell/dokkit.sh`: one file to source, needing only curl. `dokkit_beat`, `dokkit_job`, `dokkit_check`, `dokkit_metric`, `dokkit_log` and `dokkit_capture <type> <message>`, which sends an error with no message text and no stack. Each call sends its one line straight away and waits at most five seconds, ten if the first try fails. An error report is sent once, because the server cannot tell a repeat from a new error. A failed job carries its exit code.

`clients/swift/Dokkit.swift`: one file, Foundation only, for iOS 13 and macOS 10.15 or later. `start`, `beat`, `job`, `check`, `metric`, `stats`, `log`, `capture` and `flush`. Swift keeps no stack with an error, so a report carries the stack of the place that reported it. It builds with `swift build`; its tests are in `Tests/DokkitTests`. It has no log handler, because Swift's logging frameworks are packages.

## What each library has

| Language | beat | job | check | capture | log | Log handler |
|---|---|---|---|---|---|---|
| Python | yes | yes | yes | yes | yes | `logging` |
| .NET | yes | yes | yes | yes | yes | `Microsoft.Extensions.Logging` |
| JavaScript | yes | yes | yes | yes | yes | `console`, opt-in |
| Go | yes | yes | yes | yes | yes | `log/slog` |
| Rust | yes | yes | yes | yes | yes | `log` crate, optional feature |
| Java | yes | yes | yes | yes | yes | `java.util.logging` |
| PHP | yes | yes | yes | yes | yes | PSR-3, no required package |
| Elixir | yes | yes | yes | yes | yes | `:logger` |
| Swift | yes | yes | yes | yes | yes | none |
| PowerShell | yes | yes | yes | yes | yes | none: no logging framework |
| Shell | yes | yes | yes | yes | yes | none: no logging framework |

Each library folder has a README with install steps, and a manifest except the shell one, which is a single file to source. Nothing is published to a registry yet; they install from a clone of the repo by path. The install-from-git lines in the READMEs work once the repository is public.

The Python handler sends the logger name and the record's `extra` values as fields, and for a record with exception information `exception` (the type name) and `stack` (one `path:line function` per line), never the exception's message. `enabled()` says whether the library was started with an address and key. The Rust crate sends fields with `log_fields`; its exit and panic flush waits at most five seconds, and a panic caught by `catch_unhandled` is an error report of type `panic` with its stack and no message. PowerShell and shell have `stats`; shell's `dokkit_stats` takes a file or JSON text.

A log handler never queues what is logged while the library is sending, so sending cannot feed itself. The Java one also drops records from the JDK HTTP client's loggers (which log from their own threads) and from the library, and stops taking handler records when the queue is half full. The Elixir one drops a record from the TLS or HTTP modules only when it comes from the sender process or carries the library's own metadata, so an app's own failed handshake is logged. The Rust one drops what is logged on the sending thread, whatever crate logged it.

All of them send the host name, and the server records that host as a machine that was seen. When that host is not the machine the service lives on, the version the app starts with is kept for that host and is not a deploy, and the Versions page lists each such app with how many hosts are on each version.
