# Lab recovery

Use this runbook when the lab state or an upgrade has become unusable. It never authorizes an unverified overwrite.

1. Stop new workflows, VM mutations, remote-agent workers, and fleet placement. Record the incident time and app/schema versions.
2. Select the newest migration or encrypted full-lab backup and run verification. Do not continue if a manifest, ciphertext, or payload hash fails.
3. Stage the restore outside live state. Review capacity, paths, provenance, and the generated apply command.
4. Preserve the damaged state for forensics. Apply the staged restore only with operator approval.
5. Launch the prior signed application, verify the state schema, run the resilience suite, and execute a non-destructive smoke workflow.

Evidence: incident record, backup verification, restore plan, staged manifest, apply approval, launch-health record, and smoke result.

Rollback: if verification after apply fails, stop the app, preserve the failed restore, and repeat with the prior verified backup.
