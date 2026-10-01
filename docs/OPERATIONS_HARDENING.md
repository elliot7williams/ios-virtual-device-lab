# v1.1 Operations & Hardening

Version 0.14 adds a separate, fail-closed operations layer. It does not weaken or reinterpret the ten v1 completion gates in `V1_COMPLETION.md`. The desktop screen, persisted state, exported report, and `vdlctl operations status` all expose the same ten controls.

## 1. Guided host setup and restart continuation

The app discovers APFS volumes with the `System` role and requires the operator to choose an exact volume UUID. It records the current boot-session identifier, displays the required Recovery commands alongside that volume identity, and persists the phase across app and host restarts. It advances from Recovery acknowledgement to post-restart verification only after a new boot session is observed. The app never runs `csrutil`, enters Recovery, or silently changes SIP policy.

This matters on Macs with multiple macOS installations: a volume name alone is not treated as identity, and the selected UUID remains in the continuation record.

## 2. Permission onboarding

The inspector reports removable-volume read/write access, Accessibility trust, Keychain availability, and Local Network readiness when fleet mode is enabled. Every row includes its purpose and, where macOS supports it, a System Settings deep link. Permission denial remains a visible blocker; no prompt is automated or bypassed.

## 3. Fleet worker protocol

`vdl-fleetd` 1.1 implements the following mTLS endpoints:

| Method | Path | Operation |
|---|---|---|
| `GET` | `/v1/health` | Service and protocol discovery |
| `POST` | `/v1/hosts/enroll` | Policy-authorized certificate self-enrollment |
| `POST` | `/v1/hosts/heartbeat` | Capacity, active-job, and cancellation exchange |
| `POST` | `/v1/jobs` | Idempotent submission using the request UUID as job UUID |
| `POST` | `/v1/jobs/{id}/claim` | Exclusive worker claim |
| `POST` | `/v1/jobs/next/claim` | Atomically claim the oldest queued job |
| `POST` | `/v1/jobs/{id}/progress` | Monotonic progress and cancellation response |
| `POST` | `/v1/jobs/{id}/result` | Bounded, idempotent result commit |
| `GET` | `/v1/jobs/{id}` | Durable status query |
| `POST` | `/v1/jobs/{id}/cancel` | Queued cancellation or running cancellation request |

Every request remains capped at 1 MiB. Timestamps have a bounded clock window; host IDs in bodies must equal the authenticated principal; job IDs are UUIDs; messages and arrays have explicit limits. Run `vdl-fleetd --protocol-json` to obtain the machine-readable contract.

The packaged `vdl-fleetworker` is the other half of the protocol. It loads a bounded configuration, authenticates with a Keychain client identity, applies platform trust plus an exact server-certificate pin, self-enrolls only when that certificate subject is already enabled by server policy, heartbeats, atomically claims work, invokes the packaged `vdlctl`, reports monotonic progress, honors cancellation, and uploads a checksum-pinned result. Start one cycle or a persistent worker with:

```sh
vdl-fleetworker --config fleet-worker.json --once
vdl-fleetworker --config fleet-worker.json --daemon
```

Use `docs/examples/fleet-worker.json` as a fail-closed template. Install the daemon under a dedicated unprivileged macOS account for a production fleet.

The v1.1 gate also requires current two-host evidence containing all eight lifecycle capabilities, mTLS, idempotency, cancellation, and payload-boundary checks. The template in `docs/examples/fleet-worker-evidence.json` intentionally fails until replaced with real results.

## 4. Tamper-evident audit ledger

Each fleet authorization decision is encoded canonically, linked to the prior SHA-256, assigned a monotonic sequence, and signed using the configured Keychain server identity. The envelope records the signing certificate fingerprint. The desktop verifier recomputes the complete chain and verifies every signature against an imported DER certificate. Missing, reordered, edited, truncated-to-empty, or unsigned evidence fails the gate.

Protect and retain the corresponding certificate and `audit.jsonl`. Rotating the server identity starts a new trust period and requires separately retained verification material.

## 5. Transitive evidence invalidation

The dependency snapshot pins the manager, backend, guest companion, compatibility manifest, hardware profiles, supply-chain manifest, and host/state policy. A change recursively invalidates dependent acceptance, qualification, automation, performance, and release decisions. Evidence is never deleted automatically. It remains stale until replacement evidence is produced and the operator explicitly advances the baseline.

## 6. Live-storage encryption

The mounted data root is inspected with `diskutil info -plist`. The gate passes only when a recognized APFS/FileVault encryption field is true and the volume is writable. Unknown metadata fails closed. Backup encryption does not substitute for encryption of live VM disks, firmware, logs, snapshots, and state.

## 7. Startup reconciliation

Startup checks interrupted operation-journal entries, unapproved staged updates, expired fleet leases, expired physical-device leases, injected guest faults without verified cleanup, and stale local sockets. Destructive or guest-affecting recovery always remains explicit. Only findings classified as safe—currently stale local socket cleanup—are eligible for the repair button.

## 8. Atomic component upgrades

A component-set transaction stages regular, non-symlinked manager/backend/guest artifacts in a private directory, records exact sizes and SHA-256 values, and requires protocol/state-schema compatibility. Approval and commit are separate actions. Commit re-verifies every staged byte and activates the set by one atomic manifest replacement after all health checks pass. The prior activation manifest is copied to the transaction rollback directory.

The activation manifest is the consistency boundary: consumers must use one declared set, not independently select whatever manager, backend, or companion happens to be newest.

## 9. Supply-chain policy

`Resources/supply-chain-policy.json` defines the license allowlist/denylist, vulnerability threshold, SBOM requirement, provenance requirement, and unknown-license behavior. Imported evidence is bounded and hashed. A component outside the license policy, above the severity threshold, without a license, or without verified source provenance blocks the gate.

`docs/examples/supply-chain-evidence.json` documents the normalized input. CI and release tooling should generate it from a real SBOM and vulnerability scanner; changing `provenanceVerified` by hand is not qualification evidence.

## 10. Support and deprecation lifecycle

The lifecycle catalog covers manager release lines, guest protocol versions, and state schemas. Deprecated entries require dated notice, an end-of-life date at least 90 days later by default, and a migration target. End-of-life entries require an effective date and migration target. This makes compatibility removal a reviewable product decision rather than an accidental consequence of an update.

## Persisted state and recovery

The operations state is stored as `operations-hardening.json` under the lab state root using the existing advisory lock, atomic replacement, and owner-only protection. Schema migration 10 includes this file and the active component manifest in rollback backups. Reports may be exported from the desktop screen or inspected headlessly:

```sh
vdlctl operations status
vdlctl operations status --json
```

The command reports `READY` only when all ten gates pass. External evidence—Recovery/restart, permissions, a real two-Mac fleet exercise, an actual SBOM/vulnerability scan, and encrypted storage—cannot be truthfully manufactured by the app and remains visible as required operator work.
