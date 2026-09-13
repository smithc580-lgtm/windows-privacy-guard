[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\scripts\Invoke-WindowsPrivacyBaseline.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source).Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Baseline script failed parsing.' }
# Load only the actual functions, without invoking Apply on Windows policies.
foreach ($name in @('Set-DwordControl', 'Restore-Control')) {
    $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        Where-Object Name -eq $name
    . ([scriptblock]::Create($definition.Extent.Text))
}

$testPath = 'HKCU:\Software\WPG-RegistryTest-' + [guid]::NewGuid().ToString('N')
try {
    New-Item -Path $testPath | Out-Null
    New-ItemProperty -LiteralPath $testPath -Name Unrelated -Value 'keep me' -PropertyType String | Out-Null
    foreach ($name in @('First', 'Second')) {
        Set-DwordControl -Control ([pscustomobject]@{ HivePath = $testPath; Name = $name; Value = 2 })
    }
    $key = Get-Item -LiteralPath $testPath
    if ($key.GetValue('First') -ne 2 -or $key.GetValue('Second') -ne 2 -or $key.GetValue('Unrelated') -ne 'keep me') {
        throw 'Apply cleared or changed a sibling registry value.'
    }
    foreach ($name in @('First', 'Second')) {
        Restore-Control -Entry ([pscustomobject]@{ Path = $testPath; Name = $name; Exists = $true; Value = 7; PropertyType = 'DWord' })
    }
    $key = Get-Item -LiteralPath $testPath
    if ($key.GetValue('First') -ne 7 -or $key.GetValue('Second') -ne 7 -or $key.GetValue('Unrelated') -ne 'keep me') {
        throw 'Rollback cleared or changed a sibling registry value.'
    }
    Restore-Control -Entry ([pscustomobject]@{ Path = $testPath; Name = 'First'; Exists = $false })
    $key = Get-Item -LiteralPath $testPath
    if ($key.GetValueNames() -contains 'First' -or $key.GetValue('Second') -ne 7 -or $key.GetValue('Unrelated') -ne 'keep me') {
        throw 'Rollback of an originally absent value affected other values.'
    }
    [pscustomobject]@{ Result = 'PASS'; SharedKeyApply = 'PASS'; SharedKeyRollback = 'PASS'; UnrelatedValuePreserved = $true } | ConvertTo-Json
}
finally {
    # The exact key is generated above solely for this test; it has no subkeys.
    if ($testPath -match '^HKCU:\\Software\\WPG-RegistryTest-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $testPath)) {
        Remove-Item -LiteralPath $testPath -Force
    }
}
