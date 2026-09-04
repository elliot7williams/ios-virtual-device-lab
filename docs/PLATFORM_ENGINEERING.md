# Platform Engineering

Version 0.10 turns the manager’s ten newest plan items into persisted, operator-visible workflows. The state schema is version 1 inside `platform-engineering.json`; the overall lab migration schema is 6. The screen never converts an unavailable backend, guest, fleet, coverage, signing, notarization, or human-review requirement into a successful result.

## 1. Backend Adapter SDK and conformance

An adapter manifest declares a stable reverse-domain ID, semantic version, frontend protocol version, minimum lab version, capabilities, optional executable, and provenance/license reference. The conformance evaluator validates schema 1 and protocol 3, rejects duplicate or unknown capabilities, and probes a configured executable. “Manifest-only” validation does not assert runtime behavior.

Export the example SDK in the Platform Engineering screen, or check a manifest headlessly:

```sh
vdlctl adapter check --manifest docs/examples/adapter-manifest.json
vdlctl adapter check --manifest docs/examples/adapter-manifest.json --json
```

## 2. Deterministic reset

Reset planning pins the selected stopped device to a canonical fixture. The plan can include golden-snapshot restore, app reinstall, app-container/cache cleanup, privacy permissions, the app keychain namespace, networking, and environment settings. Every step maps to a declared backend capability. Current `vphone-cli` support can plan the sequence, but authenticated guest data/keychain reset remains blocked until the backend exposes `deterministicReset`.

## 3. Build, signing, and symbols

The catalog indexes imported app artifacts without changing them. It records the bundle ID, marketing/build versions, artifact hash, code-signing team and authority, entitlement digest, executable UUIDs, dSYM paths, and optional source revision. Missing signing or symbol data is a warning, never an invented identity.

## 4. Failure replay bundles

Only failed runs can produce replay bundles. A bundle contains a hash-pinned JSON manifest and replay command with the run identity, declarative Labfile, per-device environment assignments, canonical fixture IDs, and paths to already-created screenshots/diagnostics. Apple firmware, virtual disks, guest credentials, signing keys, secret values, and raw external files are excluded.

## 5. Flakiness and regression

Completed per-device results are grouped by test name and device. Reports calculate sample count, pass rate, consecutive failures, P50/P95 duration, flaky and quarantine status, and recent duration regression. Retry policy is persisted; retries are not silently applied to application failures.

## 6. Multi-Mac fleet placement

Fleet hosts advertise health, drain state, memory, concurrency, and capabilities. Placement filters all requirements and returns either one eligible host or a concrete no-placement blocker. Registering This Mac is functional locally. Cross-Mac execution still requires the separately authenticated remote-agent configuration; the scheduler never pretends it dispatched remote work.

## 7. Unified timelines

A timeline correlates run start/completion, assertions, bounded activity logs, screenshot/diagnostic references, and captured performance samples. Records are sorted by timestamp and persisted under `Unified Timelines`. Guest video is reported as unavailable until an adapter declares and implements `timelineVideo`.

## 8. Threat model and secrets inventory

The posture report documents frontend/filesystem, frontend/backend, host/guest, network, and fleet trust boundaries with threats, controls, evidence, and current state. The secret inventory contains purpose, storage class, rotation, revocation, export policy, and presence only. It never reads or serializes credential values.

## 9. Fuzzing and coverage gates

The local campaign uses a persisted seed and bounded case count to make archive-path and Labfile JSON inputs repeatable. It records behavior classes and invariant mismatches. Source coverage must be imported as measured evidence and meet the configured threshold; missing coverage fails closed even when fuzz invariants pass.

## 10. Beta operations and feedback

Channel policy covers internal, alpha, beta, and stable promotion; staged rollout percentage; healthy-run minimum; crash-like run rate; support response objective; HTTPS feedback endpoint; and optional sanitized diagnostic consent. Privacy-safe feedback packages contain readiness summaries only. Promotion requires every applicable gate and does not perform an update or bypass Developer ID, notarization, public-beta, or legal checks.

Inspect the persisted counters and gate summary in automation:

```sh
vdlctl platform status
vdlctl platform status --json
```

## Persistence and retention

The primary file is stored under `~/.vphone/VirtualDeviceLab/platform-engineering.json` with owner-only permissions and advisory locking. Generated replay bundles, timelines, adapter SDK exports, and feedback packages are bounded artifacts under the state root or an operator-selected export location. The existing backup and migration systems include the platform state file; protected guest and Apple assets remain outside these manifests.
