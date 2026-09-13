# Release validation

Version 0.1.1 is the checkbox/provisioning update. Its release ZIP is the exact
package used for the local installer tests and user desktop check. Repository
documentation was updated for publication without rebuilding that tested ZIP.
The previous release tag and installer are retained unchanged.
Machine-specific reports, recordings, VM images, credentials, and backup files
are deliberately not committed to this repository.

## Repeatable checks

The 0.1.1 checkbox/provisioning update adds mocked tests for exact
selection forwarding, check-all/uncheck-all, independent scope choices, empty
selection refusal, protected/unknown/dependency rejection, changed identities,
pre-removal inventories, and partial failures. These tests never run real
package-removal commands. All nine safe suites passed twice. The earlier
release validation below applies to the original release; the new 0.1.1
checkbox/provisioning checks are recorded separately here.

An agent-launched elevated process received `Access is denied` from the
provisioning inventory query. The same read-only check subsequently passed in
the user's administrator PowerShell, finding five installed optional entries
and seven provisioned copies. The precise process-context difference remains
unexplained. The UI reports inventory denial and lists only verified
current-account choices; mocked tests cover this fallback.

The user confirmed the source preview's Check all / individual uncheck /
Uncheck all behavior. In the retained Windows 11 evaluation VM, two real
removal rounds passed with Solitaire: first remove only its provisioned copy
and verify installed registrations are unchanged, then remove its installed
copy and verify every unchecked package remains unchanged. Both operation
inventories reported completion. After each round, checkpoint restoration
returned the installed and provisioned package lists to their original values.
The VM was saved afterward. No host app-removal commands ran in this test.
This validates that app on that guest, not every allowlisted app, other users'
registrations, a newly created account, or behavior after a future Windows update.
Checkpoint restoration is test infrastructure, not an app-undo feature.

The exact 0.1.1 ZIP passed two install/reinstall test rounds, including preserved
backups and old shortcuts, installed WPF TestMode, recorder compilation, and
rejection of malformed packages. The user then installed it locally and
confirmed the updated desktop panel and checkbox controls worked. This is not
a new public-browser download or post-update reboot test.

From Windows PowerShell 5.1 in a checkout:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-SafeRegressionTests.ps1 -Rounds 2
```

The nine suites cover syntax/preview, temporary registry value preservation,
mocked debloat/firewall actions, download failure handling, WPF action helpers,
backup validation, layout, and recorder synthetic checks. They do not apply
the privacy baseline, remove real apps, change real firewall rules, or capture
microphone audio. The registry test uses only its own temporary HKCU key.
Fixture files and that key are cleaned up; reports remain under ignored reports/.

Build and test a release package:

```powershell
$release = .\scripts\Build-Release.ps1 -Version 0.1.1 | ConvertFrom-Json
.\tests\Test-ReleasePackage.ps1 -Archive $release.Archive -Rounds 2
```

Package tests cover install/reinstall, preserved backups and shortcuts, WPF
TestMode, recorder compilation, Documents path resolution, and corrupt/missing/
traversal/duplicate manifest rejection. They install into temporary directories,
not the real default location. Output ZIPs and generated files stay under dist/.

## Completed local checks

- Nine safe suites passed twice on the development host; earlier guest testing
  also passed two rounds on a Windows 11 Enterprise evaluation VM.
- Real privacy apply/restart/undo/restart was exercised; the seven original
  policy values were restored. Defender antivirus and real-time protection
  remained enabled. This was not a full Windows Update installation test.
- Selected-executable network blocking and restore were exercised, comparing
  a disposable executable with an unblocked control. This does not cover helper
  processes, services, or arbitrary microphone transmission.
- Allowlisted app removal and manifest re-registration were exercised inside a
  disposable guest. This does not prove Store reinstall or app-data recovery.
- A Windows 11 Pro user confirmed browser use, recorder playback, window
  resizing, and native privacy/network recovery controls.
- The Documents-based rc.3 installer passed install/reinstall checks and user
  desktop launch, including a launch after restarting Windows.
- A browser-downloaded ZIP matched the tested release hash, passed two package
  test rounds, and was extracted and installed by the user. The installed panel
  opened automatically. That download used a local HTTP server, not GitHub.
- The user subsequently completed public GitHub download and installation and
  reported that it installed successfully without warnings on the test PC.

## Known gaps

The earlier agent-created AppData installation was not visible during the
user's desktop launch; the precise reason was not established. The tested
default now uses Windows' configured Documents directory. Backups retain their
original LocalAppData location; the installer does not migrate them.

The public-download installation check passed on the test PC; this does not
guarantee the same warning behavior on every PC. The release is unsigned.
Do not disable Windows protections to
install it. SHA-256 checks establish file integrity, not publisher identity.
The repository must not be described as guaranteeing zero telemetry or tested
on every Windows edition, update, language, management policy, or device.
