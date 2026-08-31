# Credential rotation

Use this runbook for routine rotation, suspected exposure, or a change of operator ownership.

1. Inventory active remote-agent keys, mTLS identities, certificate pins, update-signing keys, and their consumers. Never export private key bytes into lab state or logs.
2. Generate the replacement in Keychain or the approved secret store. Validate identity label, certificate chain, expiration, and least-privilege access.
3. Add the new key or certificate during a bounded overlap window. Run an authenticated health probe and a dry-run job.
4. Activate the replacement, revoke the superseded credential, and verify that the old credential is rejected.
5. Record key IDs, certificate fingerprints, timestamps, approver, and verification results without secret material.

Emergency rule: suspected-compromised credentials skip the overlap window and are revoked before service restoration.
