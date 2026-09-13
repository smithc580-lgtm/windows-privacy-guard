# Windows Privacy Guard 0.1.1

Choose exactly which optional apps to remove:

- Individual checkboxes, with **Check all** and **Uncheck all** above the list.
- Separate choices for apps installed for this account and copies provisioned
  for new accounts. Only checked entries are removed, after confirmation.
- Protected Windows components, frameworks, resource packages, non-removable
  packages, and detected shared dependencies are excluded.
- Exact package identities are checked again before removal. Scoped inventories
  record the plan, completed removals, and failures.

Provisioned removal prevents automatic installation for new accounts; it does
not uninstall an app from other existing accounts. Removed apps lose their
features. Backups are inventories, not restore images: there is no automatic
app-removal undo.

## Install or update

Download **WindowsPrivacyGuard-0.1.1.zip**, extract the entire ZIP, then open
the extracted WindowsPrivacyGuard folder and run **Install.cmd**. No uninstall
is needed. Earlier installations, shortcuts, and backups are retained; a new
shortcut is created if one already exists. Installation alone does not remove
apps or apply privacy settings.

The package is unsigned. Do not disable Windows security protections to install
it. Checksums detect corruption; they do not authenticate the publisher.

## Validation

- Nine safe regression suites passed twice.
- Two real removal/checkpoint-restoration rounds passed with Solitaire inside
  a disposable Windows 11 evaluation VM. Unchecked package lists were unchanged.
- Two package installation/reinstallation test rounds passed.
- The user confirmed the local updated installation and desktop checkbox UI.

These checks do not cover every app, Windows configuration, new-user account,
or future Windows update. The exact desktop-tested ZIP is published unchanged;
its bundled README reflects the pre-publication stage. See the repository's
current README and validation notes for publication status.

SHA-256 for WindowsPrivacyGuard-0.1.1.zip:
`f99d9b3c0c5389025da4e22906888dff25289da6701cad26b451b5d995f6d278`
