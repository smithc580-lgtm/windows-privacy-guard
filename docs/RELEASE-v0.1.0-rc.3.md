# Windows Privacy Guard v0.1.0-rc.3 — pre-release

Test candidate for Windows 11. Not a stable/production release.

## Download and install

Download **WindowsPrivacyGuard-0.1.0-rc.3.zip** from the assets below. Extract
the entire ZIP, open its WindowsPrivacyGuard folder, and double-click Install.cmd.
Do not use the automatic Source code ZIP for this installer: it lacks the
generated release manifest. Installation defaults to Windows' configured
Documents\WindowsPrivacyGuard directory and creates a desktop shortcut. Opening
the control panel requests administrator approval; installation does not apply
privacy settings or remove apps automatically.

The supplied ZIP is the exact locally tested candidate. Its bundled README
predates publication links; repository documentation has additional release
instructions. Runtime scripts and recorder source are unchanged.

SHA-256:

```text
78bbc92a86d98e77124efe8ed294284ae068677076d407357e9183f80eecdd6c
```

## Scope and caveats

- Seven reversible privacy settings; backup-based undo.
- Optional current-user allowlisted app removal is separate and requires
  confirmation. Its inventory backup is not an app restore image.
- Per-executable outbound firewall blocks leave microphone permission unchanged
  but also block that executable's calls/uploads. Helper processes are not covered.
- Includes a separate local WAV recorder.
- Does not guarantee zero telemetry, intercept TLS, disable Defender, or disable
  Windows Update.
- Unsigned: public download/reputation warning behavior has not yet been tested.
  Do not disable security protections to install it.

Two local package-test rounds, repeated regression checks, manual installation,
automatic panel launch, and Documents shortcut launch after reboot completed.
See docs/TESTING.md for scope and remaining gaps. Public GitHub download testing
is the next validation step, not a completed result.
