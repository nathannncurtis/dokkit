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
$script:Bytes = 0

function Start-Dokkit {
    # Turns the library on. With no address or key it stays off and every call does nothing.
    param([string]$Version, [string]$Url = $env:DOKKIT_URL, [string]$Key = $env:DOKKIT_KEY)
    if (-not $Url -or -not $Key -or $script:On) { return }
    if ($Url -match '^http://' -and $Url -notmatch '^http://(localhost|127(\.\d+){3}|\[::1\])([:/]|$)' -and $env:DOKKIT_INSECURE -ne '1') {
        [Console]::Error.WriteLine('dokkit: http:// address to a non-local host; set DOKKIT_INSECURE=1 to allow it. Staying off.')
        return
    }
    # Windows PowerShell 5.1 on older .NET does not offer TLS 1.2 unless asked.
    try { if ([Net.ServicePointManager]::SecurityProtocol -ne 0) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } } catch {}
    $script:On = @{ Url = $Url.TrimEnd('/'); Key = $Key; Version = $Version; Environment = $env:DOKKIT_ENV; Host = [Environment]::MachineName; Root = (Get-Location).Path }
    if ($Version) { Add-Line @{ type = 'deploy'; version = $Version } }
}

function Add-Line([hashtable]$Line) {
    if (-not $script:On) { return }
    $Line.at = [DateTime]::UtcNow.ToString('o')
    $Line.host = $script:On.Host
    foreach ($name in @($Line.Keys)) { if ($null -eq $Line[$name] -or ($Line[$name] -is [string] -and $Line[$name] -eq '')) { $Line.Remove($name) } }
    try { $text = ConvertTo-Json $Line -Depth 6 -Compress } catch { $script:Dropped++; return }
    $size = [Text.Encoding]::UTF8.GetByteCount($text)
    if ($size -gt 4000000) { $script:Dropped++; return }
    while ($script:Lines.Count -gt 0 -and ($script:Lines.Count -ge 1000 -or $script:Bytes + $size -gt 4000000)) {
        $script:Bytes -= [Text.Encoding]::UTF8.GetByteCount($script:Lines[0]); $script:Lines.RemoveAt(0); $script:Dropped++
    }
    $script:Lines.Add($text)
    $script:Bytes += $size
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
    param([Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
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
    $outer = $script:Run
    $id = [guid]::NewGuid().ToString()
    $script:Run = @{ Name = $Name; Id = $id }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $end = { param($event, $code) Add-Line @{ type = 'job'; name = $Name; run = $id; event = $event; exit_code = $code; duration_ms = $watch.ElapsedMilliseconds } }
    Add-Line @{ type = 'job'; name = $Name; run = $id; event = 'start' }
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
        $script:Run = $outer
        Send-Dokkit
    }
}

function Send-DokkitError {
    # Sends an error: its type and stack, never its message. Pass $_ from a catch block.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord, [switch]$Unhandled, [hashtable]$Tags = @{})
    if (-not $script:On -or $script:Errors.Count -ge 100) { return }
    $root = $script:On.Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $frames = @()
    foreach ($text in ($ErrorRecord.ScriptStackTrace -split "`n")) {
        if ($text -match '^at (?<function>.+), (?<file>.+): line (?<line>\d+)') {
            $file = $Matches.file
            $own = $file -notmatch '\\Modules\\|<No file>'
            # Relative to the folder the script runs from; other files keep only their name.
            $file = if ($file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $file.Substring($root.Length) } else { Split-Path $file -Leaf }
            $frames += @{ function = $Matches.function; file = $file; line = [int]$Matches.line; own = $own }
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
        param($path, $body, $kind, $id)
        try {
            $headers = @{ Authorization = "Bearer $($script:On.Key)"; 'Dokkit-Batch' = $id }
            $null = Invoke-WebRequest -Uri ($script:On.Url + $path) -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType $kind -Headers $headers -TimeoutSec 10 -UseBasicParsing
            $true
        }
        catch { $false }
    }
    while ($script:Errors.Count -gt 0) {
        $e = $script:Errors[0]; $script:Errors.RemoveAt(0)
        if (-not (& $post '/api/v1/errors' (ConvertTo-Json $e -Depth 6 -Compress) 'application/json' ([guid]::NewGuid().ToString()))) { $script:Dropped++; break }
    }
    while ($script:Lines.Count -gt 0) {
        $take = [Math]::Min(500, $script:Lines.Count)
        $batch = $script:Lines.GetRange(0, $take).ToArray(); $script:Lines.RemoveRange(0, $take)
        foreach ($l in $batch) { $script:Bytes -= [Text.Encoding]::UTF8.GetByteCount($l) }
        $id = [guid]::NewGuid().ToString()
        $body = $batch -join "`n"
        # A failed batch gets one more try with the same id; after that it is dropped and counted.
        if (-not (& $post '/api/v1/report' $body 'application/x-ndjson' $id) -and -not (& $post '/api/v1/report' $body 'application/x-ndjson' $id)) {
            $script:Dropped += $batch.Count
            break
        }
    }
}

Export-ModuleMember -Function Start-Dokkit, Send-DokkitBeat, Send-DokkitCheck, Send-DokkitMetric, Write-DokkitLog, Send-DokkitProgress, Invoke-DokkitJob, Send-DokkitError, Send-Dokkit
