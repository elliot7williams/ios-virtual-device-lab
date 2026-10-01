# Failed update rollback

1. Confirm the staged version's launch-health failure and stop further promotion.
2. Preserve launch forensics, the update archive hash, signature/notarization results, current schema marker, and migration backup.
3. Verify the rollback application signature and the migration or full-lab backup.
4. Execute only the generated rollback command after explicit operator approval.
5. Relaunch the prior version, verify schema compatibility and SQLite integrity, then run resilience and smoke checks.
6. Quarantine the failed update and revoke any release evidence that depended on the failing build.

Never downgrade live state by copying individual JSON or SQLite files by hand.
