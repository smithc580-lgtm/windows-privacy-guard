[CmdletBinding()]
param([ValidateRange(1, 5)] [int] $Rounds = 2)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$regressionRoot = Split-Path -Parent $PSScriptRoot
$regressionReportDir = Join-Path $regressionRoot 'reports'
[void](New-Item -ItemType Directory -Path $regressionReportDir -Force)
$report = [ordered]@{ StartedAtUtc=[DateTime]::UtcNow.ToString('o'); Rounds=$Rounds; Result='RUNNING'; Runs=@(); FinishedAtUtc=$null }
$reportPath = Join-Path $regressionReportDir 'safe-regression-results.json'
$suites = @(
    'Test-WindowsPrivacyGuard.ps1',
    'Test-RegistryValuePreservation.ps1',
    'Test-DebloatApply.ps1',
    'Test-LocalOnlyFirewall.ps1',
    'Test-DownloadAndLaunch.ps1',
    'Test-ControlPanel.ps1',
    'Test-BaselineBackupValidation.ps1',
    'Test-ControlPanelLayout.ps1',
    'Test-VoiceRecorder.ps1'
)
# Each suite has its own process. No baseline apply, AppX removal, real firewall
# change, microphone capture, or download runs here. Registry preservation uses
# only a uniquely named temporary HKCU test key and removes that key afterward.
foreach ($round in 1..$Rounds) {
    foreach ($suite in $suites) {
        $started = [DateTime]::UtcNow
        # Keep native stderr in the report, including in Windows PowerShell 5.1.
        $ErrorActionPreference = 'Continue'
        try {
            $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $suite) 2>&1
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = 'Stop' }
        $report.Runs += [pscustomobject]@{
            Round=$round; Suite=$suite; ExitCode=$code
            Seconds=([DateTime]::UtcNow - $started).TotalSeconds
            Output=($output | Out-String).Trim()
        }
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-Output "Round $round / $suite : exit $code"
    }
}
$report.Result = if (@($report.Runs | Where-Object ExitCode -ne 0).Count) { 'FAIL' } else { 'PASS' }
$report.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Output "$($report.Result): $($report.Runs.Count) suite runs. Report: $reportPath"
if ($report.Result -ne 'PASS') { exit 1 }
