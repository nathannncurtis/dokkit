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

## Test

`dotnet run --project Test`
