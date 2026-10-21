# Dokkit for Go

One file, standard library only. `Beat`, `Job`, `Check`, `Metric`, `Capture`, `Log`, `Stats`.

## Install

Nothing is published to a registry yet. From a clone of the repo, in your module:

```
go mod edit -require github.com/nathannncurtis/dokkit/clients/go@v0.0.0
go mod edit -replace github.com/nathannncurtis/dokkit/clients/go=path/to/dokkit/clients/go
```

Once the repository is public, this also works:

```
go get github.com/nathannncurtis/dokkit/clients/go@main
```

## Start

`dokkit.Start("2.3.0")` reads `DOKKIT_URL` and `DOKKIT_KEY`. `dokkit.StartWith("2.3.0", addr, key)` uses what it is given and does not read the environment: a blank address or key means off.

Start with a version sends one `deploy` line per process, in the background. Set `dokkit.AnnounceVersion = false` before `Start` to turn it off. The server records a deploy only when the version changes; for an app on many PCs it keeps one row per PC.

A non-production environment (`DOKKIT_ENV`) is put on every line. A line over 64 KB (bytes) loses its fields and has its `msg` cut, ending in ` [cut]`. Report bodies are gzipped. Stack frames carry the package path and file name only; Go has no app folder notion.

## Sending

Lines go first, then error reports. An error report the server did not answer for is kept and sent on a later pass; at most 100 wait. `dokkit.Dropped()` is how many lines and reports were dropped.

`dokkit.Flush()` and `dokkit.Recover()` wait at most `dokkit.FlushTimeout`, 5 seconds unless set.

## Logging

`slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))` sends `log/slog` records through `Log`. Anything logged on the goroutine that is inside the library's own request is not queued.

## Test

`go test`
