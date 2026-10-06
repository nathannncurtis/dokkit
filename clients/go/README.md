# Dokkit for Go

One file, standard library only. `Beat`, `Job`, `Check`, `Capture`, `Log`.

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

## Logging

`slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))` sends `log/slog` records through `Log`.

## Test

`go test`
