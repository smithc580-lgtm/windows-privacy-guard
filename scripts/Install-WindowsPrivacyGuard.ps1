[CmdletBinding()]
param(
    [string] $InstallRoot,
    [string] $ShortcutDirectory = [Environment]::GetFolderPath('Desktop'),
    [switch] $NoShortcut,
    [switch] $NoLaunch
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-GuardDefaultInstallRoot {
    param([string] $DocumentsDirectory = [Environment]::GetFolderPath('MyDocuments'))
    if ([string]::IsNullOrWhiteSpace($DocumentsDirectory) -or -not [IO.Path]::IsPathRooted($DocumentsDirectory)) {
        throw 'Windows did not provide an absolute Documents folder. Specify -InstallRoot explicitly.'
    }
    return Join-Path $DocumentsDirectory 'WindowsPrivacyGuard'
}
if (-not $PSBoundParameters.ContainsKey('InstallRoot')) { $InstallRoot = Get-GuardDefaultInstallRoot }
if ([string]::IsNullOrWhiteSpace($InstallRoot) -or -not [IO.Path]::IsPathRooted($InstallRoot)) {
    throw 'InstallRoot must be an absolute directory path.'
}
$packageRoot = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.Schema -ne 1 -or $manifest.Version -notmatch '^\d+\.\d+\.\d+(-[a-z0-9.]+)?$') {
    throw 'Unsupported release manifest.'
}
function Get-ReleaseHash([string] $Path) {
    $hash = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $hash.Dispose() }
}
$seen = @{}
foreach ($entry in $manifest.Files) {
    # Accept only relative path components, never traversal, ADS, or rooted paths.
    if ($entry.Path -isnot [string] -or $entry.Path -notmatch '^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*(/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*)*$' -or
        $seen.ContainsKey($entry.Path) -or $entry.Sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid manifest file entry.' }
    $seen[$entry.Path] = $true
    $path = Join-Path $packageRoot $entry.Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing release file: $($entry.Path)" }
    $cursor = Get-Item -LiteralPath $path
    while ($cursor.FullName -ne $packageRoot) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release symlinks are not supported.' }
        $cursor = Get-Item -LiteralPath (Split-Path -Parent $cursor.FullName)
    }
    if ((Get-ReleaseHash $path) -ne $entry.Sha256) { throw "Release hash mismatch: $($entry.Path)" }
}
foreach ($required in @('scripts/Start-WindowsPrivacyGuard.ps1', 'scripts/Invoke-WindowsPrivacyBaseline.ps1',
        'scripts/Invoke-WindowsDebloat.ps1', 'scripts/Set-LocalOnlyMicrophoneApp.ps1', 'WindowsPrivacyGuard.cmd')) {
    if (-not $seen.ContainsKey($required)) { throw "Incomplete release: $required" }
}
# A separate installation on every run preserves old releases and all backups.
$versionRoot = Join-Path $InstallRoot ('releases\' + $manifest.Version + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $versionRoot -ErrorAction Stop | Out-Null
foreach ($entry in $manifest.Files) {
    $destination = Join-Path $versionRoot $entry.Path
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageRoot $entry.Path) -Destination $destination
    if ((Get-ReleaseHash $destination) -ne $entry.Sha256) { throw 'Installed file verification failed; partial release retained.' }
}
Copy-Item -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Destination $versionRoot
$launcher = Join-Path $versionRoot 'scripts\Start-WindowsPrivacyGuard.ps1'
$powershell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcutPath = $null
if (-not $NoShortcut) {
    if (-not (Test-Path -LiteralPath $ShortcutDirectory -PathType Container)) { throw 'Desktop folder is unavailable; installed files retained.' }
    $shortcutPath = Join-Path $ShortcutDirectory 'Windows Privacy Guard.lnk'
    # Do not overwrite a pre-existing user shortcut.
    if (Test-Path -LiteralPath $shortcutPath) {
        $shortcutPath = Join-Path $ShortcutDirectory ('Windows Privacy Guard-' + [guid]::NewGuid().ToString('N') + '.lnk')
    }
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $launcher + '"'
    $shortcut.WindowStyle = 7 # Minimize the bootstrap console; do not hide the initial process.
    $shortcut.WorkingDirectory = $versionRoot
    $shortcut.Description = 'Windows Privacy Guard - review privacy settings and recovery options'
    $shortcut.Save()
}
if (-not $NoLaunch) {
    Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $launcher + '"')
}
[pscustomobject]@{ InstallDirectory=$versionRoot; Launcher=$launcher; Shortcut=$shortcutPath; LaunchRequested=(-not $NoLaunch); Version=$manifest.Version } | ConvertTo-Json
