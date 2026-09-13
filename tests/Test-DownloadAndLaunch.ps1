[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repo 'scripts\DownloadAndLaunch.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('WPG-InstallerTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$absoluteRoot = (Resolve-Path -LiteralPath $testRoot).Path
try {
    $package = Join-Path $testRoot 'package\repo-main'
    New-Item -ItemType Directory -Path $package -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'scripts') -Destination (Join-Path $package 'scripts') -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'WindowsPrivacyGuard.cmd') -Destination $package
    $archive = Join-Path $testRoot 'valid.zip'
    Compress-Archive -LiteralPath $package -DestinationPath $archive
    $installRoot = Join-Path $testRoot 'existing-install'
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'backups') -Force | Out-Null
    $sentinel = Join-Path $installRoot 'backups\existing-backup.json'
    Set-Content -LiteralPath $sentinel -Value '{"keep":"original backup"}'
    $originalContent = Get-Content -LiteralPath $sentinel -Raw
    $downloadFailure = $false
    function Invoke-WebRequest {
        [CmdletBinding()] param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
        if ($downloadFailure) { throw 'Injected download failure' }
        Copy-Item -LiteralPath $archive -Destination $OutFile
    }
    $url = 'https://github.com/example/windows-privacy-guard/archive/refs/heads/main.zip'
    $first = (& $installer -RepositoryZipUrl $url -InstallRoot $installRoot -NoLaunch) | ConvertFrom-Json
    $second = (& $installer -RepositoryZipUrl $url -InstallRoot $installRoot -NoLaunch) | ConvertFrom-Json
    if ($first.InstallDirectory -eq $second.InstallDirectory -or -not (Test-Path $first.Launcher) -or
        (Get-Content -LiteralPath $sentinel -Raw) -ne $originalContent) { throw 'Reinstall damaged existing files.' }
    $markup = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $second.Launcher -TestMode) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $markup.Result -ne 'PASS') { throw 'Installed launcher test mode failed.' }
    Write-Output 'Install/reinstall preserve old version and backup; installed popup test mode PASS'
    foreach ($case in @('DownloadFailure', 'MissingLauncher', 'InvalidZip')) {
        $downloadFailure = $case -eq 'DownloadFailure'
        if ($case -eq 'MissingLauncher') {
            $badPackage = Join-Path $testRoot 'bad\repo-main'
            New-Item -ItemType Directory -Path $badPackage -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $badPackage 'README.txt') -Value 'Incomplete package'
            $archive = Join-Path $testRoot 'bad.zip'
            Compress-Archive -LiteralPath $badPackage -DestinationPath $archive
        }
        if ($case -eq 'InvalidZip') {
            $archive = Join-Path $testRoot 'not-a-zip.zip'
            Set-Content -LiteralPath $archive -Value 'Not a ZIP archive'
        }
        $failed = $false
        try { & $installer -RepositoryZipUrl $url -InstallRoot $installRoot -NoLaunch | Out-Null } catch { $failed = $true }
        if (-not $failed -or (Get-Content -LiteralPath $sentinel -Raw) -ne $originalContent -or -not (Test-Path $first.Launcher)) {
            throw "Failure handling damaged the prior installation: $case"
        }
        Write-Output "$case preserves old installation PASS"
    }
}
finally {
    if ($absoluteRoot -eq [IO.Path]::GetFullPath($testRoot) -and
        (Split-Path -Leaf $absoluteRoot) -match '^WPG-InstallerTest-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $absoluteRoot -Recurse -Force
    }
}
