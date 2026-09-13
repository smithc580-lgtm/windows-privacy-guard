# Pre-release validation

This is a Windows 11 test candidate, not a production-readiness guarantee.
Machine-specific reports, recordings, VM images, credentials, and backup files
are deliberately not committed to this repository.

## Repeatable checks

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
$release = .\scripts\Build-Release.ps1 -Version 0.1.0-rc.3 | ConvertFrom-Json
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

## Known gaps

The earlier agent-created AppData installation was not visible during the
user's desktop launch; the precise reason was not established. The tested
default now uses Windows' configured Documents directory. Backups retain their
original LocalAppData location; the installer does not migrate them.

Public GitHub download and Windows reputation/security-prompt behavior remain
to be checked. The release is unsigned. Do not disable Windows protections to
install it. SHA-256 checks establish file integrity, not publisher identity.
The repository must not be described as guaranteeing zero telemetry or tested
on every Windows edition, update, language, management policy, or device.
