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
| Backend adapter SDK | Versioned protocol-v3 manifests, declared capability validation, executable probing, license references, desktop import/export, and `vdlctl adapter check` |
| Deterministic test reset | Golden-snapshot, reinstall, app-data, permissions, keychain, network, and environment reset plans that block when guest capabilities are absent |
| Build identity | App metadata, checksum, code-signing team/authority, entitlement digest, executable UUID, dSYM, and source-revision catalog |
| Failure reproduction | Hash-pinned privacy-safe replay manifests containing run, Labfile, environment, fixture, and evidence references without protected assets or secrets |
| Quality trends | Pass rate, consecutive failure, P50/P95 duration, flaky/quarantine classification, and recent performance-regression detection |
| Multi-Mac scheduling | Capability-, memory-, concurrency-, health-, and drain-aware placement with explicit no-placement results |
| Unified timelines | Timestamp correlation across run phases, assertions, logs, screenshots, diagnostics, and performance with explicit missing-video capability |
| Security governance | Formal trust-boundary/threat/control report and metadata-only secret inventory with rotation, revocation, and export policy |
| Engineering quality | Seeded bounded archive/Labfile fuzz campaigns plus imported source-coverage thresholds that fail closed when coverage is unavailable |
| Beta operations | Internal/alpha/beta/stable channel policy, staged rollout, launch/crash/support/feedback gates, and privacy-safe feedback packages |
| Capability maturity | Evidence-derived designed/implemented/integrated/real-VM-qualified/release-ready levels with explicit blockers |
| Qualification publication | Exact device/profile/backend campaigns and approved-seal-only compatibility export |
| Runtime adapter host | Versioned checksum-pinned installation, sandboxed JSON invocation, audit records, upgrade, and rollback |
| Guest automation | Typed reset and accessibility operations gated by authenticated replay-protected guest capabilities |
| Replay execution | Hash, device, fixture, environment, artifact, and backend validation followed by a tracked real test run |
| Crash symbolication | Crash/dSYM UUID matching, indexed build verification, bounded `atos`, frames, and fingerprints |
| Fleet control | Heartbeats, stale-host rejection, reservations, expiring leases, release state, and dispatch audit schema |
| High-fidelity timeline | Host monotonic clock calibration, nanosecond events, source identity, artifact paths, and unavailable-source evidence |
| Automated quality evidence | LLVM/xccov JSON import, report checksum/source revision, and automatic coverage-gate input |
| Hybrid device lab | CoreDevice physical discovery and version/capability-aware virtual-or-physical target routing |
| Guest companion lifecycle | Bounded package builder, manifest/backend/protocol/hash verification, versioned installation, deployment gating, and checksum-valid rollback |
| Signing and physical operations | Identity/profile/entitlement/expiry inspection, staged signing, CoreDevice pairing/DDI detail, and exclusive expiring physical-device leases |
| Regression and fault lab | Maskable RGBA pixel diffs, accessibility-tree comparison, and typed network/audio fault requests gated by authenticated guest capability |
| Production fleet transport | Keychain client identities, platform trust plus certificate pinning, enrollment rotation/revocation, probes, and correlated bounded submissions |
| Scalable state | SQLite/WAL high-volume event store with full sync, payload hashes, idempotent JSON migration, integrity checks, and checkpointed backup |
| Upgrade certification | Exact host/macOS/backend/companion/adapter/schema certificates linked to passed campaigns and approved evidence seals |
| Dependency lifecycle | Immutable GitHub Action revisions, checkout v6/Node 24, upload-artifact v7/Node 24, CodeQL v4, and a CI-enforced maintenance audit |
| Operator drills | Bundled recovery, credential, compromised-host, evidence, failed-update, and device-loss runbooks with non-destructive prerequisite drills |
| v1 completion control | Versioned support contract, concrete companion audit, real-acceptance/matrix aggregation, macOS UI harness, fault receipts, mTLS/RBAC fleet server, reliability evidence, coverage ratchet, and signed release exit report |
| v1.1 operations hardening | Restart-safe host setup, permission onboarding, complete fleet worker lifecycle, signed audit chain, transitive evidence invalidation, live-storage encryption, startup reconciliation, atomic component activation, supply-chain enforcement, and support lifecycle policy |

## Next engineering milestones

1. Complete and publish the first real baseline acceptance result after the required host restart and supported IPSW import.
2. Validate guest diagnostic export against the companion vphone host-control build on a running guest.
3. Run the ordered iOS 15 → 14 → 13 → 12 research matrix and update evidence only from reproducible results.
4. Qualify the implemented `deterministic_reset`, application-root `accessibility_tree`, `companion_lifecycle`, and network-offline `fault_injection` companion operations on a running guest; source/runtime integration exists, but real-guest evidence is still required.
5. Populate Apple Developer credentials and update-signing keys, then publish the first Developer ID signed and notarized release.
6. Run the packaged macOS UI harness and qualify full guest element-level automation/replay after a stable real-VM fixture exists; the current guest provider exposes application-root fidelity only.
7. Research audio interruption/background-media and proxy/capture extensions without presenting unsupported simulation as available.
8. Exercise disaster-recovery staging on a second APFS volume and document operator recovery time.
9. Deploy the packaged mTLS/RBAC fleet coordinator and exercise all eight worker lifecycle operations plus signed audit verification across two enrolled Macs; import the resulting v1.1 evidence.
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
