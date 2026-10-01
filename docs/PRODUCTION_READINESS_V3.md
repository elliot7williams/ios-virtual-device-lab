# Production readiness v3 (0.8)

Version 0.8 closes the operational gaps that remained after the first Production Readiness workspace. These controls make failure visible and recoverable; they do not manufacture compatibility evidence.

## Companion boundary

The manager calls `vphone-cli --vdl-contract` with a five-second/output-bounded probe. A usable companion must declare contract schema 1, backend `vphone-cli`, backend version 0.8 or later, host-control protocol 3, and credential-free exports. The UI and `vdlctl doctor` fail closed when that contract is missing or incompatible.

## Credentials and state

Per-VM host-control secrets are stored as device-only macOS Keychain items and materialized as owner-only handoff files only where the companion protocol requires them. Clone/import/restore paths discard inherited secrets and rotate a new credential. Backups, VM exports, evidence signing keys, update keys, and remote-agent tokens are explicitly separated.

JSON state uses adjacent advisory locks, atomic writes, 0700 directories, and 0600 files. The remote-agent inbox atomically claims jobs under a queue lock and records replay nonces under a second lock, allowing multiple local workers without double execution.

## Full-lab recovery

A backup may include application state, the VM library, snapshots, test/diagnostic artifacts, and explicitly opted-in owned firmware. Incremental mode hard-links unchanged content when the destination volume supports it. Portable encryption uses independently authenticated chunks, never stores the passphrase, and can verify without loading a multi-gigabyte archive into memory.

Restore is three-step: verify and calculate space, inspect live-path conflicts, then stage. The generated apply command refuses to run while the app is active, moves every current destination to a timestamped rollback directory, restores each staged tree transactionally, removes any guest-secret handoff file, and requests fresh credentials on the next app launch.

## Evidence closure

Only a passing acceptance report with a matching passing qualification campaign can be sealed. Host fingerprint, backend, device, firmware/profile campaign, complete acceptance payload, and the sealing requester are cryptographically bound. Approval and rejection require a non-empty reviewer identity.

## Freeze and update recovery

Every launch has an owner-only phase marker. An incomplete prior marker increments the unclean-launch counter; three consecutive failures enter safe mode, which skips VM, firmware, plugin, remote-agent, and updater discovery. A background watchdog records a bounded hang report when the main-thread heartbeat stops.

Update archives download to disk, verify checksums/signatures, reject unsafe paths and escaping symlinks, enforce an expansion bound, validate code signing/notarization/migrations, and preserve rollback copies. The explicit installer waits for the new version to report a healthy launch and automatically restores the previous verified app on timeout.

## Qualification status

The 0.8 workflow has been environment-tested on the current Apple-silicon Mac, but no real-VM compatibility campaign can be completed because no owned IPSW or restored VM is present. The app records that state as blocked. A passing claim requires importing an owned IPSW, pairing its BuildManifest identity with a hardware profile, restoring/booting the VM, completing every baseline gate, and sealing/reviewing the exact campaign.

