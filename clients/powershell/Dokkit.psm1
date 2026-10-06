# The Dokkit client library for PowerShell. One file. Windows PowerShell 5.1 or PowerShell 7.
#
#     Import-Module .\Dokkit.psm1
#     Start-Dokkit -Version '2.3.0'              # reads DOKKIT_URL and DOKKIT_KEY; blank means off
#     Send-DokkitBeat worker                     # from the main loop
#     Invoke-DokkitJob nightly-purge { Send-DokkitProgress 4000 9000 }
#     Send-DokkitCheck queue-age degraded -Value 14 -Note 'oldest item is 14 minutes old'
#     try { ... } catch { Send-DokkitError $_ }
#
# Nothing here throws into the script. Lines wait in a list of fixed size and are sent when a
# job ends or when Send-Dokkit is called. Error message text is never sent.

$script:On = $null
$script:Lines = New-Object System.Collections.Generic.List[object]
$script:Errors = New-Object System.Collections.Generic.List[object]
$script:Dropped = 0
$script:Run = $null

function Start-Dokkit {
    # Turns the library on. With no address or key it stays off and every call does nothing.
    param([string]$Version, [string]$Url = $env:DOKKIT_URL, [string]$Key = $env:DOKKIT_KEY)
    if (-not $Url -or -not $Key -or $script:On) { return }
    $script:On = @{ Url = $Url.TrimEnd('/'); Key = $Key; Version = $Version; Environment = $env:DOKKIT_ENV; Host = [Environment]::MachineName }
    if ($Version) { Add-Line @{ type = 'deploy'; version = $Version } }
}

function Add-Line([hashtable]$Line) {
    if (-not $script:On) { return }
    if ($script:Lines.Count -ge 1000) { $script:Lines.RemoveAt(0); $script:Dropped++ }
    $Line.at = [DateTime]::UtcNow.ToString('o')
    $Line.host = $script:On.Host
    foreach ($name in @($Line.Keys)) { if ($null -eq $Line[$name] -or $Line[$name] -eq '') { $Line.Remove($name) } }
    $script:Lines.Add($Line)
}

function Send-DokkitBeat {
    param([Parameter(Mandatory)][string]$Name, [int]$EverySeconds = 60)
    Add-Line @{ type = 'beat'; name = $Name; every_seconds = $EverySeconds }
}

function Send-DokkitCheck {
    # State is ok, degraded or down.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('ok', 'degraded', 'down')][string]$State, $Value, [string]$Note)
    Add-Line @{ type = 'custom'; check = $Name; state = $State; value = $Value; note = $Note }
}

function Send-DokkitMetric {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][double]$Value, [string]$Unit)
    Add-Line @{ type = 'metric'; name = $Name; value = $Value; unit = $Unit }
}

function Write-DokkitLog {
    # Level is trace, debug, info, warn, error or fatal.
    param([Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][string]$Message)
    Add-Line @{ type = 'log'; t = [DateTime]::UtcNow.ToString('o'); level = $Level; msg = $Message }
}

function Send-DokkitProgress {
    # Inside Invoke-DokkitJob: how far the run has got.
    param([Parameter(Mandatory)][long]$Done, $Total)
    if ($script:Run) { Add-Line @{ type = 'job'; name = $script:Run.Name; run = $script:Run.Id; event = 'progress'; done = $Done; total = $Total } }
}

function Invoke-DokkitJob {
    # Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Work)
    $script:Run = @{ Name = $Name; Id = [guid]::NewGuid().ToString() }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $end = { param($event, $code) Add-Line @{ type = 'job'; name = $Name; run = $script:Run.Id; event = $event; exit_code = $code; duration_ms = $watch.ElapsedMilliseconds } }
    Add-Line @{ type = 'job'; name = $Name; run = $script:Run.Id; event = 'start' }
    try {
        & $Work
        & $end 'ok' 0
    }
    catch {
        & $end 'fail' 1
        Send-DokkitError $_ -Unhandled
        throw
    }
    finally {
        $script:Run = $null
        Send-Dokkit
    }
}

function Send-DokkitError {
    # Sends an error: its type and stack, never its message. Pass $_ from a catch block.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord, [switch]$Unhandled, [hashtable]$Tags = @{})
    if (-not $script:On -or $script:Errors.Count -ge 100) { return }
    $frames = @()
    foreach ($text in ($ErrorRecord.ScriptStackTrace -split "`n")) {
        if ($text -match '^at (?<function>.+), (?<file>.+): line (?<line>\d+)') {
            $frames += @{ function = $Matches.function; file = $Matches.file; line = [int]$Matches.line; own = $Matches.file -notmatch '\\Modules\\|<No file>' }
        }
    }
    # Innermost last, as the format asks.
    [array]::Reverse($frames)
    $script:Errors.Add(@{
            at = [DateTime]::UtcNow.ToString('o'); type = $ErrorRecord.Exception.GetType().Name; handled = -not $Unhandled
            release = $script:On.Version; environment = $script:On.Environment; host = $script:On.Host; frames = $frames; tags = $Tags
        })
}

function Send-Dokkit {
    # Sends what is waiting. Call it at the end of a script that does not use Invoke-DokkitJob.
    if (-not $script:On) { return }
    $post = {
        param($path, $body, $kind)
        try {
            $headers = @{ Authorization = "Bearer $($script:On.Key)"; 'Dokkit-Batch' = [guid]::NewGuid().ToString() }
            $null = Invoke-WebRequest -Uri ($script:On.Url + $path) -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType $kind -Headers $headers -TimeoutSec 10 -UseBasicParsing
        }
        catch {
            # What cannot be sent is dropped. The script is never told.
        }
    }
    $errors = $script:Errors.ToArray(); $script:Errors.Clear()
    $lines = $script:Lines.ToArray(); $script:Lines.Clear()
    foreach ($e in $errors) { & $post '/api/v1/errors' (ConvertTo-Json $e -Depth 6 -Compress) 'application/json' }
    for ($i = 0; $i -lt $lines.Count; $i += 500) {
        $batch = $lines[$i..([Math]::Min($i + 499, $lines.Count - 1))] | ForEach-Object { ConvertTo-Json $_ -Depth 6 -Compress }
        & $post '/api/v1/report' ($batch -join "`n") 'application/x-ndjson'
    }
}

Export-ModuleMember -Function Start-Dokkit, Send-DokkitBeat, Send-DokkitCheck, Send-DokkitMetric, Write-DokkitLog, Send-DokkitProgress, Invoke-DokkitJob, Send-DokkitError, Send-Dokkit
