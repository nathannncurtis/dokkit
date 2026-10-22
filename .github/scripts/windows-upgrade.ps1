# Installs the last published Windows server, then upgrades it to the one just built, as the updater would.
param(
    [Parameter(Mandatory)][string]$Old,
    [Parameter(Mandatory)][string]$New
)
$ErrorActionPreference = 'Stop'

function Expand([string]$Zip, [string]$Name) {
    $dir = Join-Path $env:RUNNER_TEMP $Name
    Expand-Archive $Zip $dir -Force
    $dir
}
function Get-Login {
    for ($i = 0; $i -lt 60; $i++) {
        try { return (Invoke-WebRequest http://127.0.0.1:4000/login -UseBasicParsing).Content }
        catch { Start-Sleep -Seconds 2 }
    }
    throw 'The server did not answer /login.'
}
function Get-Css([string]$Dir) {
    (Get-ChildItem (Join-Path $Dir 'lib\dokkit-*\priv\static\css\dokkit-*.css') | Where-Object Name -match '^dokkit-[0-9a-f]{32}\.css$').Name
}

$old = Expand $Old 'server-old'
& (Join-Path $old 'install.ps1') -Postgres $env:PGROOT
if ((Get-Login) -notmatch [regex]::Escape((Get-Css $old))) { throw 'The first install does not serve its own stylesheet.' }

$erl = { @(Get-Process erl -ErrorAction SilentlyContinue | Where-Object Path -like "$env:ProgramFiles\Dokkit\*").Id }
$before = & $erl
$new = Expand $New 'server-new'
& (Join-Path $new 'install.ps1')
$css = Get-Css $new
if ((Get-Login) -notmatch [regex]::Escape($css)) { throw "After the upgrade the server does not serve $css." }
if (-not (& $erl) -or (Compare-Object @(& $erl) @($before) -IncludeEqual -ExcludeDifferent)) { throw 'The server was not restarted by the upgrade.' }
$root = (Resolve-Path $new).Path
$stale = Get-ChildItem $root -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($root.Length)
    $rel -ne '\releases\COOKIE' -and (Get-FileHash $_.FullName).Hash -ne (Get-FileHash (Join-Path "$env:ProgramFiles\Dokkit" $rel)).Hash
}
if ($stale) { throw "Not upgraded: $(($stale | Select-Object -First 5).FullName -join ', ')" }
Write-Host "Upgraded: every file matches the new build, the server restarted and serves $css."
