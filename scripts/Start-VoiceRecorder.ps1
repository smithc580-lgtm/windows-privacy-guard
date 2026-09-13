[CmdletBinding()]
param([switch]$BuildOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repo 'recorder'
$bin = Join-Path $sourceRoot 'bin'
$compiler = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'This recorder requires 64-bit Windows and the Windows .NET Framework compiler.' }
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$sources = @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cs' -File | Sort-Object Name | ForEach-Object { $_.FullName })
$sourceText = ($sources | ForEach-Object { [IO.File]::ReadAllText($_) }) -join [Environment]::NewLine
$hasher = [Security.Cryptography.SHA256]::Create()
try { $buildId = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceText))).Replace('-', '').Substring(0, 16) }
finally { $hasher.Dispose() }
# Keep updates separate from an already-running version; do not interrupt a take.
$executable = Join-Path $bin ("LocalVoiceRecorder-" + $buildId + '.exe')
if (-not (Test-Path -LiteralPath $executable)) {
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/out:$executable" @sources
    if ($LASTEXITCODE -ne 0) { throw 'The recorder did not compile.' }
}
if ($BuildOnly) { Write-Output $executable; return }
# Interactive application explicitly requested by the user; no administrator rights required.
Start-Process -FilePath $executable
