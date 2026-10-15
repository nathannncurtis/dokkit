# Adds this Windows machine to Dokkit at @@SERVER@@ as @@NAME@@.
# Run it from a PowerShell opened as administrator:
#     powershell -ExecutionPolicy Bypass -File .\@@FILE@@
# -Check downloads and checks the program and changes nothing, with no administrator needed.
# The token in it works once and runs out at @@EXPIRES@@ UTC.
param([switch]$Check)
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$server = '@@SERVER@@'
$token = '@@TOKEN@@'
$pin = '@@PIN@@'
$version = '@@VERSION@@'
$releaseKey = '@@RELEASE_KEY@@'

@@ED25519@@

function Stop-Here([string]$Why) { Write-Host ''; Write-Host "Stopped: $Why" -ForegroundColor Red; exit 1 }

if ($pin) {
    if (-not ('DokkitPin' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Net; using System.Net.Security; using System.Security.Cryptography; using System.Security.Cryptography.X509Certificates;
public static class DokkitPin {
    public static string Want;
    public static bool Check(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) {
        if (c == null) return false;
        using (var sha = SHA256.Create()) { return BitConverter.ToString(sha.ComputeHash(c.GetRawCertData())).Replace("-", "").ToLowerInvariant() == Want; }
    }
}
'@
    }
    [DokkitPin]::Want = $pin.Substring(7).ToLower()
    [Net.ServicePointManager]::ServerCertificateValidationCallback = [Net.Security.RemoteCertificateValidationCallback] [DokkitPin].GetMethod('Check').CreateDelegate([Net.Security.RemoteCertificateValidationCallback])
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Check -and -not $admin) {
    Stop-Here "this needs a PowerShell opened as administrator. Open one and run: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

$installed = Join-Path $env:ProgramFiles 'DokkitProgram\dokkit.exe'
$serviceConfig = Join-Path $env:ProgramData 'DokkitProgram\config.json'
$haveService = [bool](Get-Service dokkit -ErrorAction SilentlyContinue) -and (Test-Path $serviceConfig)
if ($haveService -and -not $Check) {
    Write-Host 'This machine already has the Dokkit service, so only the updater is checked.'
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' }
$name = "dokkit-windows-$arch.exe"
$base = "$server/api/v1/releases/$version"
$headers = @{ Authorization = "Bearer $token" }
$work = Join-Path $env:TEMP ('dokkit-add-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$exe = Join-Path $work 'dokkit.exe'

try {
    if (-not $haveService -or $Check) {
        Write-Host "1/5 Fetching dokkit $version from $server"
        try {
            Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS') -Headers $headers -UseBasicParsing
            Invoke-WebRequest -Uri "$base/SHA256SUMS.sig" -OutFile (Join-Path $work 'SHA256SUMS.sig') -Headers $headers -UseBasicParsing
        } catch {
            Stop-Here "the server did not hand over the program: $($_.Exception.Message) The token may be used or out of date; make a new script."
        }
        $sums = [IO.File]::ReadAllBytes((Join-Path $work 'SHA256SUMS'))
        try { $sig = [Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $work 'SHA256SUMS.sig'))).Trim()) } catch { $sig = [byte[]]@() }
        if (-not (Test-Ed25519 ([Convert]::FromBase64String($releaseKey)) $sig $sums)) { Stop-Here 'the signature of the release list does not check. Nothing was installed.' }
        $lines = [Text.Encoding]::UTF8.GetString($sums) -split "`n"
        if ($lines[0].Trim() -ne "version $version") { Stop-Here "the signed list is for $($lines[0].Trim()), not $version. Nothing was installed." }
        $want = $null
        foreach ($line in $lines[1..($lines.Length - 1)]) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Length -eq 2 -and $parts[1].TrimStart('*') -eq $name) { $want = $parts[0].ToLower(); break }
        }
        if (-not $want) { Stop-Here "the signed list has no $name. Nothing was installed." }
        Invoke-WebRequest -Uri "$base/$name" -OutFile $exe -Headers $headers -UseBasicParsing
        $stream = [IO.File]::OpenRead($exe)
        try { $got = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-').ToLower() }
        finally { $stream.Dispose() }
        if ($got -ne $want) { Stop-Here "the download does not match the signed list. Nothing was installed." }
        Write-Host "    Signature and checksum are good."
        if ($Check) { Write-Host "Check passed: dokkit $version downloaded and verified. Nothing was changed."; return }

        Write-Host '2/5 Enrolling this machine'
        $enrolArgs = @('enrol', $server, $token)
        if ($pin) { $enrolArgs += $pin }
        & $exe @enrolArgs
        if ($LASTEXITCODE -ne 0) { Stop-Here 'enrolling failed (above). Nothing else was changed.' }

        Write-Host '3/5 Installing the service'
        & $exe service install
        if ($LASTEXITCODE -ne 0) { Stop-Here 'the service did not install (above). The machine is enrolled; fix the cause and run: dokkit service install' }
    }

    Write-Host '4/5 Installing the updater'
    & $installed updater install
    if ($LASTEXITCODE -ne 0) { Stop-Here "the updater did not install (above). The service is running; fix the cause and run: `"$installed`" updater install" }

    Write-Host '5/5 Checking it reaches the server'
    if ((Get-Service dokkit).Status -ne 'Running') { Stop-Here 'the Dokkit service is not running.' }
    $env:DOKKIT_CONFIG = $serviceConfig
    & $installed doctor
    if ($LASTEXITCODE -ne 0) { Stop-Here 'the service is installed but cannot report (above).' }
    Write-Host ''
    Write-Host "Done: $env:COMPUTERNAME is set up and reporting to $server." -ForegroundColor Green
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    $answer = Read-Host 'Delete this script? [Y/n]'
    if ($answer -notmatch '^[nN]') { Remove-Item $PSCommandPath -Force; Write-Host 'Deleted.' }
}
}
