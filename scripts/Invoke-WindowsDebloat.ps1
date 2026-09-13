[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply', 'Rollback')]
    [string] $Mode = 'Preview',

    [string] $BackupFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Strict allowlist: unknown packages are never removed. These are optional,
# current-user consumer apps; this script does not modify provisioned packages
# or remove components for every user on the machine.
$optionalPackages = [ordered]@{
    'Clipchamp.Clipchamp' = 'Clipchamp'
    'Microsoft.BingNews' = 'Bing News'
    'Microsoft.BingWeather' = 'Bing Weather'
    'Microsoft.GamingApp' = 'Xbox / Gaming app'
    'Microsoft.GetHelp' = 'Get Help'
    'Microsoft.Getstarted' = 'Tips / Get Started'
    'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire Collection'
    'Microsoft.People' = 'People'
    'Microsoft.PowerAutomateDesktop' = 'Power Automate'
    'Microsoft.Todos' = 'Microsoft To Do'
    'Microsoft.WindowsFeedbackHub' = 'Feedback Hub'
    'Microsoft.WindowsMaps' = 'Maps'
    'Microsoft.Xbox.TCUI' = 'Xbox identity UI'
    'Microsoft.XboxApp' = 'Xbox app'
    'Microsoft.XboxGamingOverlay' = 'Xbox Game Bar'
    'Microsoft.XboxIdentityProvider' = 'Xbox Identity Provider'
    'Microsoft.XboxSpeechToTextOverlay' = 'Xbox speech overlay'
    'Microsoft.ZuneMusic' = 'Groove Music / Media Player legacy'
    'Microsoft.ZuneVideo' = 'Movies & TV'
    'MicrosoftTeams' = 'Teams consumer'
    'MSTeams' = 'New Teams'
}

# Defense-in-depth deny list. Even if a future edit accidentally expands the
# allowlist, these packages remain protected.
$protectedPrefixes = @(
    'Microsoft.WindowsStore',
    'Microsoft.DesktopAppInstaller',
    'Microsoft.VCLibs',
    'Microsoft.UI.Xaml',
    'Microsoft.NET.Native',
    'Microsoft.WindowsAppRuntime',
    'Microsoft.Windows.SecHealthUI',
    'MicrosoftWindows.Client',
    'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl',
    'Microsoft.LockApp',
    'Microsoft.Windows.StartMenuExperienceHost',
    'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.Search',
    'Microsoft.MicrosoftEdge'
)

function Test-IsProtectedPackage {
    param([Parameter(Mandatory = $true)] [string] $Name)
    foreach ($prefix in $protectedPrefixes) {
        if ($Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-CandidatePackages {
    $installed = @(Get-AppxPackage -ErrorAction Stop)
    foreach ($package in $installed) {
        if ($optionalPackages.Contains($package.Name) -and -not (Test-IsProtectedPackage -Name $package.Name)) {
            [pscustomobject]@{
                Name = $package.Name
                Version = $package.Version.ToString()
                DisplayName = $optionalPackages[$package.Name]
                FullName = $package.PackageFullName
            }
        }
    }
}

if ($Mode -eq 'Preview') {
    $candidates = @(Get-CandidatePackages)
    if ($candidates.Count -eq 0) {
        [pscustomobject]@{ Message = 'No allowlisted optional consumer apps were found for the current user.' } | ConvertTo-Json
    }
    else {
        $candidates | ConvertTo-Json -Depth 5
    }
    return
}

if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Apply and Rollback require an elevated PowerShell window.'
}

if ($Mode -eq 'Apply') {
    $candidates = @(Get-CandidatePackages)
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    if (-not $BackupFile) {
        $BackupFile = Join-Path $env:LOCALAPPDATA ("WindowsPrivacyGuard\backups\debloat-$timestamp-" + [guid]::NewGuid().ToString('N') + '.json')
    }
    $parent = Split-Path -Parent $BackupFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    ConvertTo-Json -InputObject @($candidates) -Depth 5 | Set-Content -LiteralPath $BackupFile -Encoding UTF8

    foreach ($package in $candidates) {
        if (-not (Test-IsProtectedPackage -Name $package.Name)) {
            Remove-AppxPackage -Package $package.FullName -ErrorAction Stop
        }
    }

    [pscustomobject]@{
        Mode = 'Apply'
        Removed = @($candidates | ForEach-Object { $_.Name })
        BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path
        Note = 'Only current-user packages on the strict optional-app allowlist were removed. Provisioned and protected system packages were not touched.'
    } | ConvertTo-Json -Depth 6
    return
}

if (-not $BackupFile -or -not (Test-Path -LiteralPath $BackupFile)) {
    throw 'Rollback requires a backup file. Removed Store apps may need to be reinstalled manually.'
}

[pscustomobject]@{
    Mode = 'Rollback'
    BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path
    Note = 'The backup identifies removed packages. This tool does not silently download or reinstall apps.'
} | ConvertTo-Json -Depth 6
