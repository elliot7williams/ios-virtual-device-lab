# Continuity and Public Beta

Version 0.9 adds a dedicated operator workspace for the ten post-MVP hardening areas. None of these controls converts missing real-VM evidence into a pass.

## 1. External storage

The manager inspects the configured `~/.vphone` root before backend storage preparation. It records the resolved path, volume name and UUID, link state, writability, and last check in `~/Library/Application Support/iOS Virtual Device Lab/storage-location.json`. A missing external target gates bootstrap instead of silently creating an internal replacement.

Relink requires all devices to be stopped, an existing writable dedicated directory, and an existing symlink or absent root. The swap is atomic. A real `~/.vphone` directory is never replaced; that case requires a separately staged and verified migration.

## 2. Recovery Center

Interrupted and failed journal entries remain visible until the operator selects Resume/Retry, Roll Back, Keep for Review, or Abandon. Decisions are written to `recovery-decisions.json`. Resume and rollback preserve the original transaction and provide manual target-specific guidance; no incomplete VM, snapshot, or archive is deleted automatically.

## 3. Canonical fixture

A fixture can be recorded only when the selected device has a versioned hardware profile, matching structurally valid firmware with SHA-256, a verified snapshot checksum, and a passing acceptance report for that exact device. The manifest may also pin cloudOS, backend version, guest-protocol version, and smoke-app hash. It never contains firmware, disks, credentials, or signing identities.

## 4. Declarative Labfile

`Labfile.json` schema version 1 describes the backend and desired devices: profile, firmware hashes, CPU, memory, disk, networking, environment profile, and workflow names. The app exposes import/plan/apply and export. The CLI exposes:

```sh
vdlctl labfile plan --file Labfile.json
vdlctl labfile diff --file Labfile.json --json
vdlctl labfile apply --file Labfile.json
```

Plan and diff have no side effects. Apply validates names and resource floors, resolves only hash-pinned local firmware, creates missing devices, updates stopped devices, and never deletes extra devices.

## 5–7. Evidence, capacity, and security boundaries

Evidence freshness can require a maximum age, unchanged host/backend/firmware identity, and an approved signature seal. Host calibration measures CPU/RAM, available storage, and a small local write probe, then recommends a resource-admission policy; hosts below 16 GB default to one-VM low-memory mode. The hostile-input suite exercises JSON size/malformed input, archive traversal and absolute paths, valid bounded paths, and symlink detection in temporary storage.

## 8. Retention and privacy

Unified retention covers diagnostics, screenshots, test artifacts, and migration backups. Preview is non-destructive. Apply moves only previewed artifacts to `Recovery Bin`; firmware, VM disks, credentials, and signed evidence are excluded. Telemetry defaults off. APFS overwrite deletion is not represented as secure erasure; encrypted-export key destruction is the only cryptographic-erasure claim.

## 9. Operational objectives

The SLO report evaluates recent run success, P95 workflow duration, sustained soak duration, acceptance, resilience fixtures, and the second-volume recovery drill. RTO and RPO are explicit policy values. Missing measurements fail closed.

## 10. Public-beta readiness

VoiceOver, keyboard navigation, reduced motion, onboarding, support policy, Apple asset policy, legal-review reference, localization, and second-volume recovery are explicit gates. Human verification remains human. The generated support report excludes firmware, VM disks, screenshots, credentials, personal account data, and raw console logs.

## Remaining external qualification

The implementation does not remove the three external prerequisites: enable Research Guests for the correct macOS installation from Recovery, import firmware the operator is authorized to possess, and configure protected Developer ID/notarization/update-signing credentials before a public production release.
