# What the test runs against its local server.
param([int]$Port)
Import-Module "$PSScriptRoot\Dokkit.psm1"

Send-DokkitBeat ignored
Start-Dokkit -Version '2.3.0' -Url "http://127.0.0.1:$Port/" -Key 'dka_test'
Send-DokkitBeat worker -EverySeconds 30
Send-DokkitCheck queue-age degraded -Value 14 -Note 'oldest item is "14" minutes old'
Write-DokkitLog error 'Upload failed'
try {
    Invoke-DokkitJob nightly-purge {
        Send-DokkitProgress 4000 9000
        throw [InvalidOperationException]::new('patient 4411')
    }
}
catch {
}
Send-Dokkit
