# Changelog

## Unreleased

## 0.12.0

- Added a Production Depth workspace spanning all ten productionization tracks: guest companion lifecycle, signing/provisioning, physical-device lifecycle, visual/accessibility regression, real fault injection, mTLS fleet transport, SQLite event storage, exact-tuple upgrade certification, CI dependency lifecycle, and operator runbooks.
- Added a bounded guest package builder plus manifest, protocol-v3, backend allow-list, size, path, SHA-256, version activation, deployment, and rollback controls.
- Added Keychain-identity mTLS enrollment with platform trust, server-certificate pins, explicit rotation/revocation, health probes, bounded submissions, and request correlation.
- Added idempotent JSON-to-SQLite migration in WAL/FULL mode, ongoing dual writes, payload hashes, integrity checks, and backup checkpointing.
- Updated checkout to v6/Node 24, upload-artifact to v7/Node 24, and CodeQL Action to v4 at immutable commits, with a workflow-maintenance gate.
- Added ten focused production-depth tests, six bundled incident runbooks, `vdlctl depth status`, schema migration 8, and version 0.12.0 packaging.

## 0.8.0

- Added a fast, versioned companion contract and fail-closed host enforcement for backend 0.8, protocol v3, and credential-free VM exports.
- Added Keychain-backed per-VM guest-control credentials with explicit rotation/revocation and automatic regeneration after clone, import, snapshot restore, and full-lab restore.
- Expanded backup and disaster recovery to cover VM libraries, optional owned firmware, snapshots, state, incremental hard links, streaming chunk-authenticated encryption, capacity/conflict planning, isolated staging, explicit apply commands, and rollback directories.
- Linked evidence seals to an exact passing qualification campaign and required an identified sealing requester and reviewer.
- Added cross-process file locks, atomic owner-only state and remote-agent queues, concurrent worker claiming, and replay-ledger protection.
- Added launch/crash markers, main-thread hang reports, three-strike safe mode, and a UI surface for recovery status.
- Hardened updates with streamed downloads, archive traversal/symlink/expansion checks, historical migration fixtures, version-specific launch health checks, and automatic rollback.
- Added critical-action accessibility identifiers and keyboard shortcuts, localization resources, a 10,000-record load fixture, watchdog actor-isolation coverage, and expanded service/security coverage to 48 tests.
- Pinned every GitHub Action to a full commit SHA, added release artifact attestations, enabled the dependency graph and Dependabot security updates, and added security, support, firmware, and governance policy.

## 0.7.0

- Added a Production Readiness workspace covering ten final operational areas: pinned real-VM qualification, safe setup repair, guest trust, accessibility contracts, evidence review, backup/restore, remote agent v2, staged updates, supply chain, and resilience.
- Added authenticated guest-control protocol v3 with per-VM HMAC keys, owner-only socket/key permissions, timestamps, nonces, replay rejection, and fail-closed mutation/diagnostic gates.
- Added Curve25519-signed evidence payloads, immutable hash chaining, reviewer approval/rejection, and payload tamper detection.
- Added manifest/checksum lab backups with credential exclusions and verified restore staging that never overwrites live state.
- Upgraded the CLI queue to schema v2 with key IDs, rotation/revocation, nonce replay protection, explicit cancellation, cleanup, and health reporting.
- Added signed-update policy enforcement, code-sign/notarization/migration staging, rollback copies, and explicit installer/rollback command generation.
- Added embedded resource manifests, CycloneDX SBOM, SLSA-style provenance, CodeQL, dependency review, Dependabot, and secret scanning.
- Added eight non-destructive fault-injection scenarios and expanded the test suite from 32 to 40 tests.

## 0.6.0

- Added a first-class backend registry that distinguishes active adapters, planned adapters, research-only projects, and non-executable product benchmarks.
- Added per-backend capability/evidence records for boot, lifecycle, firmware, hardware, snapshots, graphics, audio, networking, deployment, debugging, automation, and older-iOS research.
- Added conservative firmware-specific backend recommendations that never promote QEMU research or Corellium references into runnable fallbacks.
- Added a machine-readable third-party provenance catalog covering sources, exact pins, license/terms, source-code use, modifications, distribution status, obligations, and review state.
- Added the Backends & Attribution SwiftUI workspace and backend recommendations in the firmware library.
- Reconciled project-comparison and attribution policy into the architecture, acceptance, limitations, roadmap, and third-party documentation.

## 0.5.0

- Added explicit real-VM acceptance definitions and evidence-gated release status.
- Added a versioned host/macOS/backend/iOS compatibility matrix and upgrade guard.
- Added idempotent state migrations, automatic pre-migration backups, rollback support, and a crash-recovery operation journal.
- Added reproducible environment profiles for locale, timezone, appearance, accessibility size, orientation, power/thermal/storage pressure, location, permissions, and network conditions.
- Added versioned guest-control negotiation with capability, authentication, transport, and message-size reporting.
- Added lab storage quotas, reserves, inventory, duplicate-IPSW detection, and configuration-only portable exports.
- Added firmware source, checksum, signing, ownership, and retention provenance.
- Added deny-by-default plugin write/network isolation, runtime/output limits, and persistent execution auditing.
- Added an authenticated HMAC-signed `vdlctl` queue for remote and CI job submission, execution, and status reporting.
- Kept startup storage discovery and plugin trust operations off the SwiftUI main actor, and bounded host probes so slow external volumes or helper commands cannot freeze the app window.

## 0.4.0

- Added binary/XML `BuildManifest.plist` parsing for authoritative IPSW version, build, product-type, board, chip, and build-identity metadata.
- Added the `vdlctl` headless runner, resource-aware multi-VM admission, launchd schedules, and JSON/JUnit/HTML reports.
- Added secure diagnostic sanitization, privacy previews, encrypted exports, deterministic crash/boot/panic/resource/network/audio classification, and opt-in trusted analyzer plugins.
- Added screenshot-content and baseline-diff assertions, expected-log/network/audio/CPU/memory assertions, and in-app resource policy controls.
- Added runtime vphone audio capability evidence and real process disk-I/O rates while keeping proxy, packet capture, GPU, FPS, and accessory simulation explicitly gated.
- Reworked the Xcode helper around stable `vdlctl deploy` exit codes and report artifacts.
- Added Developer ID certificate import, App Store Connect notarization, signed update manifests, verified update downloads, and tagged GitHub Release infrastructure.
- Added accessibility identifiers and labels for the main lab actions and diagnostic controls.

## 0.3.0

- Expanded `LabBackend` into a typed, replaceable engine contract with backend identity, structured progress, performance sampling, and guest-diagnostic export.
- Added versioned virtual hardware profiles covering device identity, SoC, memory, storage, display, GPU, networking, and supported iOS ranges.
- Added automatic firmware compatibility recommendations and enforced VM-creation gates for invalid, incompatible, mismatched, experimental, and unverified configurations.
- Added reusable app artifacts, configurable test assertions, per-assertion evidence, diagnostic artifacts, and Markdown/JSON test reports.
- Added an ordered automation editor with values, delays, retries, conditions, scheduling metadata, headless metadata, and more backend actions.
- Added network, audio, isolation, performance, diagnostic, snapshot-retention, and Xcode/developer-tool surfaces.
- Added plugin API versioning, permissions, explicit trust, and executable checksum pinning.
- Added vphone host-control guest file export support for bounded log and crash collection.
- Increased service and integration coverage from 11 to 18 tests.

- Added a formal backend protocol and mock backend.
- Added multi-device deployment runs and full baseline acceptance orchestration.
- Added compatibility manifests, IPSW validation, SHA-256, and research worksheets.
- Added screenshots, diagnostics, pause/resume, automation workflows, and executable plugins.
- Added process cancellation/timeouts, storage guards, snapshot checksums, and restore verification.
- Added CI, tagged release archives, and optional Developer ID/notarization tooling.

## 0.1.0

- Initial SwiftUI manager MVP using `vphone-cli` as an external backend.
