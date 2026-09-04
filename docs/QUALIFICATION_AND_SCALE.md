# Qualification and Scale

Version 0.11 turns the platform-engineering contracts into an evidence-producing execution layer. Its state is stored in `lab-expansion.json` under the lab state root and is covered by lab schema migration 7.

## 1. Capability maturity

Each major capability is evaluated as designed, implemented, integrated, real-VM qualified, or release ready. Levels are derived from current evidence; operators cannot manually promote a row. In particular, code and mocks can establish implementation or integration but never real-VM qualification.

## 2. Real-VM qualification

The matrix key is the exact iOS version, physical product type, versioned hardware profile, backend identity/version, campaign, and evidence seal. Only a passing campaign with an approved seal can be exported as approved compatibility evidence. Firmware catalog presence and a successful mock test are not support claims.

## 3. Runtime adapters

A runtime adapter must first pass protocol-v3 manifest conformance. Installation copies a regular, non-symlink executable into a versioned state directory, records its SHA-256, makes only one version active, and retains the prior version for rollback. Invocation sends one bounded JSON request over stdin, requires a matching request ID in the JSON response, uses the existing sandbox policy when available, caps time and output, and rejects an executable whose checksum changed.

## 4. Guest automation

Reset and accessibility actions are typed backend operations. Guest mutation requires authenticated and replay-protected protocol v3 plus the declared `deterministic_reset` or `accessibility_tree` capability. An older or unauthenticated guest fails closed. The current vphone companion must implement these host-control messages before the UI will report success.

## 5. Replay

Replay validates the manifest schema and identity, manifest hash, local stopped-device identities, one exact canonical fixture per device, environment references, application artifact checksum, and backend identity before creating a real test run. The resulting run ID and final state are persisted. Protected firmware, disks, credentials, and signing material remain excluded.

## 6. Symbolication

Crash symbolication extracts the crash UUID and instruction addresses, verifies that the dSYM contains the UUID with `dwarfdump`, requires the dSYM/UUID pair to exist in the indexed build catalog, invokes `atos` with bounded output, and records a stable fingerprint from the exception and top frames. A dSYM filename match is never sufficient.

## 7. Fleet control

Fleet scheduling now accounts for active reservations. Leases have bounded expiry and explicit release/expiry/cancel states; stale hosts are excluded after 90 seconds. Heartbeats, leases, and dispatch audit records are versioned. The existing HMAC queue remains the authenticated job transport. Cross-Mac network transport and mTLS are intentionally not marked qualified until exercised on two controlled hosts.

## 8. High-fidelity timelines

Timeline sessions contain a wall-clock/host-monotonic calibration sample and monotonic nanoseconds for every event. Each event identifies its source and artifact. Guest logs, video, audio, and network capture are listed as unavailable unless the active backend advertises them; the app does not synthesize missing streams.

## 9. Automated quality

The quality pipeline imports machine-readable LLVM or xccov JSON, verifies and records the report SHA-256, records an optional source revision, and feeds line coverage into the existing fuzz-and-coverage gate. Coverage remains failed closed without a report. CI runs Swift tests with coverage enabled, preserves the report as an artifact, guards the existing whole-project baseline from regression, and applies a higher floor to the new execution layer. The in-app release-quality policy remains stricter than the CI regression floor.

## 10. Hybrid virtual/physical lab

Physical targets are discovered through the supported `xcrun devicectl ... --json-output` interface. Routing requires explicit paired/developer-mode evidence, availability, requested iOS major, and every requested capability. Physical-only capabilities such as camera, cellular, biometrics, Secure Enclave, Bluetooth, and motion cause virtual targets to be rejected rather than simulated. An explicit operator action can install and launch a locally code-signature-verified expanded `.app` through CoreDevice; both outcomes are persisted.

## CLI

```sh
vdlctl expansion status --json
vdlctl targets list --json
vdlctl targets route --capability networking --capability audio
vdlctl targets route --capability camera --prefer-physical
```

## Qualification boundary

The software implementation can be tested without Apple firmware, a real VM, or a physical iPhone. Those tests prove deterministic policy and failure behavior only. The following evidence still requires the corresponding external environment:

- real-VM campaigns require the Recovery configuration, an owned supported IPSW, and the vphone companion;
- guest reset/accessibility requires companion guest support for the new protocol capabilities;
- remote fleet qualification requires a second authenticated Mac;
- physical deployment requires an authorized connected iPhone and a signed build;
- release-ready promotion requires signed/notarized release evidence and the project release policy.
