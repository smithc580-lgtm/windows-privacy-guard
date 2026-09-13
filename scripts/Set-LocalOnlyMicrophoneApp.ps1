[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Preview', 'Apply', 'Rollback')]
    [string] $Mode = 'Audit',

    [string] $ProgramPath,

    [string] $BackupFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rulePrefix = 'Windows Privacy Guard - Local-only app - '

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-SafeProgramPath {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ([IO.Path]::GetExtension($resolved) -ine '.exe') {
        throw 'Local-only protection requires an executable (.exe), not a DLL or script.'
    }

    $windowsRoot = [IO.Path]::GetFullPath($env:windir).TrimEnd('\') + '\'
    if ($resolved.StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'System executables under the Windows directory are protected and cannot be selected.'
    }
    return $resolved
}

function Get-LocalOnlyRules {
    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    @(Get-PolicyRules -Policy $policy |
            Where-Object { $_.Grouping -eq 'Windows Privacy Guard' -and $_.Name.StartsWith($rulePrefix, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object {
                [pscustomobject]@{
                    DisplayName = $_.Name
                    Enabled = $_.Enabled.ToString()
                    Action = if ($_.Action -eq 0) { 'Block' } else { 'Allow' }
                    Program = $_.ApplicationName
                    Direction = if ($_.Direction -eq 2) { 'Outbound' } else { 'Inbound' }
                    Profiles = $_.Profiles
                }
            })
}

function Get-PolicyRules {
    param($Policy)
    foreach ($rule in $Policy.Rules) { $rule }
}

if ($Mode -eq 'Audit') {
    ConvertTo-Json -InputObject @(Get-LocalOnlyRules) -Depth 5
    return
}

if ($Mode -ne 'Rollback' -and -not $ProgramPath) {
    throw "$Mode requires -ProgramPath."
}
if ($Mode -ne 'Rollback') {
    $safePath = Resolve-SafeProgramPath -Path $ProgramPath
}

if ($Mode -eq 'Preview') {
    [pscustomobject]@{
        Program = $safePath
        Action = 'Block outbound network traffic for this executable'
        MicrophoneAccess = 'Unchanged'
        Warning = 'Cloud voice features and all other network features of this app may stop working.'
    } | ConvertTo-Json -Depth 5
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'Apply and Rollback require an elevated PowerShell window.'
}

if ($Mode -eq 'Apply') {
    $leaf = [IO.Path]::GetFileNameWithoutExtension($safePath)
    $ruleName = "$rulePrefix$leaf"
    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    $existing = @(Get-PolicyRules -Policy $policy | Where-Object { $_.Name -eq $ruleName })
    if ($existing.Count -gt 0) {
        throw "A local-only rule already exists for $safePath. Use Audit to inspect it."
    }

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    if (-not $BackupFile) {
        $BackupFile = Join-Path $env:LOCALAPPDATA ("WindowsPrivacyGuard\backups\local-only-$timestamp-" + [guid]::NewGuid().ToString('N') + '.json')
    }
    $parent = Split-Path -Parent $BackupFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [pscustomobject]@{
        RuleName = $ruleName
        Program = $safePath
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $BackupFile -Encoding UTF8

    # Documented Windows Firewall COM API; avoids the CIM/WinRM dependency.
    # NET_FW_RULE_DIR_OUT=2, NET_FW_ACTION_BLOCK=0, NET_FW_IP_PROTOCOL_ANY=256.
    $rule = New-Object -ComObject HNetCfg.FWRule
    $rule.Name = $ruleName
    $rule.Grouping = 'Windows Privacy Guard'
    $rule.ApplicationName = $safePath
    $rule.Protocol = 256
    $rule.Direction = 2
    $rule.Action = 0
    $rule.Profiles = 7 # Domain (1), Private (2), Public (4).
    $rule.Enabled = $true
    $policy.Rules.Add($rule)
    [pscustomobject]@{
        Mode = 'Apply'
        Program = $safePath
        RuleName = $ruleName
        BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path
        MicrophoneAccess = 'Unchanged'
    } | ConvertTo-Json -Depth 5
    return
}

if (-not $BackupFile -or -not (Test-Path -LiteralPath $BackupFile)) {
    throw 'Rollback requires a backup file created by Apply.'
}
$backup = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
if ($backup.RuleName -isnot [string] -or -not $backup.RuleName.StartsWith($rulePrefix, [StringComparison]::Ordinal) -or
    $backup.Program -isnot [string] -or [string]::IsNullOrWhiteSpace($backup.Program)) {
    throw 'The backup does not identify a Windows Privacy Guard rule.'
}
$policy = New-Object -ComObject HNetCfg.FwPolicy2
$matches = @(Get-PolicyRules -Policy $policy | Where-Object { $_.Name -eq $backup.RuleName })
if ($matches.Count -gt 1) { throw 'Multiple rules match the backup; refusing ambiguous rollback.' }
if ($matches.Count -eq 1) {
    if ($matches[0].Grouping -ne 'Windows Privacy Guard' -or $matches[0].ApplicationName -ine $backup.Program) {
        throw 'The rule no longer matches the backup; refusing to remove it.'
    }
    $policy.Rules.Remove($backup.RuleName)
}
[pscustomobject]@{
    Mode = 'Rollback'
    RuleName = $backup.RuleName
    Program = $backup.Program
    Note = 'The app regains network access. Microphone permissions were never changed.'
} | ConvertTo-Json -Depth 5
