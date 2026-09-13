[CmdletBinding()]
param([Parameter(Mandatory=$true)][string] $Archive, [ValidateRange(1,5)][int] $Rounds=2)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Path (Join-Path $repo 'reports') -Force | Out-Null
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('WPG-ReleaseTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$absoluteRoot=(Resolve-Path -LiteralPath $testRoot).Path
$runs=@()
function Assert-Release([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
try {
    foreach ($round in 1..$Rounds) {
        $roundRoot=Join-Path $testRoot ("round $round")
        $extract=Join-Path $roundRoot 'extracted package'
        Expand-Archive -LiteralPath $Archive -DestinationPath $extract
        $package=Join-Path $extract 'WindowsPrivacyGuard'
        $manifestPath=Join-Path $package 'release-manifest.json'
        $manifestRaw=Get-Content -LiteralPath $manifestPath -Raw
        $manifest=$manifestRaw | ConvertFrom-Json
        $actual=@(Get-ChildItem -LiteralPath $package -Recurse -File)
        Assert-Release ($actual.Count -eq $manifest.Files.Count + 1) 'Unexpected package contents.'
        Assert-Release (@($manifest.Files | Where-Object { $_.Path -match '^(reports|backups|tests|sandbox-results)/|\.(wav|iso|vhdx)$|/bin/' }).Count -eq 0) 'Private/test files in release.'
        $installer=Join-Path $package 'scripts\Install-WindowsPrivacyGuard.ps1'
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$parseErrors)
        $resolver=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GuardDefaultInstallRoot'},$true)
        Assert-Release ($null -ne $resolver) 'Documents default resolver missing.'
        . ([scriptblock]::Create($resolver.Extent.Text))
        foreach ($documents in @('C:\Users\Example\Documents', 'D:\Redirected Documents', 'C:\Users\Example\OneDrive\Documents')) {
            Assert-Release ((Get-GuardDefaultInstallRoot -DocumentsDirectory $documents) -eq (Join-Path $documents 'WindowsPrivacyGuard')) 'Documents location was hardcoded or changed.'
        }
        foreach ($invalid in @('', 'relative\Documents')) {
            $rejected=$false
            try { Get-GuardDefaultInstallRoot -DocumentsDirectory $invalid | Out-Null } catch { $rejected=$true }
            Assert-Release $rejected 'Unavailable/relative Documents location accepted.'
        }
        $installRoot=Join-Path $roundRoot 'existing install'
        $desktop=Join-Path $roundRoot 'test desktop'
        New-Item -ItemType Directory -Path $desktop | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $installRoot 'backups') -Force | Out-Null
        $sentinel=Join-Path $installRoot 'backups\keep.json'
        Set-Content -LiteralPath $sentinel -Value 'original backup'
        $original=Get-Content -LiteralPath $sentinel -Raw
        $first=(& $installer -InstallRoot $installRoot -ShortcutDirectory $desktop -NoLaunch) | ConvertFrom-Json
        $firstShortcutBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($first.Shortcut))
        $second=(& $installer -InstallRoot $installRoot -ShortcutDirectory $desktop -NoLaunch) | ConvertFrom-Json
        Assert-Release ($first.InstallDirectory -ne $second.InstallDirectory) 'Reinstall overwrote prior release.'
        Assert-Release ($first.Shortcut -ne $second.Shortcut) 'Reinstall overwrote shortcut.'
        Assert-Release ($firstShortcutBytes -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($first.Shortcut))) 'Existing shortcut changed.'
        $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($second.Shortcut)
        Assert-Release ($shortcut.Arguments.Contains($second.Launcher) -and $shortcut.WorkingDirectory -eq $second.InstallDirectory) 'Shortcut does not target installed release.'
        Assert-Release ($shortcut.TargetPath -eq (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')) 'Incorrect shortcut executable.'
        Assert-Release ($shortcut.Arguments -notmatch '-WindowStyle\s+Hidden' -and $shortcut.WindowStyle -eq 7) 'Shortcut hides initial process instead of minimizing bootstrap.'
        $ui=(& $shortcut.TargetPath -NoProfile -STA -ExecutionPolicy Bypass -File $second.Launcher -TestMode) | ConvertFrom-Json
        Assert-Release ($LASTEXITCODE -eq 0 -and $ui.Result -eq 'PASS') 'Installed UI test mode failed.'
        $recorder=& $shortcut.TargetPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $second.InstallDirectory 'scripts\Start-VoiceRecorder.ps1') -BuildOnly
        Assert-Release ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath ($recorder | Select-Object -Last 1))) 'Packaged recorder build failed.'
        foreach ($case in @('CorruptFile','MissingFile','Traversal','DuplicateEntry')) {
            $target=Join-Path $package 'WindowsPrivacyGuard.cmd'
            $bytes=[IO.File]::ReadAllBytes($target)
            if ($case -eq 'CorruptFile') { Add-Content -LiteralPath $target -Value 'corrupted fixture' }
            if ($case -eq 'MissingFile') { Move-Item -LiteralPath $target -Destination ($target + '.held') }
            if ($case -in @('Traversal','DuplicateEntry')) {
                $bad=$manifestRaw | ConvertFrom-Json
                if ($case -eq 'Traversal') { $bad.Files[0].Path='../escape.cmd' }
                else { $bad.Files += $bad.Files[0] }
                $bad | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            }
            $rejected=$false
            try { & $installer -InstallRoot $installRoot -NoShortcut -NoLaunch | Out-Null } catch { $rejected=$true }
            Assert-Release $rejected "Invalid package accepted: $case"
            Assert-Release (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'releases') -Directory).Count -eq 2) 'Invalid package created a release.'
            if ($case -eq 'MissingFile') { Move-Item -LiteralPath ($target + '.held') -Destination $target }
            if ($case -eq 'CorruptFile') { [IO.File]::WriteAllBytes($target, $bytes) }
            $manifestRaw | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        }
        Assert-Release ((Get-Content -LiteralPath $sentinel -Raw) -eq $original -and (Test-Path -LiteralPath $first.Launcher)) 'Recovery data or earlier installation changed.'
        $runs += [pscustomobject]@{Round=$round;Result='PASS';DocumentsResolverCases=5;InstallReinstall=$true;ShortcutPreserved=$true;InstalledUi=$true;RecorderBuild=$true;InvalidPackagesRejected=4;BackupPreserved=$true}
        Write-Output "Release package round $round PASS"
    }
}
finally {
    $result=if ($runs.Count -eq $Rounds) {'PASS'} else {'FAIL'}
    [pscustomobject]@{FinishedAtUtc=[DateTime]::UtcNow.ToString('o');Archive=$Archive;Result=$result;Runs=$runs;Scope='Local ZIP extraction, install, shortcut metadata, WPF TestMode, recorder compile. No live download, UAC clicks, policy changes, or microphone capture.'} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $repo 'reports\release-package-tests.json') -Encoding UTF8
    # Delete only this invocation's unique temporary test tree; reject reparse points.
    if ($absoluteRoot -eq [IO.Path]::GetFullPath($testRoot) -and
        (Split-Path -Parent $absoluteRoot) -eq ([IO.Path]::GetTempPath()).TrimEnd('\') -and
        (Split-Path -Leaf $absoluteRoot) -match '^WPG-ReleaseTest-[0-9a-f]{32}$') {
        $links=@(Get-Item -LiteralPath $absoluteRoot; Get-ChildItem -LiteralPath $absoluteRoot -Recurse -Force) |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
        if (-not $links) { Remove-Item -LiteralPath $absoluteRoot -Recurse -Force }
    }
}
