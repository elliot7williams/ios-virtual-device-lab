# Roadmap

## Delivered in the MVP

| Plan stage | Current implementation |
|---|---|
| Backend baseline | `vphone-cli` adapter, host preflight, external storage, direct bundle discovery |
| SwiftUI shell | Native device library, detail view, lifecycle controls, status and settings |
| Firmware management | In-place IPSW catalog, metadata parsing, guided VM creation inputs |
| Snapshots | Named exports, restore-as-new-device, archive management, VM cloning |
| Developer workflow | Launch-and-install IPA/TIPA path, repeatable per-VM actions |
| Diagnostics | Persistent streaming activity console and actionable host preflight |
| Safety and integrity | Cancellation, timeouts, storage guards, firmware SHA-256, snapshot verification |
| Multi-version testing | Persistent multi-VM deployment runs, screenshots, and full baseline acceptance runner |
| Automation and extensions | Built-in workflows plus explicit executable plugin registry |
| Release engineering | CI, packaged artifacts, tagged releases, optional Developer ID/notarization tooling |
| Backend architecture | Typed replaceable engine requests, capability reporting, progress events, performance and diagnostic contracts |
| Hardware and compatibility | Versioned device profiles, automatic import recommendations, pairing enforcement, evidence database |
| Developer lab | App artifact library, configurable assertions/reports, workflow editor, Xcode helper |
| Lab controls | Network/audio/isolation policy, performance dashboard, guest crash/log export, snapshot retention |
| Extension security | Plugin API version, permissions, explicit trust, and checksum pinning |
| Firmware truth | BuildManifest parsing overrides misleading filenames and preserves build identities |
| Headless lab | `vdlctl`, resource admission, launchd schedules, and JSON/JUnit/HTML output |
| Diagnostic privacy | Sanitization, preview, encrypted export, local classification, opt-in analyzer extension |
| Production delivery | Developer ID/notary/update signing pipeline and verified update downloads |
| Operational acceptance | Explicit host, firmware, boot/control, network, audio, deployment, snapshot, diagnostic, and stability gates |
| Host upgrade safety | Versioned macOS/model/backend/iOS compatibility evidence and unverified-host warnings |
| State evolution | Idempotent schema migrations, automatic backups, rollback, and interrupted-operation journal |
| Test reproducibility | Assignable locale/timezone/appearance/accessibility/power/pressure/location/network profiles with capability gating |
| Guest contract | Protocol-version negotiation, declared capabilities, transport/authentication status, and payload limits |
| Storage governance | Quotas, free-space reserves, category inventory, duplicate firmware detection, and configuration-only exports |
| Firmware provenance | Source, importer, checksum, signing, ownership, and retention records |
| Plugin containment | Sandboxed writes/network, bounded execution/output, audit history, trust, and per-run initiation |
| Remote/CI execution | HMAC-authenticated file queue with submit, run-once, result, and status commands |
| Multi-backend governance | Capability/evidence registry, conservative firmware recommendation, non-selectable research/reference entries |
| Attribution governance | Machine-readable source/license/version/modification/obligation records surfaced in the app |
| Production qualification | Pinned host/backend/firmware/profile campaigns linked to signed acceptance evidence |
| Setup recovery | First-run readiness checks and in-app repair limited to safe filesystem items |
| Guest trust | Per-VM HMAC protocol v3, owner-only socket/key, clock window, and replay rejection |
| Evidence and recovery | Curve25519 evidence chain, reviewer workflow, manifest backups, verified restore staging |
| Agent operations | V2 keyring, rotation/revocation, nonces, replay ledger, cancellation, cleanup, health |
| Update lifecycle | Signed download enforcement, code/notary/migration staging, rollback copy and commands |
| Software supply chain | CycloneDX SBOM, SLSA-style provenance, resource hashes, CodeQL/dependency/secret checks |
| Fault tolerance | Non-destructive corruption, volume, disk, journal, output, expiry, and digest fixtures |
| External-storage continuity | Persisted volume identity, broken-link detection, safe startup gating, and atomic relinking for stopped labs |
| Recovery Center | Explicit Resume/Retry, Roll Back, Keep, and Abandon decisions with immutable journal history and audit records |
| Canonical fixtures | Hash-pinned firmware, hardware, backend, snapshot, guest-protocol, smoke-app, and acceptance identities without redistributing Apple assets |
| Declarative labs | Versioned JSON Labfiles with desktop and `vdlctl` plan/diff/apply workflows and no implicit deletion |
| Evidence lifecycle | Age, host, backend, firmware, and approval-based recertification rules that fail closed |
| Capacity calibration | Host CPU/RAM/storage probe, low-memory classification, and applyable resource-admission recommendations |
| Hostile-input boundaries | Bounded JSON, archive-path, traversal, absolute-path, and symlink-escape regression fixtures |
| Unified retention | Preview-first artifact retention, telemetry-off default, signed-evidence preservation, and recoverable quarantine |
| Operational objectives | Success-rate, P95-duration, soak, acceptance, resilience, second-volume restore, RTO, and RPO policy |
| Public-beta quality | VoiceOver, keyboard, reduced-motion, onboarding, support, asset-policy, legal-reference, localization, and privacy-safe support-report gates |

## Next engineering milestones

1. Complete and publish the first real baseline acceptance result after the required host restart and supported IPSW import.
2. Validate guest diagnostic export against the companion vphone host-control build on a running guest.
3. Run the ordered iOS 15 → 14 → 13 → 12 research matrix and update evidence only from reproducible results.
4. Implement the defined guest accessibility-tree API before claiming UI-element assertions; screenshot-diff and host/log/resource assertions are implemented.
5. Populate Apple Developer credentials and update-signing keys, then publish the first Developer ID signed and notarized release.
6. Expand full application UI automation after a stable real-VM fixture exists.
7. Research audio interruption/background-media and proxy/capture extensions without presenting unsupported simulation as available.
8. Exercise disaster-recovery staging on a second APFS volume and document operator recovery time.
9. Convert the authenticated queue into a supervised self-hosted runner only after threat-model review and mid-execution cancellation design.
10. Prototype a QEMU adapter only after choosing a pinned research implementation, completing component-level licensing review, and recording a reproducible iOS boot experiment.

## Older-iOS compatibility research

Older releases are not represented as supported until they boot and complete a documented validation matrix. Research proceeds one release at a time:

1. iOS 15
2. iOS 14
3. iOS 13
4. iOS 12

For each release, record:

- compatible IPSW/device model and signing inputs;
- boot-chain and firmware-container differences;
- device-tree and virtual hardware expectations;
- kernel and driver compatibility gaps;
- restore, guest-agent, networking, graphics, and input behavior;
- app deployment and developer API limitations;
- reproducible failure logs and required patches.

An IPSW appearing in the firmware catalog is not a support claim. The UI distinguishes `supported`, `experimental`, `researching`, `incompatible`, and `unverified` pairings from versioned evidence, while the acceptance report remains gated until a real workflow passes.
