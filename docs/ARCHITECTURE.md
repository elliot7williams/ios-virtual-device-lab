# Architecture

## Boundary

The app is a standalone Swift package and macOS application. SwiftUI never constructs a `vphone-cli` command. It submits typed requests through `LabBackend`, allowing a different engine to replace or coexist with vphone without changing frontend views.

```text
SwiftUI views
    │
LabAppModel (main-actor state and workflows)
    │
LabBackend protocol
    ├── VPhoneBackend actor
    └── MockLabBackend actor
         │
         ├── VMCreationRequest / VMConfigurationRequest
         ├── LabProgressEvent
         ├── PerformanceSample / DiagnosticExportResult
         └── lifecycle, firmware, snapshot, control, and test operations
                  │
                  ├── process adapter → vphone-cli
                  ├── host-control socket → screenshots, input, guest file export
                  └── bundle scanners and persistent lab stores
```

## Components

### SwiftUI frontend

`LabRootView` provides the application shell. Devices, firmware, snapshots, and activity are independent feature views that share `LabAppModel`.

### Application model

`LabAppModel` owns UI state, guards operations with host readiness and VM lifecycle rules, relays streaming output, and persists the bounded activity history.

### Backend adapter

`VPhoneBackend` resolves an installed or local `vphone-cli`, passes an explicit VM library root, and maps high-level actions to stable CLI operations. Long-running commands execute away from the main actor and stream output back to the UI.

`LabBackend` is the formal dependency boundary. It publishes a backend descriptor and capability set, consumes typed device requests, emits structured progress, and owns engine-specific syntax. The application model accepts any conforming backend, while `MockLabBackend` supports deterministic service, workflow, and UI-model tests without entitled virtualization. See [Backend API](BACKEND_API.md).

### Hardware and compatibility data

`hardware-profiles.json` describes virtual device identity, SoC, CPU, memory, disk, display, GPU, networking, and iOS version range. `compatibility-manifest.json` records boot status, device profiles, cloudOS pairing, evidence, known issues, required patches, and app-deployment support. Importing an IPSW identifies its version/build/device and combines both databases into a recommendation. VM creation blocks incompatible or mismatched inputs and requires acknowledgement for experimental or unverified inputs.

`backend-catalog.json` is separate from runtime adapters. It records implemented, planned, research-only, and reference-only engines plus capability evidence. `BackendRecommendationEvaluator` may select only a catalog entry that is both an active adapter and selectable. A QEMU research record can explain a future direction but cannot become an automatic fallback. A Corellium benchmark record can never execute.

`third-party-catalog.json` is the machine-readable provenance registry surfaced by the app. It records source, license or terms, exact version/pinning status, integration state, source-code use, modifications, distribution status, and obligations. Human-readable policy remains in `THIRD_PARTY.md`.

### Read-only scanner

VM discovery reads the backend-compatible `config.plist` and `restore-info.json` formats directly. This lets the library remain visible when the entitled backend binary is blocked by host policy.

### Firmware manager

The firmware catalog stores paths and parsed filename metadata. External IPSWs are indexed in place. Files already under `~/.vphone/ipsws` are discovered automatically.

### Snapshot manager

Snapshots use backend exports as `.tgz` archives plus small JSON metadata sidecars. Restoring imports a snapshot as a new VM, preserving both the source VM and archive.

### Networking, audio, isolation, and diagnostics

Network, audio, and isolation policy are part of the backend request even when a particular engine reports only partial support. This keeps future adapters compatible without pretending the current engine implements unavailable device simulation.

The preflight checks OS version, architecture, hardware model, nested virtualization, SIP, research guests, backend location, and a real `vphone-cli --help` launch. Activity records backend output and structured progress locally. Diagnostic bundles combine manager output, host unified logs, VM metadata, screenshots, performance samples, and bounded guest log/crash exports. The enhanced vphone host socket exposes guest file list/get through its existing vphoned channel; no unrestricted guest shell is introduced.

### Compatibility and testing

The checked-in JSON compatibility manifest separates supported evidence from experimental, researching, incompatible, and unverified pairings. Firmware validation checks the IPSW ZIP structure, requires `BuildManifest.plist`, records SHA-256, and associates the image with manifest evidence.

Test runs persist one result per selected VM. Every selected assertion produces explicit pass/fail evidence, and each completed run writes JSON plus a readable Markdown report. The baseline acceptance runner operates only on temporary clones and cleans up the restored VM, snapshot, and clone after exercising the complete lifecycle.

### Automation and plugins

Automation is an ordered typed sequence with values, delays, retries, conditions, scheduling metadata, headless metadata, and failure behavior. The desktop orchestrator and the packaged `vdlctl` runner consume the same persisted workflow schema; the CLI adds resource admission, launchd installation, stable exit codes, and JSON/JUnit/HTML reports. Plugins are user-installed executable descriptors with API versions, permissions, explicit trust, and executable checksum pinning. They never auto-run and receive device context through narrowly named environment variables.

### Operational readiness

`ProductionHardeningState` loads migration history, interrupted-operation recovery, host compatibility evidence, environment profiles, storage policy, plugin audits, and remote-agent configuration away from the main actor. `AcceptanceEvaluator` derives a conservative release gate from real host, device, guest-protocol, assertion, and diagnostic evidence. `operation-journal.json` is written before destructive or multi-step backend work and is never used to delete data automatically.

The guest protocol is negotiated through `LabBackend.guestProtocolHandshake`. Environment assignments remain stored test intent unless the backend or a trusted extension declares the corresponding capability. The remote/CI agent reuses `HeadlessRunner` through an HMAC-authenticated local queue rather than introducing a second orchestration engine.

### Qualification and scale boundary

`LabExpansionState` is the persisted evidence index for the 0.11 execution layer. It records derived maturity, exact qualification rows, installed adapter checksums and invocations, guest-automation results, replay executions, symbolication, fleet leases/heartbeats, monotonic timeline sessions, coverage reports, and physical target discovery. `LabAppModel` coordinates these services but does not weaken their gates.

The runtime adapter host is process-isolated from SwiftUI and validates the declared operation, executable checksum, bounded protocol response, schema version, and request ID. Guest automation remains inside `LabBackend`, so the frontend still never constructs vphone host-control messages. Hybrid routing normalizes virtual devices and CoreDevice physical devices into a shared target record; routing is policy only and does not silently deploy to a physical phone.

### Continuity and beta boundary

`LabContinuityView` is an operator surface over small, testable services rather than a second backend. `ExternalStorageManager` records the resolved volume identity outside the lab root, detects a broken `~/.vphone` symlink before backend directory creation, and atomically swaps only an existing symlink. It refuses to overwrite a real directory or accept a filesystem/home root.

`RecoveryCenterStore` preserves the original operation journal and records operator decisions separately. Resume and rollback selections provide audited guidance; they never infer destructive cleanup. `CanonicalFixtureStore` persists identities and hashes only. `LabfilePlanner` computes create/update/unchanged/blocked changes before apply; apply never deletes devices and resolves firmware exclusively from the authorized local catalog. The desktop and `vdlctl labfile` paths share the schema and safety model.

Evidence recertification, capacity recommendations, hostile-input fixtures, retention preview/quarantine, operational objectives, and beta verification are independent policy/evaluation services. Empty or stale evidence fails closed. Human accessibility and legal checkboxes remain attestations with timestamps, not automatically manufactured claims.

## Replaceable backend

Future backend implementations should conform to the same conceptual surface:

- list and inspect devices;
- create, launch, stop, configure, clone, and delete;
- import firmware and report compatibility;
- export/import consistent device state;
- deploy an app where the guest agent supports it;
- stream diagnostics.
- report structured progress and performance samples;
- accept network, audio, isolation, and hardware-profile policy even when reporting a capability as unsupported.

No UI view should need to know the command-line syntax of a backend.

Before an adapter becomes selectable it must also have a pinned source/version, completed license review, host preflight, capability evidence, failure-safe implementation, and at least one reproducible firmware acceptance record. Catalog presence alone is never enablement.
