# Windows Privacy Guard

An audit-first, reversible Windows 11 privacy baseline.

**Public release: tested build 0.1.0-rc.3.** The validated candidate has been
promoted to a regular release; its tag and installer bytes are unchanged.
Use the packaged ZIP
from [GitHub Releases](https://github.com/smithc580-lgtm/windows-privacy-guard/releases/tag/v0.1.0-rc.3),
not GitHub's automatic source-code ZIP, for the installer with its manifest.
See [validation scope and test instructions](docs/TESTING.md).

The separate **Local Voice Recorder** opens with `VoiceRecorder.cmd`. It records
uncompressed WAV through WASAPI, offers microphone selection and live meters,
and keeps the takes you save. See [recorder instructions](recorder/README.md).

For a release ZIP: extract the entire ZIP first, open the extracted
`WindowsPrivacyGuard` folder, and double-click **Install.cmd**. It installs for
the current user, creates a **Windows Privacy Guard** desktop shortcut, and
opens the panel. Windows asks for administrator approval when the panel opens;
installation itself does not change privacy settings or remove apps. If a
shortcut already exists, a separately named shortcut is created without
overwriting it. Older releases and recovery backups are retained.

The default installation directory is `WindowsPrivacyGuard` inside the current
user's Windows Documents folder, using its configured location rather than a
hardcoded username or project directory. An explicit absolute `-InstallRoot`
can override it. Recovery backups remain in their existing LocalAppData
location; changing the application installation directory does not migrate or
delete them. If Documents is synced or redirected, the application files will
be placed there too; no sync settings are changed by the installer.

The release is currently unsigned. Do not disable Defender or SmartScreen to
install it. The manifest and ZIP checksum detect corruption, not a malicious
replacement of the package and its checksums. Only run packages from a source
you trust. Public GitHub download and installation were completed successfully
on the test PC with no warnings reported. Other PCs may show security prompts.

From a source checkout, double-click `WindowsPrivacyGuard.cmd` to launch the
control panel. The older `DownloadAndLaunch.cmd` is a developer template with
an unset GitHub URL, not the release installer; it is excluded from release ZIPs.

Build a local release candidate with `scripts/Build-Release.ps1`. Output goes
into a unique directory under `dist`, including a ZIP and SHA-256 sidecar.
Test the actual ZIP with `tests/Test-ReleasePackage.ps1 -Archive 'full ZIP path'`.

The panel keeps the last action and its recovery path visible. **Undo privacy
settings...** restores a selected baseline backup; **Restore app network...**
removes the matching Privacy Guard block using its backup. Neither action
automatically reinstalls removed apps. Choose backups you trust and undo the
most recent change first if you have applied the baseline multiple times.

To inspect the panel with all system-changing buttons disabled, without UAC:

```powershell
.\scripts\Start-WindowsPrivacyGuard.ps1 -PreviewOnly
```

Run the non-destructive pre-publication checks with:

```powershell
.\tests\Test-WindowsPrivacyGuard.ps1
```

## What this can and cannot do

This project can help you:

- turn several documented Windows privacy controls into one repeatable policy;
- identify whether Recall is enabled and whether snapshot policy is restricted;
- inspect Windows diagnostic-data, typing, speech, and app-privacy settings;
- create a rollback record before changing system policy.
- present safe suggestions for optional consumer apps before any cleanup.
- keep microphone permissions available while optionally blocking an app's outbound network traffic.

It cannot reliably rewrite arbitrary Microsoft traffic while it is in transit. Most modern Windows traffic uses TLS, so changing payload bytes without terminating TLS breaks the connection. A local proxy also cannot see traffic from every app, and a proxy certificate would create a new trust boundary. Encryption or obfuscation only helps when the receiving service is designed to decrypt it.

## Recommended architecture

1. **Audit** — collect settings and installed-feature information locally.
2. **Reduce collection at the source** — disable Recall snapshots, turn off optional diagnostic data, and disable connected experiences that are not needed.
3. **Constrain egress** — use Windows Firewall or a network gateway with an explicit allowlist for managed devices. Blocking is more dependable than trying to corrupt payloads.
4. **Redact selected data** — for applications you control, remove secrets and identifiers before requests are made. Keep this application-specific and testable.
5. **Verify** — compare settings and review network events after each change.

## First run

Audit without changing the computer:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Invoke-WindowsPrivacyBaseline.ps1 -Mode Audit
```

Preview the controls and then apply them from an elevated PowerShell window:

```powershell
.\scripts\Invoke-WindowsPrivacyBaseline.ps1 -Mode Preview
.\scripts\Invoke-WindowsPrivacyBaseline.ps1 -Mode Apply
```

Applying the baseline edits documented policy registry values. It does not
install a certificate, inspect TLS, alter keyboard input, disable Windows
Update, or block Defender. Default backups have unique filenames under
`%LOCALAPPDATA%\WindowsPrivacyGuard\backups`, independent of the launch folder.
Use the full backup path printed by Apply to roll back:

```powershell
.\scripts\Invoke-WindowsPrivacyBaseline.ps1 -Mode Rollback -BackupFile 'C:\full\path\to\your\privacy-baseline-backup.json'
```

Recall can optionally be removed as a Windows optional feature, which may
require a restart and is intentionally explicit:

```powershell
.\scripts\Invoke-WindowsPrivacyBaseline.ps1 -Mode Apply -RemoveRecall
```

The optional debloater uses a strict allowlist of current-user consumer apps.
It never removes unknown packages, provisioned packages, or protected Windows
components. It is separate from the privacy baseline because app removal can
affect a user's workflow. The GUI shows suggestions first and requires a
confirmation before removing listed apps.

```powershell
.\scripts\Invoke-WindowsDebloat.ps1 -Mode Preview
```

### Local-only microphone protection

Windows can control whether an app may use the microphone, but that permission
does not tell Windows whether the app later sends audio over its own encrypted
network connection. The GUI therefore offers a per-application local-only
profile: microphone access remains unchanged, while outbound network traffic
from the selected executable is blocked. This may disable all cloud features
of that app, not just voice upload.

```powershell
.\scripts\Set-LocalOnlyMicrophoneApp.ps1 -Mode Preview -ProgramPath 'C:\Path\To\App.exe'
.\scripts\Set-LocalOnlyMicrophoneApp.ps1 -Mode Apply -ProgramPath 'C:\Path\To\App.exe'
```

System executables under the Windows directory are rejected. The rule applies
only to the selected executable; child processes and other apps require their
own explicit rules.

## Important limitations

- Required Windows diagnostic data and required service data are not identical settings.
- Disabling Recall snapshots prevents new snapshots but does not by itself prove that every other Windows or third-party app has stopped collecting data.
- Domain blocking is brittle because Microsoft services use changing endpoints, CDNs, shared hosting, and certificate-based HTTPS.
- A transparent TLS interception proxy should not be the default design for a personal Windows machine. It adds operational and security risk and can interfere with updates, authentication, and certificate pinning.

## Next milestone

After reviewing an audit report, add application-specific policies for Edge,
Office, OneDrive, and other software separately. The enforcement layer should
support dry-run, rollback, logging, and a break-glass path for Windows Update
and security services.

## References

- Microsoft: [Privacy and control over your Recall experience](https://support.microsoft.com/en-us/windows/privacy/privacy-and-control-over-your-recall-experience)
- Microsoft Learn: [Optional diagnostic data for Windows](https://learn.microsoft.com/en-us/windows/privacy/optional-diagnostic-data)
- Microsoft Learn: [Required service data for Windows](https://learn.microsoft.com/en-us/windows/privacy/required-service-data)
