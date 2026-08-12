# Authenticated remote and CI agent

`vdlctl` provides a file-queue agent foundation with HMAC-SHA256 job authentication. It never opens a listening port. Remote systems should invoke the commands through an existing authenticated channel such as SSH or a physically controlled self-hosted runner.

## Initialize

```sh
vdlctl agent-init
```

The default queue is `~/.vphone/VirtualDeviceLab/Remote Agent/Queue`. A v2 keyring containing an active key ID and a 256-bit key is written separately as `agent-token` with mode `0600`. Initialization refuses to overwrite an existing keyring; the CLI can still read a legacy raw token during migration.

The desktop app can initialize the same directories from **Lab Operations**. Initialization does not enable a daemon or accept jobs automatically.

## Submit a job

```sh
vdlctl agent-submit \
  --workflow boot-smoke \
  --device ios-15 \
  --device ios-18 \
  --app ./Music.ipa
```

The command creates a v2 payload containing a UUID, key ID, one-use nonce, creation/expiration time, workflow, devices, artifact path, dry-run flag, and resource policy. The canonical sorted JSON payload is signed with HMAC-SHA256 before entering `Inbox`.

## Execute one queued job

```sh
vdlctl agent-run-once
```

The runner atomically moves one envelope to `Running`, verifies its signature, key revocation, schema, nonce/replay ledger, expiry, cancellation marker, and device list, then uses the same resource-governed `HeadlessRunner` as local CLI execution. Invalid or expired jobs move to `Rejected`; completed receipts go to `Results`.

## Read status

```sh
vdlctl agent-status --job 24FB022F-2290-4796-A665-8EF32F837D01 --json
```

States are `queued`, `running`, `passed`, `failed`, `cancelled`, `rejected`, and `missing`.

## Operate the v2 queue

```sh
vdlctl agent-health --json
vdlctl agent-key-rotate --revoke-previous
vdlctl agent-cancel --job 24FB022F-2290-4796-A665-8EF32F837D01
vdlctl agent-cleanup --older-than-days 30
```

Cancellation removes queued work and leaves an auditable marker. It is checked again before execution, but it does not terminate a workflow that has already begun.

The **Production Readiness** workspace exposes the same health, rotation/revocation, queued-job cancellation, and 30-day cleanup operations without creating a daemon.

## Security boundaries

- Never commit, upload, print in CI logs, or include the token in an artifact.
- Give each controlled Mac its own keyring and use `agent-key-rotate`; revoke the old key after authorized submitters have received the new keyring.
- Do not place the queue on a broadly shared or cloud-synchronized folder.
- Do not expose the queue through an unauthenticated file server.
- Treat submitted app builds and workflows as code execution requests on the lab Mac.
- Use a dedicated macOS account and a physically controlled Apple-silicon host.

The queue authenticates job integrity and origin to holders of an active shared key. It does not provide multi-user authorization, non-repudiation, network transport security, mid-execution preemption, or isolation between mutually untrusted teams.
