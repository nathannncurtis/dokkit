# Installs the Dokkit server on this Windows machine as a service, or upgrades one that is
# already here. Run it from an administrator PowerShell, in the folder of an unpacked release:
#
#     .\install.ps1 -DatabaseUrl 'ecto://dokkit:password@localhost/dokkit'     # the first time
#     .\install.ps1                                                            # an upgrade
#
# It needs a Postgres it can reach; it does not install one.
param(
    [string]$DatabaseUrl,
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
$folder = Join-Path $env:ProgramData 'Dokkit'
$settings = Join-Path $folder 'settings.env'
$upgrade = Test-Path $settings
if (-not $upgrade -and -not $DatabaseUrl) { throw 'A first install needs -DatabaseUrl.' }

$erlsrv = { (Get-ChildItem (Join-Path $To 'erts-*\bin\erlsrv.exe') | Select-Object -Last 1).FullName }

if ($upgrade -and (Get-Service $service -ErrorAction SilentlyContinue)) {
    Write-Host 'Stopping the service.'
    & (& $erlsrv) stop $service | Out-Null
}

Write-Host "Copying the server to $To."
New-Item -ItemType Directory -Force $To | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $To -Recurse -Force

if (-not $upgrade) {
    # The settings hold the database password and the key that signs sessions, so only
    # administrators and the system account may read them.
    New-Item -ItemType Directory -Force $folder | Out-Null
    & icacls $folder /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    $bytes = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $lines = @(
        "DATABASE_URL=$DatabaseUrl"
        "SECRET_KEY_BASE=$([Convert]::ToBase64String($bytes))"
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
& (& $erlsrv) start $service | Out-Null

Write-Host "Dokkit is at http://${Address}:$Port"
if (-not $upgrade) { Write-Host "The first visit asks for a setup code. It is in the newest file under $To\log." }
