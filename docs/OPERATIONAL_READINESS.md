# Operational readiness

Version 0.5 turns the project plan's production-hardening items into persisted, inspectable contracts. The **Lab Operations** screen is the single overview for these systems.

## Acceptance definition

A release can build without a running research guest, but real-VM acceptance passes only when every gate has reproducible evidence:

1. host and backend preflight;
2. firmware BuildManifest and hardware-profile identity;
3. boot and compatible guest-control negotiation;
4. network behavior;
5. audio behavior;
6. application deployment;
7. snapshot, checksum, restore, and cleanup;
8. sanitized diagnostic export; and
9. a declared-duration stability run.

Unavailable capabilities remain blocked or pending. Stored configuration is never treated as proof that the guest reproduced a behavior.

## Host compatibility and upgrades

`Resources/host-compatibility.json` records evidence by macOS prefix, Mac model family, backend version family, and iOS major version. No matching record means **unverified**, not incompatible. Before updating macOS or the backend:

1. export a portable configuration;
2. preserve a verified VM snapshot;
3. check the proposed combination in the matrix;
4. rerun baseline acceptance after the update; and
5. add a validated record only from preserved evidence.

## Data migrations and recovery

`lab-schema.json` records the current data schema and migration history. Migration is idempotent. Before the first transition from an older schema, mutable JSON catalogs are copied to `Migration Backups/`; firmware, VM disks, credentials, and diagnostic content are not duplicated.

Long-running create, boot, clone, delete, snapshot, and restore operations write `operation-journal.json` before backend mutation. Entries still running when the next app session begins are marked **interrupted** with a conservative recovery instruction. Recovery never deletes VM data automatically.

## Environment profiles

Profiles express locale, timezone, appearance, Dynamic Type category, orientation, low-power intent, storage/thermal pressure, location, permission decisions, and network conditions. Assignments are persisted per VM.

The current vphone adapter does not claim most of these simulations. Unsupported settings are test intent until a trusted `environment-policy` extension or future backend declares and applies the capability.

## Guest protocol

The manager offers protocol versions 1 through 2 over the local Unix-domain host-control socket. The handshake records:

- negotiated version;
- capability names;
- maximum message size;
- authentication status; and
- transport.

Legacy v1 responses are accepted but labeled legacy. Unknown protocol versions are rejected. The current local socket reports authentication truthfully; filesystem ownership is not represented as cryptographic guest authentication.

## Storage and provenance

Storage inventory separates VM disks, firmware, snapshots, and lab state; enforces warning/critical free-space reserves; compares managed bytes to a quota; and detects duplicate IPSWs only when matching SHA-256 values exist. Detection never removes files automatically.

Portable export includes configuration catalogs only. Apple firmware, VM disks, application builds, diagnostics, passwords, signing identities, and remote-agent tokens are deliberately excluded.

Every imported firmware record carries source kind/description, importer, import time, checksum, BuildManifest signing-metadata status, ownership notice, and retention policy. This is provenance and integrity metadata—not permission to redistribute Apple software.

## Plugin security

Plugins still require an API version, declared capability, permission, explicit trust, and pinned executable checksum. Version 0.5 additionally applies:

- macOS sandbox execution by default;
- denied network access unless declared in the sandbox policy;
- writes limited to plugin output and temporary roots;
- bounded execution time and output size; and
- a persistent audit record for every executed capability.

Clicking **Run Plugin** is the per-run approval. Automated flows may invoke only a previously trusted plugin for the capability the user explicitly enabled.

## Remote/CI execution

The remote-agent foundation is an authenticated local file queue, not a network listener. See [Remote agent](REMOTE_AGENT.md). It is suitable for SSH-mediated or self-hosted-runner workflows where the queue and token remain on a physically controlled Mac.
