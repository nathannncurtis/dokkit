# Dokkit for Go

One file, standard library only. `Beat`, `Job`, `Check`, `Capture`, `Log`.

## Install

Nothing is published to a registry yet. Install from the repo:

```
go get github.com/nathannncurtis/dokkit/clients/go@main
```

## Logging

`slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))` sends `log/slog` records through `Log`.

## Test

`go test`
