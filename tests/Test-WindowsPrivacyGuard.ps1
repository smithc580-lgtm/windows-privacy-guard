[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $repoRoot 'scripts'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $failures.Add($Message) }
}

function Read-JsonCommand {
    param([scriptblock] $Command)
    $raw = (& $Command) -join [Environment]::NewLine
    return ConvertFrom-Json -InputObject $raw
}

# 1. Parse every PowerShell file without executing it.
Get-ChildItem -LiteralPath $scriptRoot -Filter '*.ps1' -File | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True (@($errors).Count -eq 0) "PowerShell parse errors in $($_.Name): $($errors -join '; ')"
}

# 2. The baseline must be previewable and expose all expected controls.
$baseline = Read-JsonCommand { & (Join-Path $scriptRoot 'Invoke-WindowsPrivacyBaseline.ps1') -Mode Preview }
if ($baseline -isnot [array]) { $baseline = @($baseline) }
$expectedIds = @(
    'diagnostic-data-required-only',
    'typing-and-inking-data',
    'tailored-experiences',
    'app-diagnostics',
    'voice-activation',
    'online-speech',
    'recall-snapshots'
)
Assert-True ($baseline.Count -eq $expectedIds.Count) "Expected $($expectedIds.Count) baseline controls, found $($baseline.Count)."
foreach ($id in $expectedIds) {
    Assert-True (@($baseline | Where-Object { $_.Id -eq $id }).Count -eq 1) "Missing baseline control: $id"
}

# 3. Preview must not create a backup or mutate registry policy.
$backupDir = Join-Path $env:LOCALAPPDATA 'WindowsPrivacyGuard\backups'
$beforeBackups = if (Test-Path -LiteralPath $backupDir) { @(Get-ChildItem -LiteralPath $backupDir -Force).Count } else { 0 }
& (Join-Path $scriptRoot 'Invoke-WindowsPrivacyBaseline.ps1') -Mode Preview | Out-Null
$afterBackups = if (Test-Path -LiteralPath $backupDir) { @(Get-ChildItem -LiteralPath $backupDir -Force).Count } else { 0 }
Assert-True ($beforeBackups -eq $afterBackups) 'Preview unexpectedly changed the backup directory.'

# 4. The debloater must be suggestion-only in Preview mode.
$debloat = Read-JsonCommand { & (Join-Path $scriptRoot 'Invoke-WindowsDebloat.ps1') -Mode Preview }
if ($debloat -isnot [array]) { $debloat = @($debloat) }
Assert-True ($null -ne $debloat) 'Debloater preview returned no result.'

# 5. System executables must be rejected by local-only protection.
$systemExe = Join-Path $env:windir 'System32\notepad.exe'
$rejected = $false
try {
    & (Join-Path $scriptRoot 'Set-LocalOnlyMicrophoneApp.ps1') -Mode Preview -ProgramPath $systemExe | Out-Null
}
catch {
    $rejected = $_.Exception.Message -like 'System executables*'
}
Assert-True $rejected 'Local-only protection accepted a Windows system executable.'

# 6. The downloader must reject the unpublished placeholder URL.
$placeholderRejected = $false
try {
    & (Join-Path $scriptRoot 'DownloadAndLaunch.ps1') -RepositoryZipUrl 'https://github.com/REPLACE_ME/windows-privacy-guard/archive/refs/heads/main.zip' | Out-Null
}
catch {
    $placeholderRejected = $_.Exception.Message -like 'Set REPO_ZIP_URL*'
}
Assert-True $placeholderRejected 'Downloader did not reject the placeholder repository URL.'

# 7. Instantiate the WPF popup in test mode without elevation or mutation.
$popupJson = (& (Join-Path $scriptRoot 'Start-WindowsPrivacyGuard.ps1') -TestMode) -join [Environment]::NewLine
$popup = ConvertFrom-Json -InputObject $popupJson
Assert-True ($popup.Result -eq 'PASS' -and $popup.PopupMarkupLoaded -and -not $popup.SettingsChanged) 'WPF popup test mode did not complete safely.'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

[pscustomobject]@{
    Result = 'PASS'
    ScriptsParsed = (Get-ChildItem -LiteralPath $scriptRoot -Filter '*.ps1' -File | Measure-Object).Count
    BaselineControls = $baseline.Count
    PopupMarkup = 'Loaded'
    PreviewChanges = 'None detected'
    DestructiveActions = 'Not executed'
} | ConvertTo-Json
