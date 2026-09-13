[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-LocalOnlyMicrophoneApp.ps1')).Path
$source = Get-Content -LiteralPath $sourcePath -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Firewall script failed parsing.' }
# Replace only privilege detection and COM collection enumeration in memory.
# No production file is changed; no real firewall service is mutated.
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
$admin = $functions | Where-Object Name -eq 'Test-IsAdministrator'
$enumeration = $functions | Where-Object Name -eq 'Get-PolicyRules'
$source = $source.Replace($admin.Extent.Text, 'function Test-IsAdministrator { return $true }')
$source = $source.Replace($enumeration.Extent.Text, 'function Get-PolicyRules { param($Policy) $Policy.Rules.Items }')
$program = [scriptblock]::Create($source)
$fakeRules = [pscustomobject]@{ Items = [System.Collections.Generic.List[object]]::new(); RejectAdd = $false }
$fakeRules | Add-Member ScriptMethod Add {
    param($rule)
    if ($this.RejectAdd) { throw 'Injected firewall add failure' }
    $this.Items.Add($rule)
}
$fakeRules | Add-Member ScriptMethod Remove {
    param($name)
    for ($i = $this.Items.Count - 1; $i -ge 0; $i--) {
        if ($this.Items[$i].Name -eq $name) { $this.Items.RemoveAt($i) }
    }
}
$fakePolicy = [pscustomobject]@{ Rules = $fakeRules }
function New-Object {
    [CmdletBinding()]
    param([string]$ComObject)
    switch ($ComObject) {
        'HNetCfg.FwPolicy2' { return $fakePolicy }
        'HNetCfg.FWRule' { return [pscustomobject]@{ Name=''; Grouping=''; ApplicationName=''; Protocol=0; Direction=0; Action=1; Profiles=0; Enabled=$false } }
        default { throw "Unexpected COM object: $ComObject" }
    }
}
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('WPG-FirewallTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testExe = Join-Path $testDirectory 'fixture.exe'
$testBackup = Join-Path $testDirectory 'backup.json'
try {
    Copy-Item -LiteralPath (Join-Path $env:windir 'System32\whoami.exe') -Destination $testExe
    for ($cycle = 0; $cycle -lt 2; $cycle++) {
        $preview = (& $program -Mode Preview -ProgramPath $testExe) | ConvertFrom-Json
        Assert-True ($fakeRules.Items.Count -eq 0 -and $preview.MicrophoneAccess -eq 'Unchanged') 'Preview mutated rules or microphone access.'
        $result = (& $program -Mode Apply -ProgramPath $testExe -BackupFile $testBackup) | ConvertFrom-Json
        Assert-True ($fakeRules.Items.Count -eq 1) 'Expected one rule.'
        $rule = $fakeRules.Items[0]
        Assert-True ($rule.Name -eq $result.RuleName -and $rule.ApplicationName -eq $testExe -and $rule.Grouping -eq 'Windows Privacy Guard') 'Wrong rule identity.'
        Assert-True ($rule.Direction -eq 2 -and $rule.Action -eq 0 -and $rule.Protocol -eq 256 -and $rule.Profiles -eq 7 -and $rule.Enabled) 'Incorrect block configuration.'
        $audit = (& $program -Mode Audit) | ConvertFrom-Json
        Assert-True (@($audit).Count -eq 1 -and $audit[0].Action -eq 'Block') 'Audit did not describe the rule.'
        $duplicateRejected = $false
        try { & $program -Mode Apply -ProgramPath $testExe -BackupFile $testBackup | Out-Null } catch { $duplicateRejected = $_.Exception.Message -like 'A local-only rule already exists*' }
        Assert-True $duplicateRejected 'Duplicate apply was accepted.'
        & $program -Mode Rollback -BackupFile $testBackup | Out-Null
        Assert-True ($fakeRules.Items.Count -eq 0) 'Rollback without ProgramPath did not remove the rule.'
        & $program -Mode Rollback -BackupFile $testBackup | Out-Null
        Write-Output "Apply/audit/duplicate/rollback cycle $cycle PASS"
    }
    $fakeRules.RejectAdd = $true
    $addRejected = $false
    try { & $program -Mode Apply -ProgramPath $testExe -BackupFile $testBackup | Out-Null } catch { $addRejected = $_.Exception.Message -like '*Injected firewall add failure*' }
    Assert-True ($addRejected -and $fakeRules.Items.Count -eq 0) 'Failed add was reported as success.'
    $fakeRules.RejectAdd = $false
    & $program -Mode Apply -ProgramPath $testExe -BackupFile $testBackup | Out-Null
    $fakeRules.Items[0].Grouping = 'Unrelated owner'
    $ownershipRejected = $false
    try { & $program -Mode Rollback -BackupFile $testBackup | Out-Null } catch { $ownershipRejected = $_.Exception.Message -like 'The rule no longer matches*' }
    Assert-True ($ownershipRejected -and $fakeRules.Items.Count -eq 1) 'Rollback removed a rule with changed ownership.'
    Write-Output 'Add failure and rollback ownership checks PASS (fake firewall only)'
}
finally {
    foreach ($fixture in @($testExe, $testBackup)) {
        if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture }
    }
    Remove-Item -LiteralPath $testDirectory
}
