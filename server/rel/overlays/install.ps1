# Installs the Dokkit server on this Windows machine as a service, or upgrades one that is
# already here. Run it from an administrator PowerShell, in the folder of an unpacked release.
#
# The first time, with a Postgres of its own or with one that is already there:
#     .\install.ps1 -Postgres 'C:\Downloads\pgsql'
#     .\install.ps1 -DatabaseUrl 'ecto://dokkit:password@localhost/dokkit'
# An upgrade, of Dokkit alone or of its Postgres too:
#     .\install.ps1
#     .\install.ps1 -Postgres 'C:\Downloads\pgsql'
#
# -Postgres is the unpacked folder of Postgres's Windows binaries, the one that holds bin\initdb.exe.
# It becomes a Windows service of its own that listens on this machine only.
param(
    [string]$DatabaseUrl,
    [string]$Postgres,
    [string]$Address = $env:COMPUTERNAME,
    [int]$Port = 4000,
    [string]$To = (Join-Path $env:ProgramFiles 'Dokkit'),
    [string]$Archive
)
$ErrorActionPreference = 'Stop'

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator PowerShell.'
}

$service = 'dokkit_dokkit'
$database = 'dokkit-postgres'
$databasePort = 54329
$folder = Join-Path $env:ProgramData 'Dokkit'
$settings = Join-Path $folder 'settings.env'
$upgrade = Test-Path $settings
if (-not $upgrade -and -not $DatabaseUrl -and -not $Postgres) {
    throw 'A first install needs -Postgres, for a Postgres of its own, or -DatabaseUrl, for one that is already there.'
}
if ($Postgres -and -not (Test-Path (Join-Path $Postgres 'bin\initdb.exe'))) {
    throw "-Postgres must be the folder that holds bin\initdb.exe. $Postgres does not."
}

function Get-Erlsrv { (Get-ChildItem (Join-Path $To 'erts-*\bin\erlsrv.exe') | Select-Object -Last 1).FullName }
function Get-Secret([int]$Bytes) {
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    [Convert]::ToBase64String($buffer)
}

if ($upgrade -and (Get-Service $service -ErrorAction SilentlyContinue)) {
    Write-Host 'Stopping the service.'
    & (Get-Erlsrv) stop $service | Out-Null
}

Write-Host "Copying the server to $To."
New-Item -ItemType Directory -Force $To | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $To -Recurse -Force

if (-not $upgrade) {
    # The settings hold the database password and the key that signs sessions, so only
    # administrators and the system account may read them.
    New-Item -ItemType Directory -Force $folder | Out-Null
    & icacls $folder /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
}

if ($Postgres) {
    $pg = Join-Path $To 'postgres'
    $data = Join-Path $folder 'pgdata'
    $running = Get-Service $database -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host 'Stopping its Postgres to put the newer one in place.'
        Stop-Service $database
    }
    New-Item -ItemType Directory -Force $pg | Out-Null
    Copy-Item -Path (Join-Path $Postgres '*') -Destination $pg -Recurse -Force

    if (-not $running) {
        Write-Host 'Setting up a Postgres for Dokkit alone.'
        # Letters and digits only, so the password needs no escaping in an address.
        $password = (Get-Secret 24) -replace '[^A-Za-z0-9]', ''
        $passwordFile = Join-Path $folder 'postgres-password.txt'
        Set-Content -Path $passwordFile -Value $password -Encoding ascii -NoNewline
        & (Join-Path $pg 'bin\initdb.exe') -D $data -U dokkit --pwfile=$passwordFile -A scram-sha-256 -E UTF8 --locale=C | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Postgres could not make its data folder.' }
        # It runs as Network Service, which needs the data folder and nothing else.
        & icacls $data /grant '*S-1-5-20:(OI)(CI)F' | Out-Null
        & (Join-Path $pg 'bin\pg_ctl.exe') register -N $database -D $data -U 'NT AUTHORITY\NetworkService' -S auto -o "-p $databasePort"
        if ($LASTEXITCODE -ne 0) { throw 'Postgres could not be registered as a service.' }
        Start-Service $database
        $env:PGPASSWORD = $password
        & (Join-Path $pg 'bin\createdb.exe') -h localhost -p $databasePort -U dokkit dokkit
        if ($LASTEXITCODE -ne 0) { throw 'The database could not be made.' }
        $env:PGPASSWORD = $null
        $DatabaseUrl = "ecto://dokkit:$password@localhost:$databasePort/dokkit"
    }
    else {
        Start-Service $database
    }
}

if (-not $upgrade) {
    $lines = @(
        "DATABASE_URL=$DatabaseUrl"
        "SECRET_KEY_BASE=$(Get-Secret 48)"
        "PHX_HOST=$Address"
        "PORT=$Port"
        'PHX_SERVER=true'
    )
    if ($Archive) { $lines += "DOKKIT_ARCHIVE=$Archive" }
    Set-Content -Path $settings -Value $lines -Encoding ascii
}

Write-Host 'Bringing the database up to date.'
& (Join-Path $To 'bin\dokkit.bat') eval 'Dokkit.Release.migrate'
if ($LASTEXITCODE -ne 0) { throw 'The database could not be brought up to date. The service was left stopped.' }

if (-not (Get-Service $service -ErrorAction SilentlyContinue)) {
    & (Join-Path $To 'bin\dokkit.bat') install
}
& (Get-Erlsrv) start $service | Out-Null

Write-Host "Dokkit is at http://${Address}:$Port"
if (-not $upgrade) { Write-Host "The first visit asks for a setup code. It is in the newest file under $To\log." }
