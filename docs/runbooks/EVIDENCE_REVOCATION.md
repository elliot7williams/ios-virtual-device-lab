# Evidence revocation

Use append-only review records; never delete or rewrite historical evidence to conceal a bad claim.

1. Identify the affected evidence seal and establish the reason, scope, and exposure window.
2. Enumerate dependent qualification rows, compatibility certificates, beta decisions, releases, and reports.
3. Add a reviewer rejection or revocation record to the ledger and verify that the hash chain still passes.
4. Make dependent compatibility and release decisions fail closed.
5. Re-run the applicable suite and create a new independently reviewed seal. Do not reuse the revoked seal or certificate.

Evidence: seal ID, dependency inventory, review decision, ledger verification, replacement campaign, and approval identity.
