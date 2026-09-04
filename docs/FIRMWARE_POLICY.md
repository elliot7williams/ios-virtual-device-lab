# Firmware and VM data policy

The project never downloads, bundles, publishes, or redistributes Apple firmware. Users import firmware they are authorized to possess. Firmware provenance records the local source, ownership assertion, size, SHA-256, BuildManifest identity, validation result, and retention state.

IPSWs, restored VM bundles, snapshots, guest data, credentials, and diagnostic archives must not be committed to Git or attached to public issues. Full-lab backups include firmware only when the user explicitly enables that option. Guest-control keys, evidence signing keys, agent tokens, update secrets, migration backups, and transient update payloads are always excluded.

Encrypted portable backups use a chunk-authenticated container and require a user-supplied passphrase. The passphrase is not stored by the app. Losing it makes the archive unrecoverable.

