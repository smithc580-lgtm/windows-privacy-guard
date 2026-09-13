# Threat model

## Goal

Reduce Windows and Microsoft application data exposure with one auditable,
reversible baseline, while preserving security updates, Microsoft Defender,
activation, and ordinary local Windows operation.

## In scope

- Windows policy settings that control optional diagnostic and input data.
- Windows 11 Recall snapshot policy.
- Online speech recognition and selected app-privacy permissions.
- Local audit output and rollback records.

## Out of scope for the first release

- Capturing or rewriting every keyboard event.
- Installing a trusted root certificate or performing TLS interception.
- Blocking all Microsoft IP addresses or disabling Windows Update.
- Changing OneDrive, Microsoft 365, Edge, or third-party application settings
  without an explicit application-specific policy.

## Why there is no universal data scrambler

Applications generally send data through TLS. A network filter can block or
permit the connection, but it cannot redact plaintext after the application
has encrypted it. A TLS interception proxy would need to impersonate the
destination with a locally trusted certificate and still would not cover every
application. A keyboard hook that changes input before applications receive it
would break normal use and would itself create a highly sensitive component.

The safer order is: stop optional collection at the source, block selected
destinations or applications, then add opt-in redaction adapters for specific
applications that we control.
