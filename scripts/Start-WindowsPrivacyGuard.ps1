[CmdletBinding()]
param(
    [switch] $TestMode,
    [switch] $PreviewOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    # A desktop launch must not hide a startup error with its console window.
    if ($TestMode -or $PreviewOnly) { throw $_ }
    $startupError = ($_ | Out-String) + [Environment]::NewLine + $_.ScriptStackTrace
    $startupLog = Join-Path $env:LOCALAPPDATA 'WindowsPrivacyGuard\logs\startup-error.txt'
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $startupLog) -Force | Out-Null
        ([DateTime]::UtcNow.ToString('o') + [Environment]::NewLine + $startupError) |
            Set-Content -LiteralPath $startupLog -Encoding UTF8
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show("Windows Privacy Guard could not start.`n`n$startupError`nDetails: $startupLog", 'Windows Privacy Guard startup error') | Out-Null
    } catch { Write-Error $startupError -ErrorAction Continue }
    exit 1
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $TestMode -and -not $PreviewOnly -and -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`""
    )
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

$root = Split-Path -Parent $PSScriptRoot
$baselineScript = Join-Path $PSScriptRoot 'Invoke-WindowsPrivacyBaseline.ps1'
$debloatScript = Join-Path $PSScriptRoot 'Invoke-WindowsDebloat.ps1'
$localOnlyScript = Join-Path $PSScriptRoot 'Set-LocalOnlyMicrophoneApp.ps1'
$backupRoot = Join-Path $env:LOCALAPPDATA 'WindowsPrivacyGuard\backups'
$viewState = @{ ReadSucceeded = $false }

function Get-GuardWindowBounds {
    param([Parameter(Mandatory = $true)] [Windows.Rect] $WorkArea)
    if ($WorkArea.IsEmpty -or $WorkArea.Width -le 0 -or $WorkArea.Height -le 0) {
        throw 'Windows did not report a usable desktop work area.'
    }
    # WPF work-area coordinates include display scaling and exclude the taskbar.
    # Fit the complete native window, including its draggable title bar, on launch.
    $availableWidth = [Math]::Max(1, $WorkArea.Width - 32)
    $availableHeight = [Math]::Max(1, $WorkArea.Height - 32)
    $width = [Math]::Min(880, $availableWidth)
    $height = [Math]::Min(760, $availableHeight)
    [pscustomobject]@{
        Width = $width
        Height = $height
        MinWidth = [Math]::Min(420, $availableWidth)
        MinHeight = [Math]::Min(420, $availableHeight)
        Left = $WorkArea.Left + ($WorkArea.Width - $width) / 2
        Top = $WorkArea.Top + ($WorkArea.Height - $height) / 2
    }
}

[xml] $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Windows Privacy Guard" WindowStyle="SingleBorderWindow" ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="Manual" SizeToContent="Manual" Background="#101820">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Text="Windows Privacy Guard" FontSize="28" FontWeight="Bold" Foreground="White" TextWrapping="Wrap"/>
    <ScrollViewer Name="MainScroll" Grid.Row="1" Margin="0,8,0,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel Margin="0,0,12,0">
      <TextBlock Margin="0,0,0,16" TextWrapping="Wrap" Foreground="#C9D3DC" Text="Restrict selected Windows privacy settings, review optional apps, or block one app's network access. These controls do not guarantee zero telemetry. Defender and Windows Update remain enabled."/>
      <TextBlock Name="PreviewBanner" Visibility="Collapsed" Text="PREVIEW ONLY - system-changing actions are disabled." Foreground="#FFD58A" FontWeight="Bold" Margin="0,0,0,12" TextWrapping="Wrap"/>
      <TextBlock Name="Status" Text="Checking current settings..." Foreground="#9FE3B1" FontSize="16" Margin="0,0,0,12" TextWrapping="Wrap"/>
      <TextBlock Name="Details" TextWrapping="Wrap" Foreground="#DDE6ED"/>
      <TextBlock Text="Optional consumer apps found" Foreground="White" FontWeight="Bold" Margin="0,20,0,6"/>
      <ListBox Name="Candidates" Height="150" Background="#1B2A34" Foreground="White"/>
      <TextBlock Foreground="#C9D3DC" TextWrapping="Wrap" Margin="0,8,0,0" Text="Cleanup removes all listed apps for the current user. Removed apps must be reinstalled manually; a backup is an inventory, not an app restore image."/>
      <TextBlock Name="BackupLocation" Foreground="#C9D3DC" TextWrapping="Wrap" Margin="0,8,0,0"/>
      <TextBlock Foreground="#C9D3DC" TextWrapping="Wrap" Margin="0,8,0,0" Text="Network blocking leaves microphone permission unchanged, but stops calls and uploads from the selected executable. Other apps and helper processes are not covered."/>
    </StackPanel>
    </ScrollViewer>
    <StackPanel Grid.Row="2">
      <TextBlock Text="Last action / recovery" Foreground="White" FontWeight="Bold" Margin="0,16,0,6"/>
      <TextBox Name="LastAction" IsReadOnly="True" TextWrapping="Wrap" MaxHeight="80" VerticalScrollBarVisibility="Auto" Background="#1B2A34" Foreground="White" Padding="10" BorderThickness="0" Text="No changes made in this session."/>
    </StackPanel>
    <WrapPanel Grid.Row="3" Margin="0,16,0,0">
      <Button Name="Refresh" Content="Refresh suggestions" Padding="12,8" Margin="0,0,8,8"/>
      <Button Name="Apply" Content="Apply privacy baseline" Padding="12,8" Margin="0,0,8,8"/>
      <Button Name="UndoPrivacy" Content="Undo privacy settings..." Padding="12,8" Margin="0,0,8,8"/>
      <Button Name="Debloat" Content="Remove listed optional apps" Padding="12,8" Margin="0,0,8,8"/>
      <Button Name="LocalOnly" Content="Block an app's network..." Padding="12,8" Margin="0,0,8,8"/>
      <Button Name="UndoNetwork" Content="Restore app network..." Padding="12,8" Margin="0,0,8,8"/>
    </WrapPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$initialBounds = Get-GuardWindowBounds -WorkArea ([Windows.SystemParameters]::WorkArea)
$window.MinWidth = $initialBounds.MinWidth
$window.MinHeight = $initialBounds.MinHeight
$window.Width = $initialBounds.Width
$window.Height = $initialBounds.Height
$window.Left = $initialBounds.Left
$window.Top = $initialBounds.Top
$status = $window.FindName('Status')
$details = $window.FindName('Details')
$candidates = $window.FindName('Candidates')
$refresh = $window.FindName('Refresh')
$apply = $window.FindName('Apply')
$debloat = $window.FindName('Debloat')
$localOnly = $window.FindName('LocalOnly')
$undoPrivacy = $window.FindName('UndoPrivacy')
$undoNetwork = $window.FindName('UndoNetwork')
$lastAction = $window.FindName('LastAction')
$window.FindName('BackupLocation').Text = "Default backup folder: $backupRoot"
if ($PreviewOnly) {
    $window.FindName('PreviewBanner').Visibility = 'Visible'
    foreach ($button in @($apply, $debloat, $localOnly, $undoPrivacy, $undoNetwork)) { $button.IsEnabled = $false }
}

function Refresh-View {
    $viewState.ReadSucceeded = $false
    try {
        $auditJson = (& $baselineScript -Mode Audit) -join [Environment]::NewLine
        $audit = ConvertFrom-Json -InputObject $auditJson
        if ($audit -isnot [array]) { $audit = @($audit) }
        $compliant = @($audit | Where-Object { $_.Compliant }).Count
        $status.Text = "Privacy controls: $compliant of $($audit.Count) already restricted"
        $details.Text = ($audit | ForEach-Object {
            $mark = if ($_.Compliant) { '[OK]' } else { '[SUGGESTED]' }
            "$mark $($_.Description)"
        }) -join [Environment]::NewLine

        $candidates.Items.Clear()
        $suggestionsJson = (& $debloatScript -Mode Preview) -join [Environment]::NewLine
        $suggestions = ConvertFrom-Json -InputObject $suggestionsJson
        if ($suggestions -isnot [array]) { $suggestions = @($suggestions) }
        foreach ($item in $suggestions) {
            if ($item.PSObject.Properties.Name -contains 'Name') {
                [void]$candidates.Items.Add("$($item.DisplayName) ($($item.Name))")
            }
        }
        if ($candidates.Items.Count -eq 0) {
            [void]$candidates.Items.Add('No allowlisted optional apps found.')
        }
        $viewState.ReadSucceeded = $true
    }
    catch {
        $status.Text = 'Unable to read current settings'
        $details.Text = $_.Exception.Message
    }
}

# Shared by button handlers and fixture-backed workflow tests.
function Invoke-GuardAction {
    param(
        [ValidateSet('PrivacyApply', 'PrivacyUndo', 'DebloatApply', 'NetworkApply', 'NetworkUndo')]
        [string] $Action,
        [string] $BackupFile,
        [string] $ProgramPath
    )
    if ($PreviewOnly) { throw 'System-changing actions are disabled in preview mode.' }
    $isApply = $Action -in @('PrivacyApply', 'DebloatApply', 'NetworkApply')
    if ($isApply) {
        $prefix = switch ($Action) { 'PrivacyApply' { 'privacy-baseline' } 'DebloatApply' { 'debloat' } 'NetworkApply' { 'local-only' } }
        $BackupFile = Join-Path $backupRoot ($prefix + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    }
    elseif (-not $BackupFile) { throw 'Choose the backup created by the action you want to undo.' }
    try {
        $raw = switch ($Action) {
            'PrivacyApply' { & $baselineScript -Mode Apply -BackupFile $BackupFile }
            'PrivacyUndo' { & $baselineScript -Mode Rollback -BackupFile $BackupFile }
            'DebloatApply' { & $debloatScript -Mode Apply -BackupFile $BackupFile }
            'NetworkApply' { & $localOnlyScript -Mode Apply -BackupFile $BackupFile -ProgramPath $ProgramPath }
            'NetworkUndo' { & $localOnlyScript -Mode Rollback -BackupFile $BackupFile }
        }
        $result = ConvertFrom-Json -InputObject ($raw -join [Environment]::NewLine)
        if (-not $result -or $result.Mode -ne $(if ($isApply) { 'Apply' } else { 'Rollback' })) { throw 'The action did not return a valid completion result.' }
        $message = switch ($Action) {
            'PrivacyApply' { 'Privacy baseline applied. Restart Windows to refresh policies.' }
            'PrivacyUndo' { 'Privacy settings restored from the selected backup. Restart Windows to refresh policies.' }
            'DebloatApply' { "Optional app cleanup completed. $($result.Note)" }
            'NetworkApply' { 'Outbound network block applied to the selected executable. Microphone permission is unchanged.' }
            'NetworkUndo' { 'The matching app network block was removed, or was already absent. Other firewall rules remain in effect.' }
        }
        $lastAction.Text = $message + [Environment]::NewLine + "Backup: $BackupFile"
        Refresh-View
    }
    catch {
        $lastAction.Text = 'Action failed: ' + $_.Exception.Message
        if ($isApply -and (Test-Path -LiteralPath $BackupFile)) {
            $lastAction.Text += [Environment]::NewLine + "Changes may be partial. Recovery backup: $BackupFile"
        }
        throw
    }
}

function Show-ActionError {
    param($ErrorRecord)
    [void][System.Windows.MessageBox]::Show($ErrorRecord.Exception.Message, 'Windows Privacy Guard')
}

function Select-RecoveryBackup {
    param([string] $Prefix, [string] $Title)
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Filter = "Matching backups ($Prefix-*.json)|$Prefix-*.json|JSON backups (*.json)|*.json"
    $dialog.Title = $Title
    if (Test-Path -LiteralPath $backupRoot) { $dialog.InitialDirectory = $backupRoot }
    if ($dialog.ShowDialog($window)) { return $dialog.FileName }
}

$refresh.Add_Click({ Refresh-View })
$apply.Add_Click({
    try { Invoke-GuardAction -Action PrivacyApply } catch { Show-ActionError $_ }
})
$debloat.Add_Click({
    $answer = [System.Windows.MessageBox]::Show('This removes all listed optional apps for the current user. Protected Windows components and provisioned packages are excluded. Removed apps must be reinstalled manually; there is no automatic app undo. Continue?', 'Confirm optional cleanup', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        Invoke-GuardAction -Action DebloatApply
    }
    catch {
        Show-ActionError $_
    }
})
$localOnly.Add_Click({
    try {
        $dialog = [Microsoft.Win32.OpenFileDialog]::new()
        $dialog.Filter = 'Applications (*.exe)|*.exe'
        $dialog.Title = 'Choose an app whose outbound traffic should be blocked'
        if (-not $dialog.ShowDialog($window)) { return }
        $previewJson = (& $localOnlyScript -Mode Preview -ProgramPath $dialog.FileName) -join [Environment]::NewLine
        $preview = ConvertFrom-Json -InputObject $previewJson
        $answer = [System.Windows.MessageBox]::Show("Protect $($preview.Program)?`n`n$($preview.Warning)`n`nMicrophone permissions remain unchanged.", 'Confirm local-only app', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        Invoke-GuardAction -Action NetworkApply -ProgramPath $dialog.FileName
    }
    catch {
        Show-ActionError $_
    }
})
$undoPrivacy.Add_Click({
    try {
        $selected = Select-RecoveryBackup -Prefix 'privacy-baseline' -Title 'Choose the privacy backup to restore'
        if (-not $selected) { return }
        $answer = [System.Windows.MessageBox]::Show("Restore the seven privacy settings to the values in this backup? This can replace changes made since it was saved.`n`n$selected", 'Confirm privacy restore', 'YesNo', 'Warning')
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { Invoke-GuardAction -Action PrivacyUndo -BackupFile $selected }
    } catch { Show-ActionError $_ }
})
$undoNetwork.Add_Click({
    try {
        $selected = Select-RecoveryBackup -Prefix 'local-only' -Title 'Choose the app network backup to undo'
        if (-not $selected) { return }
        $answer = [System.Windows.MessageBox]::Show("Remove the matching Privacy Guard network block? The app may be able to send data again.`n`n$selected", 'Confirm network restore', 'YesNo', 'Warning')
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { Invoke-GuardAction -Action NetworkUndo -BackupFile $selected }
    } catch { Show-ActionError $_ }
})

Refresh-View
if ($TestMode) {
    if (-not $viewState.ReadSucceeded) { throw "Control-panel read check failed: $($details.Text)" }
    [pscustomobject]@{
        Result = 'PASS'
        PopupMarkupLoaded = $true
        ElevationAttempted = $false
        SettingsChanged = $false
    } | ConvertTo-Json
    return
}
[void]$window.ShowDialog()
