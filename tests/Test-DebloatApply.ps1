[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\scripts\Invoke-WindowsDebloat.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source).Path,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Debloat script failed parsing.' }
$setup=@()
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.IfStatementAst]) { break }
    $setup += $statement.Extent.Text
}
$setupCode=[scriptblock]::Create($setup -join [Environment]::NewLine)
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('WPG-DebloatTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-Cleanup([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
try {
    foreach ($case in @('CurrentOnly','ProvisionedOnly','BothScopes','UncheckedKept','Empty','Unknown','Protected',
        'Duplicate','Stale','InvalidScope','Framework','Resource','NonRemovable','Dependency','ProvisionedDependency',
        'ProvisionedFramework','InventoryExists','RemoveRejects','PartialFailure','ChangedBeforeRemoval','InventoryFailure')) {
        & {
            . $setupCode
            $news=[pscustomobject]@{Name='Microsoft.BingNews';Version=[version]'1.0';PackageFullName='news-installed';IsFramework=$false;IsResourcePackage=$false;NonRemovable=$false;Dependencies=@()}
            $weather=[pscustomobject]@{Name='Microsoft.BingWeather';Version=[version]'1.0';PackageFullName='weather-installed';Dependencies=@()}
            $fixture=@{Installed=@($news,$weather);Provisioned=@(
                [pscustomobject]@{DisplayName='Microsoft.BingNews';Version=[version]'1.0';PackageName='news-provisioned'},
                [pscustomobject]@{DisplayName='Microsoft.BingWeather';Version=[version]'1.0';PackageName='weather-provisioned'}
            );Calls=[Collections.Generic.List[string]]::new();ProvisionedReads=0;CurrentReads=0}
            $selection=@([pscustomobject]@{Name='Microsoft.BingNews';FullName='news-installed';Scope='CurrentUser'})
            if ($case -in @('ProvisionedOnly','RemoveRejects','ProvisionedDependency','ProvisionedFramework','InventoryFailure')) {
                $selection=@([pscustomobject]@{Name='Microsoft.BingNews';FullName='news-provisioned';Scope='Provisioned'})
            }
            if ($case -in @('BothScopes','PartialFailure')) { $selection += [pscustomobject]@{Name='Microsoft.BingNews';FullName='news-provisioned';Scope='Provisioned'} }
            if ($case -eq 'Empty') { $selection=@() }
            if ($case -eq 'Unknown') { $selection[0].Name='Unknown.App' }
            if ($case -eq 'Protected') { $selection[0].Name='Microsoft.WindowsStore'; $optionalPackages['Microsoft.WindowsStore']='Store' }
            if ($case -eq 'Duplicate') { $selection += $selection[0] }
            if ($case -eq 'Stale') { $selection[0].FullName='news-old-version' }
            if ($case -eq 'InvalidScope') { $selection[0].Scope='AllUsers' }
            if ($case -in @('Framework','ProvisionedFramework')) { $news.IsFramework=$true }
            if ($case -eq 'Resource') { $news.IsResourcePackage=$true }
            if ($case -eq 'NonRemovable') { $news.NonRemovable=$true }
            if ($case -in @('Dependency','ProvisionedDependency')) { $weather.Dependencies=@([pscustomobject]@{Name='Microsoft.BingNews'}) }
            $inventory=Join-Path $testRoot ($case+'.json')
            if ($case -eq 'InventoryExists') { 'keep this existing inventory' | Set-Content -LiteralPath $inventory }
            function Get-AppxPackage {
                [CmdletBinding()]param([switch]$AllUsers)
                if (-not $AllUsers) { $fixture.CurrentReads++ }
                if ($case -eq 'ChangedBeforeRemoval' -and $fixture.CurrentReads -ge 2) { $news.PackageFullName='news-new-version' }
                $fixture.Installed
            }
            function Get-AppxProvisionedPackage {
                [CmdletBinding()]param([switch]$Online)
                Assert-Cleanup $Online 'Offline image enumeration requested.'
                $fixture.ProvisionedReads++
                if ($case -eq 'InventoryFailure') { throw 'Injected inventory failure' }
                $fixture.Provisioned
            }
            function Assert-BackupBeforeRemoval {
                Assert-Cleanup (Test-Path -LiteralPath $inventory) 'Removal happened before backup.'
                $record=Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json
                Assert-Cleanup ($record.Schema -eq 2 -and $record.Planned.Count -eq $selection.Count) 'Incomplete planned inventory before removal.'
            }
            function Remove-AppxPackage {
                [CmdletBinding()]param([string]$Package)
                Assert-BackupBeforeRemoval
                Assert-Cleanup ($Package -ceq 'news-installed') 'Unchecked/wrong installed package removed.'
                $fixture.Calls.Add('CurrentUser|'+$Package)
                $fixture.Installed=@($fixture.Installed | Where-Object PackageFullName -ne $Package)
            }
            function Remove-AppxProvisionedPackage {
                [CmdletBinding()]param([switch]$Online,[string]$PackageName)
                Assert-BackupBeforeRemoval
                Assert-Cleanup ($Online -and $PackageName -ceq 'news-provisioned') 'Wrong provisioned target or offline mode.'
                if ($case -in @('RemoveRejects','PartialFailure')) { throw 'Injected removal rejection' }
                $fixture.Calls.Add('Provisioned|'+$PackageName)
                $fixture.Provisioned=@($fixture.Provisioned | Where-Object PackageName -ne $PackageName)
                [pscustomobject]@{RestartNeeded=$false}
            }
            $expectSuccess=$case -in @('CurrentOnly','ProvisionedOnly','BothScopes','UncheckedKept')
            $threw=$false
            try { $result=Invoke-SelectedCleanup -Json (ConvertTo-Json -InputObject $selection -Compress) -InventoryPath $inventory | ConvertFrom-Json }
            catch { $threw=$true; if ($expectSuccess) { throw } }
            Assert-Cleanup ($threw -ne $expectSuccess) "Unexpected outcome: $case"
            if ($expectSuccess) {
                Assert-Cleanup ($result.Mode -eq 'Apply' -and $fixture.Calls.Count -eq $selection.Count) 'Selection/removal count differs.'
                $record=Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json
                Assert-Cleanup ($record.Status -eq 'Completed' -and $record.Completed.Count -eq $selection.Count) 'Incomplete success record.'
            } elseif ($case -eq 'PartialFailure') {
                $record=Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json
                Assert-Cleanup ($fixture.Calls.Count -eq 1 -and $record.Completed.Count -eq 1 -and $record.Status -eq 'Failed') 'Partial failure hidden.'
            } else { Assert-Cleanup ($fixture.Calls.Count -eq 0) 'Rejected selection caused removal.' }
            if ($case -in @('RemoveRejects','ChangedBeforeRemoval')) {
                $record=Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json
                Assert-Cleanup ($record.Status -eq 'Failed' -and $record.Completed.Count -eq 0 -and $record.Planned.Count -eq 1) 'Failure lost planned inventory.'
            }
            if ($case -eq 'InventoryExists') { Assert-Cleanup ((Get-Content -Raw $inventory).Trim() -eq 'keep this existing inventory') 'Old inventory overwritten.' }
            if ($case -in @('CurrentOnly','UncheckedKept')) { Assert-Cleanup ($fixture.ProvisionedReads -eq 0) 'Provisioned packages inspected without scope selection.' }
            Assert-Cleanup (@($fixture.Installed | Where-Object PackageFullName -eq 'weather-installed').Count -eq 1) 'Unchecked installed app changed.'
            Assert-Cleanup (@($fixture.Provisioned | Where-Object PackageName -eq 'weather-provisioned').Count -eq 1) 'Unchecked provisioned copy changed.'
            Write-Output "$case PASS"
        }
    }
} finally {
    $absolute=[IO.Path]::GetFullPath($testRoot)
    if ((Split-Path -Parent $absolute) -ne ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $absolute) -notmatch '^WPG-DebloatTest-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup path.' }
    Get-ChildItem -LiteralPath $absolute -File -Filter '*.json' | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $absolute
}
