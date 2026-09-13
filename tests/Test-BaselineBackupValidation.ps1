[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$validationSourcePath = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-WindowsPrivacyBaseline.ps1')).Path
$validationSource = Get-Content -LiteralPath $validationSourcePath -Raw
$tokens = $null
$errors = $null
$validationAst = [System.Management.Automation.Language.Parser]::ParseFile($validationSourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Baseline parsing failed.' }
$validationFunctions = $validationAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
$originalReader = ($validationFunctions | Where-Object Name -eq 'Get-ValueState').Extent.Text
$replacements = @{
    'Test-IsAdministrator' = 'function Test-IsAdministrator { $true }'
    'Get-ValueState' = @'
function Get-ValueState {
    param($Control)
    [pscustomobject]@{ Id=$Control.Id; Path=$Control.HivePath; Name=$Control.Name; Exists=$true; CurrentValue=42; PropertyType='DWord' }
}
'@
    'Set-DwordControl' = 'function Set-DwordControl { param($Control) $backupFixture.Applied.Add($Control.Id) }'
    'Restore-Control' = 'function Restore-Control { param($Entry) $backupFixture.Restored.Add($Entry.Id) }'
}
foreach ($name in $replacements.Keys) {
    $definition = $validationFunctions | Where-Object Name -eq $name
    $validationSource = $validationSource.Replace($definition.Extent.Text, $replacements[$name])
}
$validationProgram = [scriptblock]::Create($validationSource)
$backupFixture = @{ Applied=[System.Collections.Generic.List[string]]::new(); Restored=[System.Collections.Generic.List[string]]::new() }
function Assert-Backup { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$backupTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('WPG-BackupTest-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $backupTestRoot)
$priorLocalAppData = $env:LOCALAPPDATA
try {
    # The real default-location code writes only into this temporary environment.
    $env:LOCALAPPDATA = $backupTestRoot
    $firstBackupPath = $null
    for ($round = 1; $round -le 2; $round++) {
        $backupFixture.Applied.Clear()
        $backupFixture.Restored.Clear()
        $result = (& $validationProgram -Mode Apply) | ConvertFrom-Json
        Assert-Backup ($backupFixture.Applied.Count -eq 7) 'Fixture apply did not cover seven controls.'
        Assert-Backup ($result.BackupFile.StartsWith((Join-Path $backupTestRoot 'WindowsPrivacyGuard\backups\'))) 'Default backup was not under LocalAppData.'
        Assert-Backup ($result.BackupFile -ne $firstBackupPath) 'Repeated apply reused a backup filename.'
        if ($round -eq 1) { $firstBackupPath = $result.BackupFile }
        & $validationProgram -Mode Rollback -BackupFile $result.BackupFile | Out-Null
        Assert-Backup ($backupFixture.Restored.Count -eq 7) 'Valid backup was not restored.'
    }
    $goodJson = Get-Content -LiteralPath $firstBackupPath -Raw
    $invalidFile = Join-Path $backupTestRoot 'invalid.json'
    $cases = @('incomplete', 'duplicate', 'unknown-path', 'unknown-name', 'wrong-exists-type', 'unsupported-value-type', 'wrong-document', 'broken-json')
    foreach ($case in $cases) {
        $entries = ConvertFrom-Json -InputObject $goodJson
        switch ($case) {
            'incomplete' { $entries = @($entries[0..5]) }
            'duplicate' { $entries[6] = $entries[0] }
            'unknown-path' { $entries[6].Path = 'HKLM:\SOFTWARE\UnrelatedFixture' }
            'unknown-name' { $entries[6].Name = 'UnrelatedValue' }
            'wrong-exists-type' { $entries[6].Exists = 'true' }
            'unsupported-value-type' { $entries[6].PropertyType = 'Unknown' }
            'wrong-document' { $entries = [pscustomobject]@{ RuleName='Fixture firewall'; Program='C:\fixture.exe' } }
        }
        ConvertTo-Json -InputObject $entries -Depth 6 | Set-Content -LiteralPath $invalidFile -Encoding UTF8
        if ($case -eq 'broken-json') { '{' | Set-Content -LiteralPath $invalidFile }
        $backupFixture.Restored.Clear()
        $rejected = $false
        try { & $validationProgram -Mode Rollback -BackupFile $invalidFile | Out-Null } catch { $rejected = $true }
        Assert-Backup ($rejected -and $backupFixture.Restored.Count -eq 0) "Invalid backup $case was not rejected before all registry writes."
    }
    # Exercise the real reader: access denial must not be treated as an absent value.
    . ([scriptblock]::Create($originalReader))
    function Get-Item { [CmdletBinding()] param($LiteralPath) throw [UnauthorizedAccessException]::new('Injected access denial') }
    $rejected = $false
    try { Get-ValueState -Control ([pscustomobject]@{ HivePath='HKLM:\Fixture'; Name='Fixture' }) | Out-Null }
    catch { $rejected = $_.Exception.Message -eq 'Injected access denial' }
    Assert-Backup $rejected 'Registry read access denial was incorrectly backed up as absence.'
    Remove-Item Function:\Get-Item
    [pscustomobject]@{ Result='PASS'; ApplyRollbackRounds=2; InvalidBackupsRejectedBeforeWrites=$cases.Count; ReadDenial='Propagated'; RealRegistryWrites=0 } | ConvertTo-Json
}
finally {
    $env:LOCALAPPDATA = $priorLocalAppData
    $resolvedBackupTest = [IO.Path]::GetFullPath($backupTestRoot)
    if (-not $resolvedBackupTest.StartsWith(([IO.Path]::GetTempPath().TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedBackupTest) -notlike 'WPG-BackupTest-*') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolvedBackupTest -Recurse -Force
}
