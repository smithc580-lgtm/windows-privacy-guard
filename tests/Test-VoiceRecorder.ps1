[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$exe = @(& (Join-Path $repo 'scripts\Start-VoiceRecorder.ps1') -BuildOnly)[-1]
$reports = Join-Path $repo 'reports'
New-Item -ItemType Directory -Path $reports -Force | Out-Null
foreach ($test in @(@{ Mode='--self-test'; File='recorder-tests.txt' }, @{ Mode='--devices'; File='recorder-devices.txt' })) {
    $report = Join-Path $reports $test.File
    $process = Start-Process -FilePath $exe -ArgumentList @($test.Mode, "`"$report`"") -WindowStyle Hidden -Wait -PassThru
    Get-Content -LiteralPath $report
    if ($process.ExitCode -ne 0) { throw "Recorder check failed: $($test.Mode)" }
}
Write-Output 'No microphone stream was started and no sound was played by these checks.'
