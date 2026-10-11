# Puts the dokkit program on this Windows machine. No administrator needed.
#     irm https://dokkit.dev/get.ps1 | iex
# DOKKIT_RELEASE_BASE names another folder that holds the release's files. With a Dokkit server that holds
# the release, that is https://<server>/api/v1/releases/<version>, and DOKKIT_RELEASE_KEY is a machine key
# the server accepts. Whatever the source, SHA256SUMS must carry a valid Ed25519 signature
# (SHA256SUMS.sig) from the release key below and the download must match it, or nothing is installed.
# The signature is checked here, with .NET's BigInteger, so it needs nothing that is not in Windows PowerShell 5.1.
# Run in its own scope, so nothing it sets is left in the session that ran it.
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$releaseKey = 'xX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk='

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

$base = 'https://github.com/nathannncurtis/dokkit/releases/latest/download'
if ($env:DOKKIT_RELEASE_BASE) { $base = $env:DOKKIT_RELEASE_BASE.TrimEnd('/') }
$headers = @{}
if ($env:DOKKIT_RELEASE_KEY) { $headers.Authorization = "Bearer $($env:DOKKIT_RELEASE_KEY)" }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' }
$name = "dokkit-windows-$arch.exe"

$work = Join-Path $env:TEMP ('dokkit-get-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$file = Join-Path $work $name

Write-Host "Fetching $base/SHA256SUMS"
Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS') -Headers $headers -UseBasicParsing
Invoke-WebRequest -Uri "$base/SHA256SUMS.sig" -OutFile (Join-Path $work 'SHA256SUMS.sig') -Headers $headers -UseBasicParsing
$sums = [IO.File]::ReadAllBytes((Join-Path $work 'SHA256SUMS'))
try { $sig = [Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $work 'SHA256SUMS.sig'))).Trim()) } catch { $sig = [byte[]]@() }
if (-not (Test-Ed25519 ([Convert]::FromBase64String($releaseKey)) $sig $sums)) {
    throw 'The signature of SHA256SUMS does not check against the release key. Nothing was installed.'
}
$lines = [Text.Encoding]::UTF8.GetString($sums) -split "`n"
if ($lines[0] -notmatch '^version v') { throw 'SHA256SUMS does not start with a version line. Nothing was installed.' }
$want = $null
foreach ($line in $lines[1..($lines.Length - 1)]) {
    $parts = $line.Trim() -split '\s+', 2
    if ($parts.Length -eq 2 -and $parts[1].TrimStart('*') -eq $name) { $want = $parts[0].ToLower(); break }
}
if (-not $want) { throw "The signed list has no $name. Nothing was installed." }

Write-Host "Fetching $base/$name"
Invoke-WebRequest -Uri "$base/$name" -OutFile $file -Headers $headers -UseBasicParsing
$stream = [IO.File]::OpenRead($file)
try { $got = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-').ToLower() }
finally { $stream.Dispose() }
if ($got -ne $want) { throw "The download's SHA-256 is $got, but the signed list says $want. Nothing was installed." }

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
}
