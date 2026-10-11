# Dokkit for .NET

`Dokkit` is one file for .NET Standard 2.0 with no packages: `Beat`, `Job`, `Check`, `Capture`, `Log`. `Dokkit.Logging` adds the logging provider.

## Install

Nothing is published to a registry yet. Reference the project from a clone of the repo:

```
dotnet add reference path/to/dokkit/clients/dotnet/Dokkit/Dokkit.csproj
dotnet add reference path/to/dokkit/clients/dotnet/Dokkit.Logging/Dokkit.Logging.csproj
```

## Logging

`builder.Logging.AddDokkit()` sends `Microsoft.Extensions.Logging` through `Log`. It needs `Dokkit.Logging`.

## Behavior

- `Start(version: ...)` sends the version once as a deploy line; `announceVersion: false` turns that off. The server records a deploy only when the version changes.
- A line over 64 KB is cut: `msg` is shortened and ends with ` [cut]`. Lines with no `msg` that are too big are dropped and counted.
- An error report the server did not answer for (network error, timeout, 5xx, 429) is kept for the next pass; a 4xx is dropped and counted. Error reports and log batches never hold each other up.
- Report bodies are gzipped. Whatever the library's own HTTP call logs is not queued.
- Stack frames carry the type name, not a file path, so no folder on the machine is sent.
- When the environment (`environment:` or `DOKKIT_ENV`) is set and is not `production`, it goes on every line.

## Test

`dotnet run --project Test`
