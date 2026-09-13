[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://github\.com/.+/.+/archive/refs/heads/.+\.zip$')]
    [string] $RepositoryZipUrl,

    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'WindowsPrivacyGuard'),

    [switch] $NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RepositoryZipUrl -match 'REPLACE_ME') {
    throw 'Set REPO_ZIP_URL in DownloadAndLaunch.cmd to the public GitHub repository URL before using the downloader.'
}

$runId = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('wpg-download-' + $runId)
New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null
$stageAbsolute = (Resolve-Path -LiteralPath $stageRoot).Path
try {
    $downloadPath = Join-Path $stageRoot 'repository.zip'
    $extractRoot = Join-Path $stageRoot 'extracted'
    Invoke-WebRequest -Uri $RepositoryZipUrl -OutFile $downloadPath -UseBasicParsing
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractRoot
    $roots = @(Get-ChildItem -LiteralPath $extractRoot -Force)
    if ($roots.Count -ne 1 -or -not $roots[0].PSIsContainer) {
        throw 'The downloaded repository must contain exactly one top-level directory.'
    }
    $sourceRoot = $roots[0].FullName
    foreach ($relative in @('WindowsPrivacyGuard.cmd', 'scripts\Start-WindowsPrivacyGuard.ps1',
            'scripts\Invoke-WindowsPrivacyBaseline.ps1', 'scripts\Invoke-WindowsDebloat.ps1',
            'scripts\Set-LocalOnlyMicrophoneApp.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
            throw "The downloaded repository is missing $relative."
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'scripts') -Filter '*.ps1' -File) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { throw "The downloaded script $($file.Name) has syntax errors." }
    }
    # Never replace a previous installation or its backups. Each launch has its
    # own version directory; existing files remain available for recovery.
    $releasesRoot = Join-Path $InstallRoot 'releases'
    New-Item -ItemType Directory -Path $releasesRoot -Force | Out-Null
    $versionRoot = Join-Path $releasesRoot $runId
    Copy-Item -LiteralPath $sourceRoot -Destination $versionRoot -Recurse -ErrorAction Stop
    $launcher = Join-Path $versionRoot 'scripts\Start-WindowsPrivacyGuard.ps1'
    if ($NoLaunch) {
        [pscustomobject]@{ InstallDirectory = (Resolve-Path -LiteralPath $versionRoot).Path; Launcher = $launcher; Launched = $false } | ConvertTo-Json
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher
        if ($LASTEXITCODE -ne 0) { throw "The launcher exited with code $LASTEXITCODE. Installed files were retained." }
    }
}
finally {
    # Only the unique staging directory created by this invocation is removed.
    $expectedStage = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wpg-download-' + $runId)))
    if ($stageAbsolute -eq $expectedStage -and (Test-Path -LiteralPath $stageAbsolute)) {
        $stageItem = Get-Item -LiteralPath $stageAbsolute
        if (($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Remove-Item -LiteralPath $stageAbsolute -Recurse -Force
        }
    }
}
