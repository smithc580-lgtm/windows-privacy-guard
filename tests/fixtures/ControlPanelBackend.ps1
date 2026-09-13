# Test-only backend. Never imports or invokes the real mutation scripts.
param([string] $Mode, [string] $BackupFile, [string] $ProgramPath)
if ($Mode -in @('Audit', 'Preview')) {
    if ($panelFixture.ReadFails) { throw 'Injected audit failure' }
    if ($Mode -eq 'Audit') {
        '[{"Compliant":true,"Description":"Fixture privacy control"}]'
    } else {
        '{"Name":"Fixture.OptionalApp","DisplayName":"Fixture optional app"}'
    }
    return
}
$panelFixture.Calls.Add([pscustomobject]@{ Mode=$Mode; BackupFile=$BackupFile; ProgramPath=$ProgramPath })
if ($Mode -eq 'Apply') {
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $BackupFile) -Force)
    '{"FixtureOnly":true}' | Set-Content -LiteralPath $BackupFile -Encoding UTF8
}
if ($panelFixture.ActionFails) { throw 'Injected action failure' }
if ($panelFixture.Malformed) { '{"Mode":"Wrong"}'; return }
[pscustomobject]@{ Mode=$Mode; BackupFile=$BackupFile; Note='Fixture cleanup only.' } | ConvertTo-Json
