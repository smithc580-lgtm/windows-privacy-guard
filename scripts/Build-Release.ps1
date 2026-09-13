[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[a-z0-9.]+)?$')] [string] $Version = '0.1.0-rc.3',
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $OutputDirectory ('build-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $buildRoot 'WindowsPrivacyGuard'
New-Item -ItemType Directory -Path $package -Force | Out-Null
# Explicit allowlist: no reports, backups, user recordings, VM files, or compiled caches.
$files = @('Install.cmd', 'WindowsPrivacyGuard.cmd', 'VoiceRecorder.cmd', 'README.md', 'LICENSE',
    'scripts/Install-WindowsPrivacyGuard.ps1', 'scripts/Start-WindowsPrivacyGuard.ps1',
    'scripts/Invoke-WindowsPrivacyBaseline.ps1', 'scripts/Invoke-WindowsDebloat.ps1',
    'scripts/Set-LocalOnlyMicrophoneApp.ps1', 'scripts/Get-WindowsPrivacyAudit.ps1',
    'scripts/Start-VoiceRecorder.ps1', 'recorder/AudioEngine.cs', 'recorder/DraftStore.cs',
    'recorder/NativeAudio.cs', 'recorder/VoiceRecorder.cs', 'recorder/RecorderTests.cs',
    'recorder/README.md', 'docs/threat-model.md')
$entries = @(foreach ($relative in $files) {
    $source = Join-Path $repo $relative
    if ($relative.EndsWith('.ps1')) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { throw "Parse failure: $relative" }
    }
    $target = Join-Path $package $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
    $hash=[Security.Cryptography.SHA256]::Create(); $stream=[IO.File]::OpenRead($target)
    try { $digest=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $hash.Dispose() }
    [pscustomobject]@{Path=$relative; Sha256=$digest}
})
[pscustomobject]@{Schema=1;Version=$Version;Files=$entries} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
$zip = Join-Path $buildRoot ("WindowsPrivacyGuard-$Version.zip")
Compress-Archive -LiteralPath $package -DestinationPath $zip
$hash=[Security.Cryptography.SHA256]::Create(); $stream=[IO.File]::OpenRead($zip)
try { $digest=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
finally { $stream.Dispose(); $hash.Dispose() }
($digest + '  ' + [IO.Path]::GetFileName($zip)) | Set-Content -LiteralPath ($zip + '.sha256') -Encoding ASCII
[pscustomobject]@{Version=$Version;Archive=(Resolve-Path $zip).Path;Sha256=$digest;PackageDirectory=(Resolve-Path $package).Path;FileCount=$files.Count} | ConvertTo-Json
