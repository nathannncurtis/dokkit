$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\overlays\install.ps1'), [ref]$null, [ref]$null)
$def = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-OwnServices' }, $true)
. ([scriptblock]::Create($def.Extent.Text))

$root = 'C:\Program Files\Dokkit'
$erlsrv = '"C:\Program Files\Dokkit\erts-15.2\bin\erlsrv.exe"'
$fake = @(
    @{ Name = 'dokkit01dd59e0d4f44eb0'; PathName = $erlsrv }
    @{ Name = 'dokkit01dd59e3a0276ed0'; PathName = $erlsrv }
    @{ Name = 'dokkit-server'; PathName = $erlsrv }
    @{ Name = 'dokkit'; PathName = '"C:\Program Files\DokkitProgram\dokkit.exe" watch' }
    @{ Name = 'dokkit-postgres'; PathName = '"C:\Program Files\Dokkit\pgsql\bin\pg_ctl.exe" runservice' }
    @{ Name = 'dokkit01dd59f5c9944560'; PathName = '"C:\Program Files\Contoso\erts-15.2\bin\erlsrv.exe"' }
    @{ Name = 'ErlangApp'; PathName = $erlsrv }
    @{ Name = 'dokkitZZZZZZZZZZZZZZZZ'; PathName = $erlsrv }
) | ForEach-Object { [pscustomobject]$_ }

$got = (Get-OwnServices $fake $root).Name
$want = 'dokkit01dd59e0d4f44eb0', 'dokkit01dd59e3a0276ed0', 'dokkit-server'
Write-Host "removed: $($got -join ', ')"
Write-Host "installed as: dokkit-server (display name Dokkit)"
if (Compare-Object $got $want) { Write-Host 'FAIL'; exit 1 }
if (@(Get-OwnServices @() $root).Count -ne 0) { Write-Host 'FAIL: first install'; exit 1 }
Write-Host 'first install: nothing to remove'
Write-Host 'PASS'
