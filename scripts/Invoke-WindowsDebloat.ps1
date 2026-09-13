[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply', 'Rollback')]
    [string] $Mode = 'Preview',

    [string] $BackupFile,
    [switch] $IncludeProvisioned,
    [string] $SelectionJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Strict allowlist: unknown packages are never removed. These are optional,
# consumer apps. Every mutation requires an explicit exact-package selection.
# Provisioned copies are a separate scope; other users' registrations are not removed.
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
    'Microsoft.XboxIdentityProvider'
    'Microsoft.Xbox.TCUI'
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

function Get-AppRemovalEffect {
    param([string] $Name)
    switch -Regex ($Name) {
        'Teams' { return 'Removes this Teams app and its calling/chat features.' }
        'Xbox|GamingApp' { return 'Removes this gaming app or overlay and its related gaming features.' }
        'PowerAutomate' { return 'Removes Power Automate Desktop; workflows needing it will not run.' }
        'ZuneMusic|ZuneVideo|Clipchamp' { return 'Removes this media app; use another player/editor for its features.' }
        default { return 'Removes this optional app and its features; reinstall manually if needed.' }
    }
}

function Test-PackageSafetyFlags {
    param($Package)
    foreach ($flag in @('IsFramework', 'IsResourcePackage', 'NonRemovable')) {
        if ($Package.PSObject.Properties.Name -contains $flag -and $Package.$flag) { return $false }
    }
    return $true
}

function Get-CandidatePackages {
    param([switch] $WithProvisioned)
    $installed = @(Get-AppxPackage -ErrorAction Stop)
    # When deprovisioning, also inspect registrations for other users for shared dependencies.
    $dependencyInventory = if ($WithProvisioned) { @(Get-AppxPackage -AllUsers -ErrorAction Stop) } else { $installed }
    $dependencies = @{}
    foreach ($app in $dependencyInventory) {
        if ($app.PSObject.Properties.Name -contains 'Dependencies') {
            foreach ($dependency in $app.Dependencies) {
                if ($null -ne $dependency -and $dependency.PSObject.Properties.Name -contains 'Name') { $dependencies[$dependency.Name] = $true }
            }
        }
    }
    foreach ($package in $installed) {
        if ($optionalPackages.Contains($package.Name) -and -not (Test-IsProtectedPackage -Name $package.Name) -and
            (Test-PackageSafetyFlags $package) -and -not $dependencies.ContainsKey($package.Name)) {
            [pscustomobject]@{
                Name = $package.Name
                Version = $package.Version.ToString()
                DisplayName = $optionalPackages[$package.Name]
                FullName = $package.PackageFullName
                Scope = 'CurrentUser'
                Effect = Get-AppRemovalEffect $package.Name
            }
        }
    }
    if ($WithProvisioned) {
        foreach ($package in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) {
            $name = $package.DisplayName
            $unsafeRegistration = @($dependencyInventory | Where-Object { $_.Name -eq $name -and -not (Test-PackageSafetyFlags $_) }).Count -gt 0
            if ($optionalPackages.Contains($name) -and -not (Test-IsProtectedPackage $name) -and
                (Test-PackageSafetyFlags $package) -and -not $dependencies.ContainsKey($name) -and -not $unsafeRegistration) {
                [pscustomobject]@{
                    Name=$name; Version=$package.Version.ToString(); DisplayName=$optionalPackages[$name]
                    FullName=$package.PackageName; Scope='Provisioned'
                    Effect='Stops this app being installed automatically for new accounts. Existing accounts are not uninstalled by this choice.'
                }
            }
        }
    }
}

function Invoke-SelectedCleanup {
    param([string] $Json, [string] $InventoryPath)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'Select at least one optional app or provisioned copy.' }
    $selected = @($Json | ConvertFrom-Json | ForEach-Object { $_ })
    if ($selected.Count -eq 0) { throw 'Select at least one optional app or provisioned copy.' }
    $seen = @{}
    foreach ($entry in $selected) {
        foreach ($field in @('Name','FullName','Scope')) {
            if ($entry.PSObject.Properties.Name -notcontains $field -or $entry.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.$field)) { throw 'Invalid cleanup selection.' }
        }
        if ($entry.Scope -notin @('CurrentUser','Provisioned') -or -not $optionalPackages.Contains($entry.Name) -or (Test-IsProtectedPackage $entry.Name)) { throw 'Protected, unknown, or invalid selection.' }
        $key = $entry.Scope + '|' + $entry.FullName
        if ($seen.ContainsKey($key)) { throw 'Duplicate cleanup selection.' }
        $seen[$key] = $true
    }
    $withProvisioned = @($selected | Where-Object Scope -eq 'Provisioned').Count -gt 0
    $available = @(Get-CandidatePackages -WithProvisioned:$withProvisioned)
    $plan = @(foreach ($entry in $selected) {
        $matches = @($available | Where-Object { $_.Name -ceq $entry.Name -and $_.FullName -ceq $entry.FullName -and $_.Scope -ceq $entry.Scope })
        if ($matches.Count -ne 1) { throw 'Selection changed or is no longer eligible. Refresh the list and choose again.' }
        $matches[0]
    })
    # Save the entire reviewed plan before any mutation. This is an inventory, not an app restore image.
    if (Test-Path -LiteralPath $InventoryPath) { throw 'Inventory already exists; refusing to overwrite recovery information.' }
    New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($InventoryPath))) -Force | Out-Null
    $record = [ordered]@{Schema=2;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Planned=$plan;Completed=@();Status='Planned';Failure=$null}
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InventoryPath -Encoding UTF8
    try {
        foreach ($entry in $plan) {
            # Recheck the exact identity and protection rules immediately before each removal.
            $fresh = @(Get-CandidatePackages -WithProvisioned:$withProvisioned | Where-Object {
                $_.Name -ceq $entry.Name -and $_.FullName -ceq $entry.FullName -and $_.Scope -ceq $entry.Scope
            })
            if ($fresh.Count -ne 1) { throw 'An app changed during cleanup; stopped before removing that entry.' }
            if ($entry.Scope -eq 'Provisioned') {
                Remove-AppxProvisionedPackage -Online -PackageName $entry.FullName -ErrorAction Stop | Out-Null
            } else {
                Remove-AppxPackage -Package $entry.FullName -ErrorAction Stop
            }
            $record.Completed += $entry
            $record.Status = 'InProgress'
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InventoryPath -Encoding UTF8
        }
        $record.Status = 'Completed'
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InventoryPath -Encoding UTF8
    } catch {
        $record.Status = 'Failed'; $record.Failure = $_.Exception.Message
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InventoryPath -Encoding UTF8
        throw
    }
    [pscustomobject]@{Mode='Apply';Removed=@($record.Completed);BackupFile=[IO.Path]::GetFullPath($InventoryPath)
        Note='Only checked entries were removed. Provisioned choices affect new accounts; other existing accounts were not uninstalled. Manual reinstall/reprovisioning may be needed; no automatic app undo.'} | ConvertTo-Json -Depth 8
}

if ($Mode -eq 'Preview') {
    $candidates = @(Get-CandidatePackages -WithProvisioned:$IncludeProvisioned)
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
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    if (-not $BackupFile) {
        $BackupFile = Join-Path $env:LOCALAPPDATA ("WindowsPrivacyGuard\backups\debloat-$timestamp-" + [guid]::NewGuid().ToString('N') + '.json')
    }
    Invoke-SelectedCleanup -Json $SelectionJson -InventoryPath $BackupFile
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
