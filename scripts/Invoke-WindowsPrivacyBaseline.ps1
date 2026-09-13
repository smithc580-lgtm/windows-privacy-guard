[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Preview', 'Apply', 'Rollback')]
    [string] $Mode = 'Audit',

    [string] $BackupFile,

    [switch] $RemoveRecall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$controls = @(
    [pscustomobject]@{
        Id = 'diagnostic-data-required-only'
        HivePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
        Name = 'AllowTelemetry'
        Value = 1
        Description = 'Limit Windows diagnostic data to the required level where supported.'
    },
    [pscustomobject]@{
        Id = 'typing-and-inking-data'
        HivePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput'
        Name = 'AllowLinguisticDataCollection'
        Value = 0
        Description = 'Do not allow Windows to send typing and inking data for language recognition improvements.'
    },
    [pscustomobject]@{
        Id = 'tailored-experiences'
        HivePath = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        Name = 'DisableTailoredExperiencesWithDiagnosticData'
        Value = 1
        Description = 'Do not use diagnostic data for personalized recommendations, tips, and offers.'
    },
    [pscustomobject]@{
        Id = 'app-diagnostics'
        HivePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        Name = 'LetAppsGetDiagnosticInfo'
        Value = 2
        Description = 'Force Windows apps to be denied diagnostic information about other apps.'
    },
    [pscustomobject]@{
        Id = 'voice-activation'
        HivePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        Name = 'LetAppsActivateWithVoice'
        Value = 2
        Description = 'Force Windows apps to be denied voice-activation access.'
    },
    [pscustomobject]@{
        Id = 'online-speech'
        HivePath = 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'
        Name = 'HasAccepted'
        Value = 0
        Description = 'Do not accept online speech recognition.'
    },
    [pscustomobject]@{
        Id = 'recall-snapshots'
        HivePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
        Name = 'DisableAIDataAnalysis'
        Value = 1
        Description = 'Turn off saving snapshots for Recall.'
    }
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ValueState {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Control
    )

    $exists = $false
    $value = $null
    $propertyType = $null

    try {
        $key = Get-Item -LiteralPath $Control.HivePath -ErrorAction Stop
        $value = $key.GetValue($Control.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $exists = $null -ne $key.GetValueNames() -and $key.GetValueNames() -contains $Control.Name
        if ($exists) {
            $propertyType = $key.GetValueKind($Control.Name).ToString()
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        $exists = $false
    }

    [pscustomobject]@{
        Id = $Control.Id
        Path = $Control.HivePath
        Name = $Control.Name
        CurrentValue = $value
        DesiredValue = $Control.Value
        Exists = $exists
        PropertyType = $propertyType
        Description = $Control.Description
        Compliant = $exists -and ([string]$value -eq [string]$Control.Value)
    }
}

function Set-DwordControl {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Control
    )

    # Recreating an existing registry key with -Force clears its other values.
    if (-not (Test-Path -LiteralPath $Control.HivePath)) {
        New-Item -Path $Control.HivePath -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Control.HivePath -Name $Control.Name -PropertyType DWord -Value $Control.Value -Force | Out-Null
}

function Restore-Control {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Entry
    )

    if ($Entry.Exists) {
        if (-not (Test-Path -LiteralPath $Entry.Path)) {
            New-Item -Path $Entry.Path -Force | Out-Null
        }
        $type = if ($Entry.PropertyType) { $Entry.PropertyType } else { 'DWord' }
        New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -PropertyType $type -Value $Entry.Value -Force | Out-Null
    }
    elseif (Test-Path -LiteralPath $Entry.Path) {
        $key = Get-Item -LiteralPath $Entry.Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Entry.Name) {
            Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction Stop
        }
    }
}

if ($Mode -eq 'Audit' -or $Mode -eq 'Preview') {
    $controls | ForEach-Object { Get-ValueState -Control $_ } | ConvertTo-Json -Depth 6
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'Apply and Rollback require an elevated PowerShell window.'
}

if ($Mode -eq 'Apply') {
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    if (-not $BackupFile) {
        $BackupFile = Join-Path $env:LOCALAPPDATA ("WindowsPrivacyGuard\backups\privacy-baseline-$timestamp-" + [guid]::NewGuid().ToString('N') + '.json')
    }

    $backup = @($controls | ForEach-Object {
        $state = Get-ValueState -Control $_
        [pscustomobject]@{
            Id = $state.Id
            Path = $state.Path
            Name = $state.Name
            Exists = $state.Exists
            Value = $state.CurrentValue
            PropertyType = $state.PropertyType
        }
    })

    $backupParent = Split-Path -Parent $BackupFile
    if ($backupParent -and -not (Test-Path -LiteralPath $backupParent)) {
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
    }
    $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupFile -Encoding UTF8

    $controls | ForEach-Object { Set-DwordControl -Control $_ }

    if ($RemoveRecall) {
        $recall = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue
        if ($recall -and $recall.State -ne 'Disabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName Recall -Remove -NoRestart
            Write-Warning 'Recall was removed. Restart Windows to complete removal; existing snapshots are expected to be deleted by Windows.'
        }
        else {
            Write-Verbose 'Recall optional feature was not present or was already disabled.'
        }
    }

    [pscustomobject]@{
        Mode = 'Apply'
        BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path
        ControlsApplied = $controls.Id
        RecallRemoved = [bool]$RemoveRecall
        RestartRecommended = $true
    } | ConvertTo-Json -Depth 6
    return
}

if (-not $BackupFile) {
    throw 'Rollback requires -BackupFile pointing to a backup created by Apply.'
}
if (-not (Test-Path -LiteralPath $BackupFile)) {
    throw "Backup file not found: $BackupFile"
}

$entries = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
if ($entries -isnot [array] -or $entries.Count -ne $controls.Count) {
    throw 'This is not a complete privacy baseline backup.'
}
$seen = @{}
foreach ($entry in $entries) {
    $match = @($controls | Where-Object { $_.Id -ceq $entry.Id -and $_.HivePath -ieq $entry.Path -and $_.Name -ceq $entry.Name })
    if ($match.Count -ne 1 -or $seen.ContainsKey($entry.Id) -or $entry.Exists -isnot [bool]) {
        throw 'The backup contains an unknown, duplicate, or invalid privacy setting.'
    }
    if ($entry.Exists -and $entry.PropertyType -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')) {
        throw 'The backup contains an unsupported registry value type.'
    }
    $seen[$entry.Id] = $true
}
$entries | ForEach-Object { Restore-Control -Entry $_ }

[pscustomobject]@{
    Mode = 'Rollback'
    BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path
    ControlsRestored = $entries.Count
    RestartRecommended = $true
} | ConvertTo-Json -Depth 6
