# Changelog

## Unreleased

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
