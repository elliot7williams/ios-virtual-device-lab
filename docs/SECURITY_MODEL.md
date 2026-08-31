# VM security and isolation model

Default lab policy is deny-by-default for host integration:

```text
Virtual machine
├── Dedicated virtual disk
├── Explicit virtual network mode
├── No shared folder
├── Clipboard disabled
└── Host integration disabled
```

Network, clipboard, shared-folder, and host-integration access must be represented in VM metadata and shown to the user. An adapter must report when it cannot enforce a requested control.

Guest diagnostics use bounded file list/download operations over the existing vphoned connection. The manager restricts automatic collection to known log/crash roots, four directory levels, 200 files, approved diagnostic extensions, and 50 MB per file. It does not expose a guest command shell.

Plugins run out of process, never at startup, and require a supported API version, declared capability/permission, explicit trust, and a pinned SHA-256 executable digest. Any executable change revokes effective trust until reviewed again. Plugin execution defaults to a macOS sandbox with denied network access, writes limited to the output/temporary roots, bounded runtime and output, and a persistent audit record. A plugin that explicitly disables its sandbox is labeled unsandboxed in the audit trail.

The host-control socket and per-VM key are owner-only (`0600`). Protocol v3 requests use HMAC-SHA256, a 30-second timestamp window, UUID nonces, and replay rejection. Mutating input/screenshot and guest diagnostic export fail closed unless capability negotiation reports authenticated v3. This protects the local companion boundary; it is not guest user authentication.

Guest companion packages are copied only after safe-path, non-symlink, size, backend, protocol range, semantic version, and SHA-256 checks. Rollback re-verifies the installed payload. Fault injection and companion deployment require authenticated, replay-protected protocol v3 plus separate advertised capabilities; a stored policy is never treated as execution evidence.

Network fleet transport uses credential-free HTTPS URLs, Keychain-resident client identities, normal platform server trust, and an explicit SHA-256 leaf-certificate pin. Persisted state contains identity labels and public fingerprints only. Replacing an enrollment revokes its predecessor, explicit revocation removes the active configuration, and the client bounds request and response bodies to 1 MiB.

The SQLite event store uses owner-only files, WAL journaling, full synchronous writes, transactions, payload hashes, bounded queries, and `integrity_check`. Full-lab backup checkpoints WAL first; pre-migration backup also includes any outstanding WAL. Compatibility certificates fail closed unless an unexpired certificate matches the exact runtime tuple and derives from a passed qualification with an approved evidence seal.

The remote/CI foundation is a local file queue, not a network server. V2 job payloads are HMAC-SHA256 authenticated with key IDs and one-use nonces, expire, move atomically through queue states, and use a separate versioned keyring with mode `0600`. Portable exports, lab backups, and diagnostic bundles exclude that keyring. Anyone who holds an active key can authorize lab jobs, so the queue must remain on a physically controlled Mac and travel only through an existing authenticated channel.

Diagnostic bundles are sanitized into a new directory before the raw generated bundle is removed. Trusted analyzer plugins receive only the sanitized bundle path and run only after an explicit opt-in. AES-GCM encrypted exports require a user-supplied passphrase of at least 12 characters; the passphrase is not persisted.

The update client verifies the release archive SHA-256. Production policy requires an embedded RSA public key and matching detached signature over the update manifest. Staging verifies code signing, notarization policy, and migration before creating explicit install/rollback commands. GitHub Actions imports Developer ID, notarization, and update-signing credentials only from protected production secrets.

Acceptance evidence is stored separately from its payload, hashed with SHA-256, signed with a local Curve25519 key, chained over immutable seal fields, and reviewed through explicit approve/reject metadata. Lab backups exclude signing and agent credentials and restore only into a verified staging directory.
