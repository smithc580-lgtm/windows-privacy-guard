[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-Panel { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$panelFixture = @{ ReadFails=$false; ActionFails=$false; Malformed=$false; Calls=[System.Collections.Generic.List[object]]::new() }
$panelTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('WPG-PanelTest-' + [guid]::NewGuid().ToString('N'))
$panelSourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
[void](New-Item -ItemType Directory -Path $panelTestRoot)
$fixturePanel = Join-Path $panelTestRoot 'Start-WindowsPrivacyGuard.ps1'
try {
    Copy-Item -LiteralPath (Join-Path $panelSourceRoot 'scripts\Start-WindowsPrivacyGuard.ps1') -Destination $fixturePanel
    foreach ($name in @('Invoke-WindowsPrivacyBaseline.ps1', 'Invoke-WindowsDebloat.ps1', 'Set-LocalOnlyMicrophoneApp.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\ControlPanelBackend.ps1') -Destination (Join-Path $panelTestRoot $name)
    }
    # Run the actual panel source against fixture backends only, without a visible window.
    . $fixturePanel -TestMode | Out-Null
    $expectedBackupRoot = Join-Path $env:LOCALAPPDATA 'WindowsPrivacyGuard\backups'
    Assert-Panel ($backupRoot -eq $expectedBackupRoot) 'Default GUI backup location depends on the working directory.'
    $backupRoot = Join-Path $panelTestRoot 'backups'
    $seenBackups = [System.Collections.Generic.HashSet[string]]::new()
    for ($round = 1; $round -le 2; $round++) {
        foreach ($action in @('PrivacyApply', 'DebloatApply', 'NetworkApply')) {
            Invoke-GuardAction -Action $action -ProgramPath 'C:\Fixture Only\recorder.exe'
            $call = $panelFixture.Calls[$panelFixture.Calls.Count - 1]
            Assert-Panel ($call.Mode -eq 'Apply' -and $call.BackupFile.StartsWith($backupRoot + '\')) 'Apply did not receive a stable, explicit backup path.'
            Assert-Panel ($seenBackups.Add($call.BackupFile)) 'An action reused a backup filename.'
            Assert-Panel (Test-Path -LiteralPath $call.BackupFile) 'Fixture backup was not created.'
            Assert-Panel ($lastAction.Text.Contains($call.BackupFile) -and -not $lastAction.Text.StartsWith('Action failed')) 'Action result or backup path was lost.'
            $remembered = $lastAction.Text
            Refresh-View
            Assert-Panel ($lastAction.Text -eq $remembered) 'Refresh erased action/recovery information.'
            if ($action -eq 'NetworkApply') { Assert-Panel ($call.ProgramPath -eq 'C:\Fixture Only\recorder.exe') 'Network apply changed the selected program path.' }
            if ($action -ne 'DebloatApply') {
                $undoAction = if ($action -eq 'PrivacyApply') { 'PrivacyUndo' } else { 'NetworkUndo' }
                $selectedBackup = $call.BackupFile
                Invoke-GuardAction -Action $undoAction -BackupFile $selectedBackup
                $undoCall = $panelFixture.Calls[$panelFixture.Calls.Count - 1]
                Assert-Panel ($undoCall.Mode -eq 'Rollback' -and $undoCall.BackupFile -ceq $selectedBackup) 'Undo did not receive the exact selected backup.'
                Assert-Panel ($lastAction.Text.Contains($selectedBackup)) 'Undo status lost the backup path.'
            }
        }
    }
    $panelFixture.ActionFails = $true
    $failed = $false
    try { Invoke-GuardAction -Action PrivacyApply } catch { $failed = $_.Exception.Message -eq 'Injected action failure' }
    Assert-Panel ($failed -and $lastAction.Text.Contains('Changes may be partial. Recovery backup:')) 'Partial apply failure hid the recovery backup or reported success.'
    $remembered = $lastAction.Text
    Refresh-View
    Assert-Panel ($lastAction.Text -eq $remembered) 'Refresh hid an action failure.'
    $panelFixture.ActionFails = $false
    $panelFixture.Malformed = $true
    $failed = $false
    try { Invoke-GuardAction -Action NetworkApply -ProgramPath 'C:\Fixture Only\recorder.exe' } catch { $failed = $true }
    Assert-Panel ($failed -and $lastAction.Text.StartsWith('Action failed:')) 'Malformed action result passed.'
    $panelFixture.Malformed = $false
    $panelFixture.ReadFails = $true
    Refresh-View
    Assert-Panel (-not $viewState.ReadSucceeded -and $status.Text -eq 'Unable to read current settings') 'Audit failure was hidden.'
    $window.Close()
    $failed = $false
    try { . $fixturePanel -TestMode | Out-Null } catch { $failed = $_.Exception.Message -like 'Control-panel read check failed:*' }
    Assert-Panel $failed 'TestMode reported PASS after a failed read.'
    $window.Close()
    $panelFixture.ReadFails = $false
    . $fixturePanel -TestMode -PreviewOnly | Out-Null
    foreach ($button in @($apply, $debloat, $localOnly, $undoPrivacy, $undoNetwork)) {
        Assert-Panel (-not $button.IsEnabled) 'Preview left a mutation button enabled.'
    }
    $beforeCalls = $panelFixture.Calls.Count
    $failed = $false
    try { Invoke-GuardAction -Action PrivacyApply } catch { $failed = $_.Exception.Message -like '*disabled in preview mode*' }
    Assert-Panel ($failed -and $panelFixture.Calls.Count -eq $beforeCalls) 'Preview permitted a mutation through the action helper.'
    $window.Close()
    [pscustomobject]@{ Result='PASS'; WorkflowRounds=2; UniqueApplyBackups=$seenBackups.Count; Undo='Exact backup forwarded'; FailureRecovery='Visible'; Preview='Mutation blocked'; RealSettingsChanged=$false } | ConvertTo-Json
}
finally {
    # Only our unique fixture tree; never the real backup directory.
    $resolvedPanelTest = [IO.Path]::GetFullPath($panelTestRoot)
    $expectedParent = [IO.Path]::GetTempPath().TrimEnd('\') + '\'
    if (-not $resolvedPanelTest.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedPanelTest) -notlike 'WPG-PanelTest-*') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolvedPanelTest -Recurse -Force
}
