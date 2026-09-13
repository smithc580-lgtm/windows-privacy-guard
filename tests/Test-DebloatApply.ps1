[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\scripts\Invoke-WindowsDebloat.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Debloat script failed parsing.' }
# Execute the real setup and Apply body with package commands replaced by fakes.
# The CLI administrator gate is not part of this isolated logic test.
$setup = @()
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.IfStatementAst]) { break }
    $setup += $statement.Extent.Text
}
$apply = $ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '$Mode -eq ''Apply'''
}
if (@($apply).Count -ne 1) { throw 'Could not locate the actual Apply branch.' }
$applyCode = [scriptblock]::Create(($apply.Clauses[0].Item2.Statements.Extent.Text -join [Environment]::NewLine))
$setupCode = [scriptblock]::Create(($setup -join [Environment]::NewLine))
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('WPG-DebloatTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    foreach ($case in @('Empty', 'Single', 'MultipleWithProtectedAndUnknown')) {
        & {
            . $setupCode
            $fixture = @()
            if ($case -ne 'Empty') {
                $fixture += [pscustomobject]@{ Name = 'Microsoft.BingNews'; Version = [version]'1.0'; PackageFullName = 'fake-news' }
            }
            if ($case -eq 'MultipleWithProtectedAndUnknown') {
                $fixture += [pscustomobject]@{ Name = 'Microsoft.BingWeather'; Version = [version]'1.0'; PackageFullName = 'fake-weather' }
                $fixture += [pscustomobject]@{ Name = 'Microsoft.WindowsStore'; Version = [version]'1.0'; PackageFullName = 'fake-store' }
                $fixture += [pscustomobject]@{ Name = 'Unknown.App'; Version = [version]'1.0'; PackageFullName = 'fake-unknown' }
                # Even an accidental allowlist addition must not remove Store.
                $optionalPackages['Microsoft.WindowsStore'] = 'Store'
            }
            $removed = [System.Collections.Generic.List[string]]::new()
            function Get-AppxPackage { [CmdletBinding()] param() $fixture }
            function Remove-AppxPackage { [CmdletBinding()] param([string]$Package) $removed.Add($Package) }
            $BackupFile = Join-Path $testDirectory ($case + '.json')
            $raw = (& $applyCode) -join [Environment]::NewLine
            $result = ConvertFrom-Json -InputObject $raw
            $expectedCount = switch ($case) { 'Empty' { 0 }; 'Single' { 1 }; default { 2 } }
            if ($result.Mode -ne 'Apply' -or @($result.Removed).Count -ne $expectedCount -or $removed.Count -ne $expectedCount) {
                throw "Incorrect removal count in $case."
            }
            if ($removed.Contains('fake-store') -or $removed.Contains('fake-unknown')) { throw 'Protected or unknown package selected.' }
            $backupText = Get-Content -LiteralPath $BackupFile -Raw
            $backupData = ConvertFrom-Json -InputObject $backupText
            if (-not $backupText.Trim().StartsWith('[') -or @($backupData).Count -ne $expectedCount) { throw "Invalid backup in $case." }
            Write-Output "$case PASS"
        }
    }
}
finally {
    # Remove only the three known fixture files and their non-recursive directory.
    foreach ($case in @('Empty', 'Single', 'MultipleWithProtectedAndUnknown')) {
        $fixturePath = Join-Path $testDirectory ($case + '.json')
        if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath }
    }
    Remove-Item -LiteralPath $testDirectory
}
