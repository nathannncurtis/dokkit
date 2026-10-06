@{
    RootModule           = 'Dokkit.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '7d0a4b52-3c1e-4f6a-9b8d-2e5c1a7f4d63'
    Description          = 'The Dokkit client library'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Start-Dokkit', 'Send-DokkitBeat', 'Send-DokkitCheck', 'Send-DokkitMetric', 'Write-DokkitLog', 'Send-DokkitProgress', 'Invoke-DokkitJob', 'Send-DokkitError', 'Send-Dokkit')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{ PSData = @{ LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0' } }
}
