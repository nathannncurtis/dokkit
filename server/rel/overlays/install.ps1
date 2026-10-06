# Installs the Dokkit server on this Windows machine as a service, or upgrades one that is
# already here. Run it from an administrator PowerShell, in the folder of an unpacked release.
# Or piped from the site, which fetches the release and, the first time, a Postgres:
#     irm https://dokkit.dev/install.ps1 | iex
#
# The first time, with a Postgres of its own or with one that is already there:
#     .\install.ps1 -Postgres 'C:\Downloads\pgsql'
#     .\install.ps1 -DatabaseUrl 'ecto://dokkit:password@localhost/dokkit'
# An upgrade, of Dokkit alone or of its Postgres too:
#     .\install.ps1
#     .\install.ps1 -Postgres 'C:\Downloads\pgsql'
#
# -Postgres is the unpacked folder of Postgres's Windows binaries, the one holding bin\initdb.exe.
# It becomes a Windows service of its own that listens on this machine only.
# -Cert and -CertKey are a certificate and its key, as PEM files. With them Dokkit serves https
# itself. Without them it serves plain http, which only this machine can use: anything else needs
# a certificate here or a proxy that holds one.
# Settings given on an upgrade replace the ones from before; the rest are kept.
param(
    [string]$DatabaseUrl,
    [string]$Postgres,
    [string]$Address = $env:COMPUTERNAME,
    [int]$Port = 4000,
    [string]$To = (Join-Path $env:ProgramFiles 'Dokkit'),
    [string]$Archive,
    [string]$Cert,
    [string]$CertKey
)
$ErrorActionPreference = 'Stop'

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator PowerShell.'
}

# Piped from the site there is no release beside this script, so it fetches one, and a Postgres
# for a first install that named no database, then runs the copy inside that release.
if (-not $PSScriptRoot -or -not (Test-Path (Join-Path $PSScriptRoot 'bin\dokkit.bat'))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $work = Join-Path $env:TEMP ('dokkit-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $work | Out-Null
    # Nothing is unpacked until its SHA-256 matches the one expected.
    $fetch = {
        param($Url, $Name, $Sha256)
        Write-Host "Fetching $Url"
        $zip = Join-Path $work "$Name.zip"
        Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
        $stream = [IO.File]::OpenRead($zip)
        try { $got = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-' }
        finally { $stream.Dispose() }
        if ($got -ne $Sha256) { throw "$Url is not the file expected: its SHA-256 is $got, not $Sha256. Nothing was installed." }
        Expand-Archive -Path $zip -DestinationPath (Join-Path $work $Name)
    }
    $releaseUrl = 'https://github.com/nathannncurtis/dokkit/releases/latest/download/dokkit-windows-x64.zip'
    if ($env:DOKKIT_RELEASE_URL) { $releaseUrl = $env:DOKKIT_RELEASE_URL }
    # A release is published with its SHA-256 beside it, in a file of the same name plus .sha256.
    $releaseSha = (-split [string](Invoke-WebRequest -Uri "$releaseUrl.sha256" -UseBasicParsing).Content)[0]
    & $fetch $releaseUrl 'dokkit' $releaseSha
    $again = @{}
    foreach ($name in $PSBoundParameters.Keys) { $again[$name] = $PSBoundParameters[$name] }
    $first = -not (Test-Path (Join-Path $env:ProgramData 'Dokkit\settings.env'))
    if ($first -and -not $DatabaseUrl -and -not $Postgres) {
        $postgresUrl = 'https://get.enterprisedb.com/postgresql/postgresql-17.6-1-windows-x64-binaries.zip'
        $postgresSha = 'D378882ABD001A186735ACD6F6BA716BCA6CCD192E800412D4FD15ED25376B3E'
        # Another download needs its own SHA-256 named with it.
        if ($env:DOKKIT_POSTGRES_URL) {
            if (-not $env:DOKKIT_POSTGRES_SHA256) { throw 'DOKKIT_POSTGRES_URL needs DOKKIT_POSTGRES_SHA256 with it.' }
            $postgresUrl = $env:DOKKIT_POSTGRES_URL; $postgresSha = $env:DOKKIT_POSTGRES_SHA256
        }
        & $fetch $postgresUrl 'postgres' $postgresSha
        $again.Postgres = Join-Path $work 'postgres\pgsql'
    }
    $inner = Get-ChildItem (Join-Path $work 'dokkit') -Recurse -Filter install.ps1 | Select-Object -First 1
    if (-not $inner) { throw "The release from $releaseUrl holds no install.ps1." }
    & $inner.FullName @again
    Write-Host "The downloads are in $work and can be deleted."
    return
}

$service = 'dokkit_dokkit'
$database = 'dokkit-postgres'
$databasePort = 54329
$folder = Join-Path $env:ProgramData 'Dokkit'
$settings = Join-Path $folder 'settings.env'
$data = Join-Path $folder 'pgdata'
$logs = Join-Path $folder 'log'
$administrators = '*S-1-5-32-544'
$system = '*S-1-5-18'
$localService = '*S-1-5-19'
$networkService = '*S-1-5-20'

# A folder somebody else made first would stay theirs, and so would the settings in it.
if (Test-Path $folder) {
    $owner = (Get-Acl $folder).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin 'S-1-5-32-544', 'S-1-5-18') {
        throw "$folder belongs to $owner, not to administrators. Find out who made it before installing."
    }
}

$upgrade = Test-Path $settings
if (-not $upgrade -and -not $DatabaseUrl -and -not $Postgres) {
    throw 'A first install needs -Postgres, for a Postgres of its own, or -DatabaseUrl, for one that is already there.'
}
if ($Postgres -and -not (Test-Path (Join-Path $Postgres 'bin\initdb.exe'))) {
    throw "-Postgres must be the folder that holds bin\initdb.exe. $Postgres does not."
}
if ([bool]$Cert -ne [bool]$CertKey) { throw '-Cert and -CertKey go together.' }
if ($Cert -and -not ((Test-Path $Cert) -and (Test-Path $CertKey))) { throw 'The certificate or its key is not there.' }

# Postgres cannot open data made by another major version, and the old binaries are gone once
# these are copied over them.
if ($Postgres -and (Test-Path (Join-Path $data 'PG_VERSION'))) {
    $have = (Get-Content (Join-Path $data 'PG_VERSION') -Raw).Trim()
    $new = (& (Join-Path $Postgres 'bin\postgres.exe') -V) -replace '^\D*(\d+).*$', '$1'
    if ($new -ne ($have -replace '\..*$', '')) {
        throw "The data is Postgres $have and these binaries are Postgres $new. A new major version needs a dump and a restore, not a copy."
    }
}

function Get-Erlsrv {
    (Get-ChildItem (Join-Path $To 'erts-*\bin\erlsrv.exe') |
        Sort-Object { [version]($_.Directory.Parent.Name -replace '^erts-') } |
        Select-Object -Last 1).FullName
}
function Test-Ok([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed." }
}
function Get-Secret([int]$Bytes) {
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    [Convert]::ToBase64String($buffer)
}
function Get-SetupCodes {
    $log = Join-Path $logs 'dokkit.log'
    if (Test-Path $log) {
        @(Select-String -Path $log -Pattern 'etup code(?: is)?: ([A-Z0-9]{4}-[A-Z0-9]{4})' |
            ForEach-Object { $_.Matches[0].Groups[1].Value })
    }
}

# What was set before, then what was asked for now.
$values = [ordered]@{}
if ($upgrade) {
    foreach ($line in Get-Content $settings) {
        if ($line.TrimStart([char]0xFEFF) -match '^\s*([^=\s]+)\s*=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
    }
}
if ($DatabaseUrl) { $values['DATABASE_URL'] = $DatabaseUrl }
if ($PSBoundParameters.ContainsKey('Address') -or -not $values['PHX_HOST']) { $values['PHX_HOST'] = $Address }
if ($PSBoundParameters.ContainsKey('Port') -or -not $values['PORT']) { $values['PORT'] = "$Port" }
if ($Archive) { $values['DOKKIT_ARCHIVE'] = $Archive }
if (-not $values['SECRET_KEY_BASE']) { $values['SECRET_KEY_BASE'] = Get-Secret 48 }
$values['PHX_SERVER'] = 'true'
$values['DOKKIT_LOG_DIR'] = $logs

$restartService = $false
$restartDatabase = $false
try {
    if (Get-Service $service -ErrorAction SilentlyContinue) {
        Write-Host 'Stopping the service.'
        & (Get-Erlsrv) stop $service | Out-Null
        $restartService = $upgrade
    }

    Write-Host "Copying the server to $To."
    New-Item -ItemType Directory -Force $To | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $To -Recurse -Force

    # Every release archive carries the same cookie. This one is made here and only administrators
    # and the system account can read it.
    $cookie = Join-Path $To 'releases\COOKIE'
    $cookieBytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($cookieBytes)
    Set-Content -Path $cookie -Value (($cookieBytes | ForEach-Object { $_.ToString('x2') }) -join '') -Encoding ascii -NoNewline
    & icacls $cookie /inheritance:r /grant:r "${administrators}:F" "${system}:F" | Out-Null
    Test-Ok 'Locking down the cookie'

    New-Item -ItemType Directory -Force $folder | Out-Null
    if (-not $upgrade) {
        # The settings hold the database password and the key that signs sessions, so only
        # administrators and the system account may read them.
        & icacls $folder /setowner $administrators /T /C | Out-Null
        Test-Ok 'Setting the owner of the settings folder'
        & icacls $folder /reset /T /C | Out-Null
        Test-Ok 'Resetting the settings folder'
        & icacls $folder /inheritance:r /grant:r "${administrators}:(OI)(CI)F" "${system}:(OI)(CI)F" | Out-Null
        Test-Ok 'Locking down the settings folder'
        # What a failed first install left behind is Postgres's again.
        if (Test-Path $data) {
            & icacls $data /grant "${networkService}:(OI)(CI)F" | Out-Null
            Test-Ok 'Giving Postgres its data folder'
        }
    }
    # The service runs as Local Service. It may read the settings and write the log, nothing else here.
    & icacls $folder /grant "${localService}:R" | Out-Null
    Test-Ok 'Letting the service read the settings folder'
    New-Item -ItemType Directory -Force $logs | Out-Null
    & icacls $logs /inheritance:r /grant:r "${administrators}:(OI)(CI)F" "${system}:(OI)(CI)F" "${localService}:(OI)(CI)M" | Out-Null
    Test-Ok 'Locking down the log folder'
    if ($values['DOKKIT_ARCHIVE']) {
        New-Item -ItemType Directory -Force $values['DOKKIT_ARCHIVE'] | Out-Null
        & icacls $values['DOKKIT_ARCHIVE'] /grant "${localService}:(OI)(CI)M" | Out-Null
        Test-Ok 'Letting the service write the archive folder'
    }

    if ($Cert) {
        $values['DOKKIT_CERT'] = Join-Path $folder 'cert.pem'
        $values['DOKKIT_CERT_KEY'] = Join-Path $folder 'key.pem'
        Copy-Item $Cert $values['DOKKIT_CERT'] -Force
        Copy-Item $CertKey $values['DOKKIT_CERT_KEY'] -Force
        & icacls $values['DOKKIT_CERT'] /grant "${localService}:R" | Out-Null
        Test-Ok 'Letting the service read the certificate'
        & icacls $values['DOKKIT_CERT_KEY'] /grant "${localService}:R" | Out-Null
        Test-Ok 'Letting the service read the key'
    }

    if ($Postgres) {
        $pg = Join-Path $To 'postgres'
        $passwordFile = Join-Path $folder 'postgres-password.txt'
        $running = Get-Service $database -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host 'Stopping its Postgres to put the newer one in place.'
            Stop-Service $database
            $restartDatabase = $true
        }
        New-Item -ItemType Directory -Force $pg | Out-Null
        Copy-Item -Path (Join-Path $Postgres '*') -Destination $pg -Recurse -Force

        if (-not $running) {
            Write-Host 'Setting up a Postgres for Dokkit alone.'
            # A data folder that was made keeps its password; only a missing one gets a new one.
            if (-not (Test-Path (Join-Path $data 'PG_VERSION'))) {
                # Letters and digits only, so the password needs no escaping in an address.
                $password = (Get-Secret 24) -replace '[^A-Za-z0-9]', ''
                Set-Content -Path $passwordFile -Value $password -Encoding ascii -NoNewline
                & (Join-Path $pg 'bin\initdb.exe') -D $data -U dokkit --pwfile=$passwordFile -A scram-sha-256 -E UTF8 --locale=C | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Postgres could not make its data folder.' }
            }
            # It runs as Network Service, which needs the data folder and nothing else.
            & icacls $data /grant "${networkService}:(OI)(CI)F" | Out-Null
            Test-Ok 'Giving Postgres its data folder'
            & (Join-Path $pg 'bin\pg_ctl.exe') register -N $database -D $data -U 'NT AUTHORITY\NetworkService' -S auto -o "-p $databasePort"
            if ($LASTEXITCODE -ne 0) { throw 'Postgres could not be registered as a service.' }
        }
        Start-Service $database
        $restartDatabase = $false

        if (-not $upgrade) {
            # A first install that failed after Postgres was set up comes back here with the
            # password already made and possibly the database too.
            if (-not (Test-Path $passwordFile)) { throw "$passwordFile is missing, so the password of Dokkit's Postgres is not known." }
            $password = (Get-Content $passwordFile -Raw).Trim()
            $env:PGPASSWORD = $password
            try {
                & (Join-Path $pg 'bin\createdb.exe') -h localhost -p $databasePort -U dokkit dokkit
                if ($LASTEXITCODE -ne 0 -and -not $running) { throw 'The database could not be made.' }
            }
            finally { $env:PGPASSWORD = $null }
            $values['DATABASE_URL'] = "ecto://dokkit:$password@localhost:$databasePort/dokkit"
        }
    }

    if (-not $values['DATABASE_URL']) { throw 'There is no database address to write to the settings.' }
    Set-Content -Path $settings -Value ($values.Keys | ForEach-Object { "$_=$($values[$_])" }) -Encoding ascii
    & icacls $settings /grant "${localService}:R" | Out-Null
    Test-Ok 'Letting the service read the settings'

    Write-Host 'Bringing the database up to date.'
    $restartService = $false
    & (Join-Path $To 'bin\dokkit.bat') eval 'Dokkit.Release.migrate'
    if ($LASTEXITCODE -ne 0) { throw 'The database could not be brought up to date. The service was left stopped.' }

    # The registration holds this version's paths, so it is made again every time.
    if (Get-Service $service -ErrorAction SilentlyContinue) { & (Get-Erlsrv) remove $service | Out-Null }
    & (Join-Path $To 'bin\dokkit.bat') install
    if ($LASTEXITCODE -ne 0) { throw 'The service could not be registered.' }
    & sc.exe config $service obj= 'NT AUTHORITY\LocalService' password= '""' start= auto | Out-Null
    Test-Ok 'Making the service run as Local Service'
    if (Get-Service $database -ErrorAction SilentlyContinue) {
        & sc.exe config $service depend= $database | Out-Null
        Test-Ok 'Making the service wait for its Postgres'
    }
    # The wrapper is the service process, so its own setting is what restarts it.
    & (Get-Erlsrv) set $service -onfail restart | Out-Null
    Test-Ok 'Making the service restart when it stops'
    # The wrapper keeps the cookie in this key, which every user can read until it is locked.
    $key = Get-ChildItem 'HKLM:\SOFTWARE\Ericsson\Erlang\ErlSrv' -ErrorAction Stop |
        ForEach-Object { Join-Path $_.PSPath $service } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $key) { throw 'The registry key of the service is not where it was expected.' }
    $acl = Get-Acl $key
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($grant in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-19', 'ReadKey'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $grant[0]
        $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule $sid, $grant[1], 'ContainerInherit', 'None', 'Allow'))
    }
    Set-Acl $key $acl

    $before = @(Get-SetupCodes).Count
    & (Get-Erlsrv) start $service | Out-Null
}
catch {
    if ($restartDatabase) { try { Start-Service $database } catch { } }
    if ($restartService) { try { & (Get-Erlsrv) start $service | Out-Null } catch { } }
    throw
}

$scheme = if ($values['DOKKIT_CERT']) { 'https' } else { 'http' }
$shown = if ($values['DOKKIT_CERT']) { $values['PHX_HOST'] } else { 'localhost' }
Write-Host "Dokkit is at ${scheme}://${shown}:$($values['PORT'])"
if (-not $values['DOKKIT_CERT']) {
    Write-Host 'It has no certificate, so only this machine can use it. Other machines need -Cert and -CertKey, or a proxy that holds a certificate.'
}
if (-not $upgrade) {
    Write-Host 'Waiting for the setup code.'
    $code = $null
    for ($i = 0; $i -lt 60 -and -not $code; $i++) {
        Start-Sleep -Seconds 1
        $codes = @(Get-SetupCodes)
        if ($codes.Count -gt $before) { $code = $codes[-1] }
    }
    if ($code) { Write-Host "The first visit asks for this setup code: $code" }
    else { Write-Host "The first visit asks for a setup code. It is in $logs\dokkit.log." }
}
