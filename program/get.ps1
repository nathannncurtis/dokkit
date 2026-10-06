# Puts the dokkit program on this Windows machine. No administrator needed.
#     irm https://dokkit.dev/get.ps1 | iex
# DOKKIT_RELEASE_BASE names another place to download from.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$base = 'https://github.com/nathannncurtis/dokkit/releases/latest/download'
if ($env:DOKKIT_RELEASE_BASE) { $base = $env:DOKKIT_RELEASE_BASE.TrimEnd('/') }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' }
$name = "dokkit-windows-$arch.exe"

$work = Join-Path $env:TEMP ('dokkit-get-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$file = Join-Path $work $name

Write-Host "Fetching $base/$name"
Invoke-WebRequest -Uri "$base/$name" -OutFile $file -UseBasicParsing
$content = (Invoke-WebRequest -Uri "$base/$name.sha256" -UseBasicParsing).Content
# A release file comes as application/octet-stream, which Windows PowerShell 5.1 gives as bytes.
if ($content -is [byte[]]) { $content = [Text.Encoding]::ASCII.GetString($content) }
$want = (-split [string]$content)[0]

$stream = [IO.File]::OpenRead($file)
try { $got = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-' }
finally { $stream.Dispose() }
if (-not $want -or $got -ne $want) { throw "The download's SHA-256 is $got, not $want. Nothing was installed." }

$folder = Join-Path $env:LOCALAPPDATA 'Programs\dokkit'
New-Item -ItemType Directory -Force $folder | Out-Null
Copy-Item $file (Join-Path $folder 'dokkit.exe') -Force
Write-Host "Installed $folder\dokkit.exe"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $folder)) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath, $folder) -join ';').Trim(';'), 'User')
    Write-Host 'Added it to your Path. Open a new terminal to use it.'
}
Write-Host 'Next: dokkit enrol <address> <token>'
