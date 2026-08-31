# Production depth

Version 0.12 turns the architecture promises into bounded, fail-closed operator controls. The Production Depth screen is the control surface; `vdlctl depth status` exposes the persisted summary for automation.

## Delivered controls

1. Guest companions are versioned packages with a schema-v1 manifest, protocol-v3 range, backend allow-list, safe relative payload, size bound, SHA-256 verification, activation history, and checksum-verified rollback. Deployment requires an authenticated, replay-protected guest that advertises `companion_lifecycle`.
2. Signing inspects identities, deep signatures, entitlements, decoded provisioning profiles, expiry, bundle identifiers, and team identifiers. Signing occurs only on a staged copy.
3. Physical devices expose pairing, Developer Mode, DDI service, battery, thermal, product, and OS checks through CoreDevice. Exclusive leases are bounded and fail on conflicting owners.
4. PNG regression compares canonical RGBA pixels with masks and thresholds and writes a diff. Accessibility comparison reports stable identifiers added, removed, or changed.
5. Network and audio faults use typed, bounded scenarios. The backend request is sent only after protocol-v3 authentication, replay protection, and `fault_injection` capability negotiation.
6. Fleet enrollment requires credential-free HTTPS, a Keychain client identity, and SHA-256 server-certificate pins. The transport presents the client certificate, verifies platform trust plus the pin, bounds payloads, and correlates request IDs.
7. High-volume activities, test runs, and leases migrate idempotently to SQLite in WAL mode with full sync, payload hashes, transactions, integrity checks, and continued JSON compatibility.
8. Runtime upgrades require an unexpired certificate for the exact host, macOS, backend, guest companion, adapter, and schema tuple. Certificates derive from passed campaigns and approved evidence seals.
9. CI rejects mutable action references and enforces checkout v6/Node 24 plus CodeQL Action v4. Every action remains pinned to a full commit SHA.
10. Six bundled runbooks cover lab recovery, credential rotation, compromised hosts, evidence revocation, failed updates, and lost devices. In-app drills validate prerequisites and documentation without performing destructive operations.

## Honest boundaries

These controls do not make unsupported Apple guests bootable. Guest deployment and fault injection require corresponding protocol-v3 support in the selected backend/guest. Physical workflows require a locally connected and authorized device. mTLS requires a user-provisioned Keychain identity and matching server. Compatibility certification describes tested tuples; it does not infer compatibility for untested combinations.
