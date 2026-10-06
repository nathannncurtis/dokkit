# Dokkit for PowerShell

One file, for Windows PowerShell 5.1 and PowerShell 7. `Send-DokkitBeat`, `Invoke-DokkitJob`, `Send-DokkitCheck`, `Send-DokkitError`, `Write-DokkitLog`.

## Install

Nothing is published to a registry yet. Import the module from a clone of the repo:

```
Import-Module path\to\dokkit\clients\powershell\Dokkit.psd1
```

## Logging

PowerShell has no logging framework, so there is no handler. Call `Write-DokkitLog`.

## Test

`node --test`
