# Architecture

## Boundary

The app is a standalone Swift package and macOS application. It integrates with `vphone-cli` through a narrow backend adapter and does not copy or modify backend sources.

```text
SwiftUI views
    │
LabAppModel (main-actor state and workflows)
    │
LabBackend protocol
    ├── VPhoneBackend actor
    └── MockLabBackend actor
    ├── process adapter → vphone-cli
    ├── read-only VM bundle scanner
    ├── firmware catalog
    ├── snapshot metadata
    └── host preflight
```

## Components

### SwiftUI frontend

`LabRootView` provides the application shell. Devices, firmware, snapshots, and activity are independent feature views that share `LabAppModel`.

### Application model

`LabAppModel` owns UI state, guards operations with host readiness and VM lifecycle rules, relays streaming output, and persists the bounded activity history.

### Backend adapter

`VPhoneBackend` resolves an installed or local `vphone-cli`, passes an explicit VM library root, and maps high-level actions to stable CLI operations. Long-running commands execute away from the main actor and stream output back to the UI.

`LabBackend` is the formal dependency boundary. The application model accepts any conforming backend, while `MockLabBackend` supports deterministic workflow and UI tests without entitled virtualization.

### Read-only scanner

VM discovery reads the backend-compatible `config.plist` and `restore-info.json` formats directly. This lets the library remain visible when the entitled backend binary is blocked by host policy.

### Firmware manager

The firmware catalog stores paths and parsed filename metadata. External IPSWs are indexed in place. Files already under `~/.vphone/ipsws` are discovered automatically.

### Snapshot manager

Snapshots use backend exports as `.tgz` archives plus small JSON metadata sidecars. Restoring imports a snapshot as a new VM, preserving both the source VM and archive.

### Diagnostics

The preflight checks OS version, architecture, hardware model, nested virtualization, SIP, research guests, backend location, and a real `vphone-cli --help` launch. Activity records backend output and operation results locally. Diagnostic bundles combine that activity, host unified logs, VM metadata, available guest log/crash artifacts, and a control-socket screenshot.

### Compatibility and testing

The checked-in JSON compatibility manifest separates supported evidence from experimental, researching, incompatible, and unverified pairings. Firmware validation checks the IPSW ZIP structure, requires `BuildManifest.plist`, records SHA-256, and associates the image with manifest evidence.

Test runs persist one result per selected VM. The baseline acceptance runner operates only on temporary clones and cleans up the restored VM, snapshot, and clone after exercising the complete lifecycle.

### Automation and plugins

Automation is a typed sequence of backend/control-socket actions. Plugins are user-installed executable descriptors with explicit capabilities. They never auto-run and receive device context through narrowly named environment variables.

## Replaceable backend

Future backend implementations should conform to the same conceptual surface:

- list and inspect devices;
- create, launch, stop, configure, clone, and delete;
- import firmware and report compatibility;
- export/import consistent device state;
- deploy an app where the guest agent supports it;
- stream diagnostics.

No UI view should need to know the command-line syntax of a backend.
