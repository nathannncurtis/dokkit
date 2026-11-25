# Dokkit for PowerShell

One file, for Windows PowerShell 5.1 and PowerShell 7. `Send-DokkitBeat`, `Invoke-DokkitJob`, `Send-DokkitCheck`, `Send-DokkitMetric`, `Send-DokkitError`, `Write-DokkitLog`.

## Install

Nothing is published to a registry yet. Import the module from a clone of the repo:

```
Import-Module path\to\dokkit\clients\powershell\Dokkit.psd1
```

`Send-DokkitStats` sends a stats document (an object or a JSON string). `Start-Dokkit` queues a deploy line for `-Version`; `-AnnounceVersion $false` leaves it out. The server records a deploy only when the version changes. `-Environment` (or `DOKKIT_ENV`), when it is not `production`, goes on every line.

Report bodies are gzipped. A line over 64 KB is cut in bytes, with ` [cut]` at the end of its message. An error report the server did not answer for, or answered with 5xx or 429, is kept and sent on the next `Send-Dokkit`; one it refuses with another 4xx is dropped and counted. Stack paths are relative to the folder of the script that calls `Start-Dokkit` (`-Root` names another); other files carry only their name.

## Fields and time limit

`Write-DokkitLog info paid -Fields @{ order = 42; who = 'x' }` sends the hashtable as a flat `fields` object on the log line. A line over 64 KB loses its fields first, then the end of its message.

`Send-Dokkit` stops after `-TimeoutSeconds` (5 by default), so an unreachable server never holds the script. What it did not send stays queued for the next call. `Invoke-DokkitJob` ends with a `Send-Dokkit` at the default limit.

## Logging

PowerShell has no logging framework, so there is no handler. Call `Write-DokkitLog`.

## Test

`node --test`
