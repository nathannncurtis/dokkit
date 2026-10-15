# Installs the Dokkit server on this Windows machine as a service, or upgrades one that is
# already here. Run it from an administrator PowerShell, in the folder of an unpacked release.
# Or piped from the site, which fetches the release (its SHA256SUMS must carry a valid signature from the release key;
# DOKKIT_RELEASE_URL names another release zip, DOKKIT_RELEASE_KEY a machine key for a Dokkit server that holds it) and, the first time, a Postgres:
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

# The program on a machine installed before it had folders of its own lives in these two folders.
# Installing over it would change what the program's service runs and may read.
$programData = Join-Path $env:ProgramData 'Dokkit'
$programHere = (Test-Path (Join-Path $programData 'config.json')) -or (Test-Path (Join-Path $programData 'spool'))
$programExe = (Test-Path (Join-Path $To 'dokkit.exe')) -and -not (Test-Path (Join-Path $To 'bin\dokkit.bat'))
if (-not (Test-Path (Join-Path $programData 'settings.env')) -and ($programHere -or $programExe)) {
    throw ("The Dokkit program is installed in $programData and $To, and there is no server there. Nothing was changed. " +
        "The server needs those folders to itself. From an administrator prompt, run 'service update' with a current copy of the program, " +
        "which moves the program to its own folders (DokkitProgram under Program Files and ProgramData) and leaves the old files where they are. " +
        "Then delete config.json, spool, dokkit.log and dokkit.exe from the old folders, and run this again.")
}

# Piped from the site there is no release beside this script, so it fetches one, and a Postgres
# for a first install that named no database, then runs the copy inside that release.
if (-not $PSScriptRoot -or -not (Test-Path (Join-Path $PSScriptRoot 'bin\dokkit.bat'))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $work = Join-Path $env:TEMP ('dokkit-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $work | Out-Null
    function Test-Ed25519([byte[]]$Key, [byte[]]$Sig, [byte[]]$Message) {
        if ($Key.Length -ne 32 -or $Sig.Length -ne 64) { return $false }
        $BI = [System.Numerics.BigInteger]
        $Prime = $BI::Pow(2, 255) - 19
        $Order = $BI::Pow(2, 252) + $BI::Parse('27742317777372353535851937790883648493')
        function Mod([System.Numerics.BigInteger]$a) { $r = $a % $Prime; if ($r.Sign -lt 0) { $r + $Prime } else { $r } }
        function Inv([System.Numerics.BigInteger]$a) { $BI::ModPow((Mod $a), $Prime - 2, $Prime) }
        function FromLE([byte[]]$b) { $BI::new([byte[]]($b + [byte]0)) }
        $Coef = Mod ((Inv 121666) * -121665)
        $RootM1 = $BI::ModPow(2, ($Prime - 1) / 4, $Prime)
        function RecoverX([System.Numerics.BigInteger]$y, [int]$sign) {
            $y2 = Mod ($y * $y)
            $x2 = Mod (($y2 - 1) * (Inv ($Coef * $y2 + 1)))
            $x = $BI::ModPow($x2, ($Prime + 3) / 8, $Prime)
            if (-not (Mod ($x * $x - $x2)).IsZero) { $x = Mod ($x * $RootM1) }
            if (-not (Mod ($x * $x - $x2)).IsZero) { return $null }
            if ((-not $x.IsEven) -ne ($sign -eq 1)) { $x = $Prime - $x }
            $x
        }
        function Decode([byte[]]$b) {
            $top = $b[31]
            $c = [byte[]]$b.Clone(); $c[31] = $top -band 127
            $y = FromLE $c
            if ($y -ge $Prime) { return $null }
            $x = RecoverX $y ($top -shr 7)
            if ($null -eq $x) { return $null }
            , @($x, $y, $BI::One, (Mod ($x * $y)))
        }
        function Add-Point($p, $q) {
            $a = Mod (($p[1] - $p[0]) * ($q[1] - $q[0]))
            $b = Mod (($p[1] + $p[0]) * ($q[1] + $q[0]))
            $c = Mod ($p[3] * $q[3] * $Coef * 2)
            $d = Mod ($p[2] * $q[2] * 2)
            $e = $b - $a; $f = $d - $c; $g = $d + $c; $h = $b + $a
            , @((Mod ($e * $f)), (Mod ($g * $h)), (Mod ($f * $g)), (Mod ($e * $h)))
        }
        function Mul-Point([System.Numerics.BigInteger]$s, $pt) {
            $q = @($BI::Zero, $BI::One, $BI::One, $BI::Zero)
            $bytes = $s.ToByteArray()
            for ($i = $bytes.Length * 8 - 1; $i -ge 0; $i--) {
                $q = Add-Point $q $q
                if ((($bytes[[math]::Floor($i / 8)] -shr ($i % 8)) -band 1) -eq 1) { $q = Add-Point $q $pt }
            }
            $q
        }
        $By = Mod ((Inv 5) * 4)
        $Bx = RecoverX $By 0
        $BasePt = @($Bx, $By, $BI::One, (Mod ($Bx * $By)))
        $SigR = Decode $Sig[0..31]
        $PubA = Decode $Key
        $SigS = FromLE $Sig[32..63]
        if ($null -eq $SigR -or $null -eq $PubA -or $SigS -ge $Order) { return $false }
        $sha = [Security.Cryptography.SHA512]::Create()
        $h = (FromLE $sha.ComputeHash([byte[]]($Sig[0..31] + $Key + $Message))) % $Order
        $left = Mul-Point $SigS $BasePt
        $right = Add-Point $SigR (Mul-Point $h $PubA)
        (Mod ($left[0] * $right[2] - $right[0] * $left[2])).IsZero -and (Mod ($left[1] * $right[2] - $right[1] * $left[2])).IsZero
    }
    $releaseKey = 'xX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk='
    $headers = @{}
    if ($env:DOKKIT_RELEASE_KEY) { $headers.Authorization = "Bearer $($env:DOKKIT_RELEASE_KEY)" }
    # Nothing is unpacked until its SHA-256 matches the one expected.
    $fetch = {
        param($Url, $Name, $Sha256, $Headers)
        Write-Host "Fetching $Url"
        $zip = Join-Path $work "$Name.zip"
        Invoke-WebRequest -Uri $Url -OutFile $zip -Headers $Headers -UseBasicParsing
        $stream = [IO.File]::OpenRead($zip)
        try { $got = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-' }
        finally { $stream.Dispose() }
        if ($got -ne $Sha256) { throw "$Url is not the file expected: its SHA-256 is $got, not $Sha256. Nothing was installed." }
        Expand-Archive -Path $zip -DestinationPath (Join-Path $work $Name)
    }
    $releaseUrl = 'https://github.com/nathannncurtis/dokkit/releases/latest/download/dokkit-windows-x64.zip'
    if ($env:DOKKIT_RELEASE_URL) { $releaseUrl = $env:DOKKIT_RELEASE_URL }
    # The release's SHA256SUMS must carry a valid signature from the release key, and the zip must be in it.
    $releaseBase = $releaseUrl.Substring(0, $releaseUrl.LastIndexOf('/'))
    $releaseName = $releaseUrl.Substring($releaseUrl.LastIndexOf('/') + 1)
    Write-Host "Fetching $releaseBase/SHA256SUMS"
    Invoke-WebRequest -Uri "$releaseBase/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS') -Headers $headers -UseBasicParsing
    Invoke-WebRequest -Uri "$releaseBase/SHA256SUMS.sig" -OutFile (Join-Path $work 'SHA256SUMS.sig') -Headers $headers -UseBasicParsing
    $sums = [IO.File]::ReadAllBytes((Join-Path $work 'SHA256SUMS'))
    try { $sig = [Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $work 'SHA256SUMS.sig'))).Trim()) } catch { $sig = [byte[]]@() }
    if (-not (Test-Ed25519 ([Convert]::FromBase64String($releaseKey)) $sig $sums)) {
        throw 'The signature of SHA256SUMS does not check against the release key. Nothing was installed.'
    }
    $lines = [Text.Encoding]::UTF8.GetString($sums) -split "`n"
    if ($lines[0] -notmatch '^version v') { throw 'SHA256SUMS does not start with a version line. Nothing was installed.' }
    $releaseSha = $null
    foreach ($line in $lines[1..($lines.Length - 1)]) {
        $parts = $line.Trim() -split '\s+', 2
        if ($parts.Length -eq 2 -and $parts[1].TrimStart('*') -eq $releaseName) { $releaseSha = $parts[0].ToUpper(); break }
    }
    if (-not $releaseSha) { throw "The signed list has no $releaseName. Nothing was installed." }
    & $fetch $releaseUrl 'dokkit' $releaseSha $headers
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
        & $fetch $postgresUrl 'postgres' $postgresSha @{}
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
# Copies only the files that are new or different. A file Windows still has open is nearly always
# one that did not change, such as the service wrapper, and is left alone.
# Reads a file other programs may have open.
function Get-Sha256([string]$Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) }
    finally { $stream.Dispose() }
}
function Copy-Changed([string]$From, [string]$Into) {
    $root = (Resolve-Path $From).Path.TrimEnd('\')
    foreach ($file in Get-ChildItem $root -Recurse -File) {
        $target = Join-Path $Into $file.FullName.Substring($root.Length).TrimStart('\')
        if ((Test-Path $target) -and (Get-Item $target).Length -eq $file.Length -and
            (Get-Sha256 $target) -eq (Get-Sha256 $file.FullName)) { continue }
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $file.FullName $target -Force
    }
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
if ($PSBoundParameters.ContainsKey('Address') -or -not $values['PHX_HOST']) { $values['PHX_HOST'] = $Address.ToLower() }
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
        # The port mapper outlives the server and keeps its own file open.
        $epmd = Join-Path (Split-Path (Get-Erlsrv)) 'epmd.exe'
        if (Test-Path $epmd) { & $epmd -kill | Out-Null }
    }

    Write-Host "Copying the server to $To."
    New-Item -ItemType Directory -Force $To | Out-Null
    # A file that has just been run, or that a scanner has open, is free again within moments.
    for ($try = 1; ; $try++) {
        try { Copy-Changed $PSScriptRoot $To; break }
        catch {
            if ($try -ge 30) { throw }
            if ($try -eq 1) { Write-Host "Waiting for a file that is in use: $($_.Exception.Message)" }
            Start-Sleep -Seconds 2
        }
    }

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
    $releases = if ($values['DOKKIT_RELEASES']) { $values['DOKKIT_RELEASES'] } else { Join-Path $folder 'releases' }
    New-Item -ItemType Directory -Force $releases | Out-Null
    & icacls $releases /inheritance:r /grant:r "${administrators}:(OI)(CI)F" "${system}:(OI)(CI)F" "${localService}:(OI)(CI)M" | Out-Null
    Test-Ok 'Locking down the releases folder'
    $tls = if ($values['DOKKIT_TLS']) { $values['DOKKIT_TLS'] } else { Join-Path $folder 'tls' }
    New-Item -ItemType Directory -Force $tls | Out-Null
    & icacls $tls /inheritance:r /grant:r "${administrators}:(OI)(CI)F" "${system}:(OI)(CI)F" "${localService}:(OI)(CI)M" | Out-Null
    Test-Ok 'Locking down the tls folder'
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
                # initdb gives up its administrator rights, so until it is done the person
                # installing is named on the two things it touches.
                $installer = '*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                New-Item -ItemType Directory -Force $data | Out-Null
                & icacls $data /grant "${installer}:(OI)(CI)F" | Out-Null
                Test-Ok 'Letting initdb write the data folder'
                & icacls $passwordFile /grant "${installer}:R" | Out-Null
                Test-Ok 'Letting initdb read the password'
                & (Join-Path $pg 'bin\initdb.exe') -D $data -U dokkit --pwfile=$passwordFile -A scram-sha-256 -E UTF8 --locale=C | Out-Null
                $made = $LASTEXITCODE
                & icacls $data /remove $installer /T /C | Out-Null
                & icacls $passwordFile /remove $installer | Out-Null
                if ($made -ne 0) { throw 'Postgres could not make its data folder.' }
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
    # The wrapper keeps the cookie in this key, which every user can read until it is locked.
    $key = Get-ChildItem 'HKLM:\SOFTWARE\Ericsson\Erlang\ErlSrv' -ErrorAction Stop |
        ForEach-Object { Join-Path $_.PSPath $service } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $key) { throw 'The registry key of the service is not where it was expected.' }
    # Windows knows the service by a name the wrapper made up; $service is only what it shows.
    $real = (Get-ItemProperty $key).InternalServiceName
    if (-not $real) { throw "The wrapper did not record the service's own name in $key." }
    # It is registered as the system account and never started as it.
    $said = & sc.exe config $real obj= 'NT AUTHORITY\LocalService' password= '""' start= auto
    if ($LASTEXITCODE -ne 0) { throw "Making the service run as Local Service failed: $said" }
    if (Get-Service $database -ErrorAction SilentlyContinue) {
        $said = & sc.exe config $real depend= $database
        if ($LASTEXITCODE -ne 0) { throw "Making the service wait for its Postgres failed: $said" }
    }
    $account = (& sc.exe qc $real | Select-String 'SERVICE_START_NAME').Line
    if ($account -notmatch 'LocalService') { throw "The service would not run as Local Service: $account" }
    # The wrapper is the service process, so its own setting is what restarts it.
    $said = & (Get-Erlsrv) set $service -onfail restart
    if ($LASTEXITCODE -ne 0) { throw "Making the service restart when it stops failed: $said" }
    $acl = Get-Acl $key
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($grant in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-19', 'ReadKey'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $grant[0]
        $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule $sid, $grant[1], 'ContainerInherit', 'None', 'Allow'))
    }
    Set-Acl $key $acl

    $before = @(Get-SetupCodes).Count
    $said = & (Get-Erlsrv) start $service
    $started = $LASTEXITCODE

    # It is not installed until it answers.
    Write-Host 'Waiting for the server to answer.'
    $up = $false
    for ($i = 0; $i -lt 90 -and -not $up; $i++) {
        $probe = New-Object Net.Sockets.TcpClient
        try { $probe.Connect('127.0.0.1', [int]$values['PORT']); $up = $true }
        catch { Start-Sleep -Seconds 1 }
        finally { $probe.Close() }
    }
    if (-not $up) {
        Write-Host "The wrapper said ($started): $said"
        & sc.exe query $real | Write-Host
        $log = Join-Path $logs 'dokkit.log'
        if (Test-Path $log) { Write-Host "The end of ${log}:"; Get-Content $log -Tail 40 | Write-Host }
        else { Write-Host "There is no $log, so the server never got as far as its settings." }
        throw "The service did not answer on port $($values['PORT'])."
    }
}
catch {
    if ($restartDatabase) { try { Start-Service $database } catch { } }
    if ($restartService) { try { & (Get-Erlsrv) start $service | Out-Null } catch { } }
    throw
}

# With its own certificate it is meant to be reached from other machines.
if ($values['DOKKIT_CERT']) {
    if (Get-NetFirewallRule -DisplayName 'Dokkit' -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -DisplayName 'Dokkit' -LocalPort $values['PORT']
    }
    else {
        New-NetFirewallRule -DisplayName 'Dokkit' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $values['PORT'] | Out-Null
    }
    Write-Host "Windows Firewall lets port $($values['PORT']) in."
}

$scheme = if ($values['DOKKIT_CERT']) { 'https' } else { 'http' }
$shown = if ($values['DOKKIT_CERT']) { $values['PHX_HOST'] } else { 'localhost' }
Write-Host "Dokkit is at ${scheme}://${shown}:$($values['PORT'])"
if (-not $values['DOKKIT_CERT']) {
    Write-Host 'It has no certificate, so only this machine can use it. Other machines need -Cert and -CertKey, or a proxy that holds a certificate.'
}
# A first install that stopped partway comes back as an upgrade and still has no account.
Write-Host 'Waiting for the setup code.'
$wait = if ($upgrade) { 15 } else { 60 }
$code = $null
for ($i = 0; $i -lt $wait -and -not $code; $i++) {
    Start-Sleep -Seconds 1
    $codes = @(Get-SetupCodes)
    if ($codes.Count -gt $before) { $code = $codes[-1] }
}
if ($code) { Write-Host "The first visit asks for this setup code: $code" }
elseif (-not $upgrade) { Write-Host "The first visit asks for a setup code. It is in $logs\dokkit.log." }
else { Write-Host 'It printed no setup code, so it already has an account.' }
