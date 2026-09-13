[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-Panel { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$panelFixture = @{ ReadFails=$false; ProvisionedReadFails=$false; ActionFails=$false; Malformed=$false; Calls=[System.Collections.Generic.List[object]]::new() }
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
    # Simulate elevated inventory availability using only fixture backends.
    $canInspectProvisioned = $true
    Refresh-View
    Assert-Panel (@(Get-CheckedCleanupEntries).Count -eq 0 -and -not $debloat.IsEnabled) 'Cleanup must start with no checked entries.'
    $checkAll.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Assert-Panel (@(Get-CheckedCleanupEntries).Count -eq 2 -and $debloat.IsEnabled) 'Check all missed entries.'
    $candidates.Items[0].IsChecked=$false
    $chosen=@(Get-CheckedCleanupEntries)
    Assert-Panel ($chosen.Count -eq 1 -and $chosen[0].Scope -eq 'Provisioned') 'Unchecking installed entry also affected provisioned choice.'
    $confirmation=Get-CleanupConfirmation -Entries $chosen
    Assert-Panel ($confirmation.Contains('[provisioned for new accounts]') -and -not $confirmation.Contains('[this account]')) 'Confirmation included unchecked entry.'
    $chosenJson=ConvertTo-Json -InputObject @($chosen | Select-Object Name,FullName,Scope) -Compress
    $uncheckAll.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Assert-Panel (@(Get-CheckedCleanupEntries).Count -eq 0 -and -not $debloat.IsEnabled) 'Uncheck all failed.'
    $panelFixture.ProvisionedReadFails = $true
    Refresh-View
    Assert-Panel ($viewState.ReadSucceeded -and $candidates.Items.Count -eq 1 -and $candidates.Items[0].Tag.Scope -eq 'CurrentUser') 'Provisioning read denial exposed unverified choices or hid available current-user apps.'
    Assert-Panel ($window.FindName('ProvisionedNotice').Text.Contains('could not be inspected')) 'Provisioning read denial was hidden.'
    $panelFixture.ProvisionedReadFails = $false
    $canInspectProvisioned = $false
    Refresh-View
    Assert-Panel ($candidates.Items.Count -eq 1 -and $window.FindName('ProvisionedNotice').Text.Contains('administrator')) 'Non-elevated preview exposed provisioned choices.'
    $canInspectProvisioned = $true
    Refresh-View
    $beforeCalls=$panelFixture.Calls.Count
    $failed=$false
    try { Invoke-GuardAction -Action DebloatApply } catch { $failed=$true }
    Assert-Panel ($failed -and $panelFixture.Calls.Count -eq $beforeCalls) 'Empty cleanup invoked backend.'
    $expectedBackupRoot = Join-Path $env:LOCALAPPDATA 'WindowsPrivacyGuard\backups'
    Assert-Panel ($backupRoot -eq $expectedBackupRoot) 'Default GUI backup location depends on the working directory.'
    $backupRoot = Join-Path $panelTestRoot 'backups'
    $seenBackups = [System.Collections.Generic.HashSet[string]]::new()
    for ($round = 1; $round -le 2; $round++) {
        foreach ($action in @('PrivacyApply', 'DebloatApply', 'NetworkApply')) {
            Invoke-GuardAction -Action $action -ProgramPath 'C:\Fixture Only\recorder.exe' -SelectionJson $chosenJson
            $call = $panelFixture.Calls[$panelFixture.Calls.Count - 1]
            Assert-Panel ($call.Mode -eq 'Apply' -and $call.BackupFile.StartsWith($backupRoot + '\')) 'Apply did not receive a stable, explicit backup path.'
            Assert-Panel ($seenBackups.Add($call.BackupFile)) 'An action reused a backup filename.'
            Assert-Panel (Test-Path -LiteralPath $call.BackupFile) 'Fixture backup was not created.'
            Assert-Panel ($lastAction.Text.Contains($call.BackupFile) -and -not $lastAction.Text.StartsWith('Action failed')) 'Action result or backup path was lost.'
            $remembered = $lastAction.Text
            Refresh-View
            Assert-Panel ($lastAction.Text -eq $remembered) 'Refresh erased action/recovery information.'
            if ($action -eq 'NetworkApply') { Assert-Panel ($call.ProgramPath -eq 'C:\Fixture Only\recorder.exe') 'Network apply changed the selected program path.' }
            if ($action -eq 'DebloatApply') {
                Assert-Panel ($call.SelectionJson -ceq $chosenJson) 'Backend did not receive exactly the checked selection.'
                Assert-Panel (@(Get-CheckedCleanupEntries).Count -eq 0 -and -not $debloat.IsEnabled) 'Refresh retained stale selections.'
            }
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
