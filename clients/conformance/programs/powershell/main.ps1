param([string]$Tag)
Import-Module (Join-Path $PSScriptRoot '..\..\..\powershell\Dokkit.psd1') -Force
Start-Dokkit -Version '9.9.9'
Send-DokkitBeat -Name 'conf-beat' -EverySeconds 60
Invoke-DokkitJob -Name 'conf-job' -Work { }
Send-DokkitCheck -Name 'conf-check' -State ok -Value 1
Send-DokkitMetric -Name 'conf.metric' -Value 5 -Unit 'n'
Write-DokkitLog -Level info -Message "conformance $Tag"
class ConformanceError : System.Exception {}
try { throw [ConformanceError]::new() } catch { Send-DokkitError $_ }
Send-Dokkit
