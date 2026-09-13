[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function Get-CommandOutputSafe {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Command
    )

    try {
        return & $Command 2>$null
    }
    catch {
        return $null
    }
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
}
catch {
    $os = [pscustomobject]@{
        Caption = Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName'
        Version = Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion'
        BuildNumber = Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuild'
    }
}
$recallPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
$diagnosticPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'

$recallFeature = Get-CommandOutputSafe { Get-WindowsOptionalFeature -Online -FeatureName Recall }
$firewallProfiles = Get-CommandOutputSafe { Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction }

$report = [ordered]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    computerName = $env:COMPUTERNAME
    os = [ordered]@{
        caption = $os.Caption
        version = $os.Version
        build = $os.BuildNumber
    }
    recall = [ordered]@{
        optionalFeatureState = if ($null -eq $recallFeature) { $null } else { $recallFeature.State.ToString() }
        disableAiDataAnalysisPolicy = Get-RegistryValueSafe -Path $recallPolicyPath -Name 'DisableAIDataAnalysis'
        allowRecallEnablementPolicy = Get-RegistryValueSafe -Path $recallPolicyPath -Name 'AllowRecallEnablement'
        note = 'Per-user snapshot state is not inferred from this machine-level audit.'
    }
    diagnostics = [ordered]@{
        allowTelemetryPolicy = Get-RegistryValueSafe -Path $diagnosticPolicyPath -Name 'AllowTelemetry'
        disableDiagnosticDataViewerPolicy = Get-RegistryValueSafe -Path $diagnosticPolicyPath -Name 'DisableDiagnosticDataViewer'
        note = 'A missing policy value does not mean that no diagnostic or service data is sent.'
    }
    firewall = [ordered]@{
        profiles = @($firewallProfiles)
        note = 'This reports profile defaults only; it is not a complete outbound-connection inventory.'
    }
}

$json = $report | ConvertTo-Json -Depth 8
$json

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
    Write-Verbose "Wrote audit report to $OutputPath"
}
