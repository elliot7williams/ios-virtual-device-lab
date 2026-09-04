# Compromised host isolation

1. Drain the host and block all new scheduler placement.
2. Cancel or expire active fleet and physical-device leases. Stop remote-agent processing.
3. Isolate network access while preserving volatile and monotonic timeline evidence where policy permits.
4. Revoke the host's mTLS identity, agent keys, pairing records, and any scoped signing access.
5. Identify every artifact, evidence seal, compatibility certificate, and test result produced during the exposure window. Mark affected claims unavailable pending review.
6. Rebuild from a trusted image, re-enroll with new credentials, recalibrate capacity, and requalify the exact runtime tuple before returning the host to service.

Exit criteria: the old identities fail authentication, no old lease remains active, evidence review is recorded, and a fresh qualification passes.
