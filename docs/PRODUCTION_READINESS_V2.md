# Production readiness v2

Version 0.7 turns the remaining production gaps into explicit, local workflows. The **Production Readiness** workspace is the control surface; none of its green states are a claim that an untested iOS/host combination works.

## 1. Real-VM qualification

A qualification campaign pins the Mac model/macOS/architecture, backend identity and version, selected VM, firmware SHA-256, hardware-profile ID, and all acceptance gates. It is blocked when any identity or real-VM evidence is missing. A passing campaign can be linked to a signed evidence seal.

## 2. Setup and safe repair

The first-run report separates actions the app can safely perform from owner-only host changes. **Repair Safe Items** creates lab, evidence, backup, resilience, and update directories. It never changes SIP, AMFI, Research Guests, Recovery policy, or installs privileged software.

## 3. Authenticated guest control

Guest protocol v3 uses a per-VM 256-bit HMAC key stored as `.vdl-host-control-key` with mode `0600`. Every request carries a timestamp, UUID nonce, key ID, and HMAC-SHA256 signature. The companion socket is mode `0600`, accepts a 30-second clock window, and rejects replayed nonces. Mutating host-control and guest-log export fail closed unless an authenticated v3 capability handshake succeeds.

The credential authenticates local host-control requests to the companion process. It is not an iOS user credential and does not create a network service.

## 4. Accessibility automation contract

The model includes versioned accessibility nodes and selector-based wait, tap, text, assertion, and screenshot steps. Execution stays gated until a backend truthfully advertises `accessibility_tree` over an authenticated compatible channel. The current vphone companion advertises this as unavailable, so the UI does not imply working element automation.

## 5. Evidence governance

Acceptance payloads are SHA-256 hashed and signed with a local Curve25519 key protected as mode `0600`. The ledger chains immutable seal material, permits later reviewer approval/rejection without invalidating the chain, and verifies the detached payload checksum. Keys and raw credentials are excluded from backups.

## 6. Backup and disaster recovery

Backups contain a payload plus a versioned manifest of relative paths, sizes, and SHA-256 values. Policy controls snapshots, test artifacts, and sanitized diagnostics. Agent tokens, evidence signing keys, update staging, and migration backups are excluded. Restore first verifies every recorded file and copies into **Restore Staging**; it never overwrites live state automatically.

## 7. Remote agent v2

The local file-queue agent now uses a versioned keyring, active key IDs, key rotation/revocation, nonces and a replay ledger, explicit cancelled state, expiry, cleanup, and health reporting. It still opens no listener. Queued jobs can be cancelled; a job already executing must finish or be stopped through the underlying workflow/host controls.

## 8. Updates and rollback

Production policy requires the packaged update public key, detached manifest signature, archive checksum, valid code signature, notarization, and migration preflight. Staging copies the current app to a rollback directory and emits user-launched install and rollback `.command` files. Downloading or staging never replaces the running app.

Ad-hoc development builds can disable notarization/signature requirements for local fixture testing, but that policy should not be used for production releases.

## 9. Supply chain

Packaging embeds a resource-hash manifest, CycloneDX SBOM, and SLSA-style source provenance. Release assets include those documents plus a detached provenance signature. CI also runs CodeQL, dependency review, secret scanning, package tests, bundle verification, and remote-agent v2 smoke tests.

The internal hash manifest covers static resources and `Info.plist`; Mach-O code integrity remains the responsibility of Apple code signing and notarization because signing changes executable bytes.

## 10. Resilience

The non-destructive resilience suite runs isolated fixtures for corrupted JSON, atomic state writes, a missing external volume, low-disk threshold ordering, interrupted journal recovery, bounded output floods, stale agent jobs, and update digest mismatch. Results are saved under `VirtualDeviceLab/Resilience Reports`.

## Remaining real-world gates

- Restart the required Apple-silicon host after owner-approved Recovery configuration.
- Import an owned supported IPSW and complete the first real baseline campaign.
- Record authenticated v3 screenshot/input/guest-file evidence against the updated companion.
- Implement and validate a real guest accessibility-tree provider before enabling element automation.
- Configure protected Developer ID, notarization, and update-signing secrets before the first production tag.
