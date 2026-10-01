# v1.2 Lab Tools — 0.15.0

This milestone adds ten development and operations tracks. The desktop workspace is **v1.2 Lab Tools**. Core algorithms are shared by the manager, CLI, fixture server, and fleet coordinator through `VDLEvolutionCore`.

| Track | Working implementation | Qualification / remaining boundary |
|---|---|---|
| 1. Bootstrap rescue | Storage failure opens an interactive recovery screen; retry can run again after access returns; existing lab roots can be relinked; readable directory entries can be inspected | A macOS permission dialog still requires the user |
| 2. Host policy | SIP/Research Guests output, backend launch, CDHash, amfidont presence, and Gatekeeper checks; links to exact-volume Recovery flow and packaged helper | Host security changes remain user actions; multiple installations can prevent a noninteractive status query |
| 3. Upstream tracking | GitHub main-commit inspection, full installed/upstream revisions, dated result, comparison link | Updates are reviewed before adapter, firmware, and certification changes; merging upstream is not automatic |
| 4. Managed services | Packaged SMAppService LaunchAgents, per-user configuration import, start/restart/stop/unregister, Login Items approval/status | Real mTLS credentials, platform trust, and Apple service approval are required |
| 5. Version matrix | Executable probes for manager/backend/companion/server/worker/migration, explicit executable allowlist, exact-row digest, schema/protocol validation, optional downgrade probe | A version/help probe alone does not prove runtime guest interoperability; use meaningful component/conformance and migration probes |
| 6. Artifact registry | SHA-256 objects, deduplication, provenance note, quarantine, explicit approval, verification on export, resumable file transfer with prefix and final checksum checks | Multi-Mac transfer uses an explicitly supplied file/shared volume; no unauthenticated artifact HTTP service; directory bundles must be archived |
| 7. Network/time lab | Loopback HTTP and UDP DNS fixtures, deterministic connection loss, latency, response bandwidth, offline mode, recorded UTF-8 response replay, simulated-date header | Clients must opt into fixture endpoints and an injected clock; guest wall-clock control, transparent proxies, TLS-expiry simulation, and hypervisor packet loss are not qualified |
| 8. Suspend compatibility | Typed backend save/restore operations, payload checksum/size validation, exact host/backend/firmware/profile binding | Current vphone does not advertise qualified RAM-state save/restore; disk snapshots remain the available recovery mechanism |
| 9. Fleet production controls | Priorities, aging, subject fairness, host concurrency, subject queue quotas, capability matching, admin retry with exponential backoff, drain/maintenance policy, renewable leases, exclusive coordinator lock, verified backups/restores | Expired running jobs require operator reconciliation/fencing; automatic distributed failover and mid-job preemption are not implemented |
| 10. XCTest bridge | Runs named Xcode schemes/test plans across supplied destinations; copies original xcresult; extracts test cases and available attachments, diagnostics, and coverage; exports JUnit/HTML | Destinations must be recognized by Xcode. The current vphone VM is not an Xcode destination; VM test dispatch needs a qualified guest runner |

## Storage rescue

No lab directories are recreated through a broken external-volume link. Bootstrap failures clear the retry guard, pause device controls, and retain the configured root. Reconnect the volume or grant Files and Folders access, then choose **Retry Startup**. Choose **Existing Lab Directory** only when relocating a stopped lab to an existing dedicated directory. The recovery view reads directory entries without starting a VM.

State schema 11 adds `lab-evolution.json` and `network-fixture.json` to migration backup coverage. Artifact payloads live below `ArtifactRegistry`, outside the small control-state JSON file.

## Service setup

Import the appropriate `docs/examples/fleet-worker.json` or `fleet-server-policy.json` after replacing every template credential/pin/path. Configurations are copied privately to `~/Library/Application Support/iOS Virtual Device Lab/Services/`. The package contains `Contents/Library/LaunchAgents/dev.vdl.fleetd.plist` and `dev.vdl.fleetworker.plist`; both reference bundled executables via `BundleProgram`. Starting registers a user LaunchAgent, and stopping unregisters it. Use Login Items to approve or revoke background operation. No daemon is enabled just by opening the app.

## Artifact registry

```sh
vdlctl artifact import --file MyApp.ipa --kind ipa --source 'Owned build: revision abc123'
vdlctl artifact list
vdlctl artifact approve --sha256 FULL_SHA256
vdlctl artifact export --sha256 FULL_SHA256 --output /new/path/MyApp.ipa
vdlctl artifact resume --sha256 FULL_SHA256 --file /mounted/share/MyApp.ipa --partial /new/path/MyApp.partial
```

Only regular files are ingested. A modified object fails approval/export; an export never overwrites an existing file. Resuming verifies the already-copied prefix before copying the remainder and verifies the full digest afterward. The resumed file may then be imported on the destination Mac, where it is independently quarantined.

## Network fixtures

```sh
vdlctl fixture template --output scenario.json
vdl-fixture --scenario scenario.json
vdlctl fixture record --url https://your-test-origin.example/metadata --path /metadata --output recorded.json
```

See `docs/examples/network-fixture.json`. The TCP and UDP listeners bind to `127.0.0.1` only, defaulting to HTTP port 8787 and DNS port 53535. A DNS client must explicitly use that nonstandard test port. HTTP replay is an exact method/path lookup; no forwarding or host-wide proxy configuration occurs. Recording stores the response body and content type, so review it for application secrets before sharing. Repeated request identities use the same seeded drop decision. Date simulation is surfaced through `X-VDL-Simulated-Date`, for test applications that use an injected clock.

## Fleet policy and recovery

Place `scheduling-policy.json` in the coordinator state root before starting the service. Policy bounds concurrency, per-subject queue size, retry attempts, backoff, lease duration, and aging. Submission JSON can optionally add `priority` (-10…10) and `requiredCapabilities`. Older schema-v1 submissions remain readable; existing queued/running files receive scheduler records on startup.

The administrator mTLS routes are:

- `POST /v1/admin/maintenance`: `{ "hostID": "worker-subject", "draining": true }`, optionally `unavailableUntil` as an ISO-8601 date.
- `POST /v1/jobs/{uuid}/retry`: requeues a completed failed job within the bounded attempt limit and applies exponential backoff. Running or cancelled jobs are not blindly retried.
- `POST /v1/admin/backup`: writes a checksum manifest and recovery tree below the coordinator's sibling `FleetBackups` directory.

Offline operations:

```sh
vdlctl fleet-recovery backup --source /dedicated/fleet-state --output /new/backup --coordinator-fenced
vdlctl fleet-recovery restore --source /backup --output /new/fleet-state --coordinator-fenced
```

Stop/fence the old coordinator before offline backup or promotion, copy its retained audit verification certificate, and verify signed audit history. A local exclusive lock prevents two coordinator instances from running against one state root. Remote split-brain prevention requires operational fencing; the flag is an operator assertion, not a distributed consensus protocol. Running jobs and expired leases remain visible for explicit recovery decisions. Restore rejects traversal and corrupt files and requires an entirely new destination.

## Version matrix

Use `docs/examples/version-matrix.json` as a candidate specification. Replace every executable, version, and conformance expectation with the actual installed component. CLI callers explicitly authorize component paths:

```sh
vdlctl matrix --file version-matrix.json --allow-executable /absolute/component/path --output matrix-results.json
```

Repeat `--allow-executable` for each component. Desktop execution permits its packaged components, the discovered backend, and component executables explicitly selected for the current session. Matrix input does not authorize arbitrary shell scripts. The manager provides `--vdl-version`, `--vdl-companion-probe --backend-repo /repo` (source conformance only), and `--vdl-migration-probe --from-schema 10` (isolated real migration, idempotency, and managed-file rollback). A reported pass describes the probes actually run, not an unexercised downgrade, guest boot, or two-Mac campaign.

## XCTest

```sh
vdlctl xctest run --project /path/App.xcodeproj --scheme App --test-plan RadioTests --destination 'platform=iOS Simulator,id=UDID' --destination 'platform=iOS,id=DEVICE_UDID' --output /new/test-matrix
vdlctl xctest import --bundle /path/Results.xcresult --output /new/report
```

Xcode is invoked with argument arrays, not shell interpolation. Each destination produces its own result bundle and report. Import fails when no completed test cases are present. Optional artifact exporters can fail if the bundle contains no coverage/attachments/diagnostics; the report exposes availability separately. Failed and unknown test results fail the report. Existing result bundle paths are never overwritten.

## Verification

The core test suite covers artifact corruption/quarantine/deduplication and resumable prefixes, DNS parsing, scenario bounds/header injection, deterministic loss, scheduler admission/fairness/backoff, verified recovery and traversal rejection, exact saved-state binding, matrix allowlists/probes, xcresult parsing/escaping, and process deadlines. Desktop tests cover retry after a missing-volume reconnect and the unsupported backend saved-state contract. The real Accessibility harness visits the new workspace and requires `evolution.refresh`.
