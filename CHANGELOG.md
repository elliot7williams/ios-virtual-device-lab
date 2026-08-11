# Changelog

## Unreleased

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
