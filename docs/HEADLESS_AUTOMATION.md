# Headless automation and CI

`vdlctl` is packaged inside the application at `Contents/MacOS/vdlctl`. It can also be built directly with SwiftPM.

## Validate a workflow without running a VM

```sh
vdlctl run \
  --workflow boot-smoke \
  --device ci-placeholder \
  --dry-run \
  --output ./vdl-results
```

Every run writes `result.json`, `junit.xml`, and `report.html`. Exit status is zero only when all required steps pass.

## Run a resource-governed matrix

```sh
vdlctl run \
  --workflow ./workflow.json \
  --device ios-14 \
  --device ios-15 \
  --app ./Music.ipa \
  --max-concurrency 2 \
  --memory-budget-mb 12288 \
  --reserve-memory-mb 4096 \
  --max-cpu 85 \
  --output ./vdl-results
```

Admission is constrained by maximum concurrent VMs and aggregate VM memory. The runner also waits for normalized host CPU usage to fall below the configured ceiling. A request larger than the memory budget is serialized rather than deadlocked.

## Install an explicit schedule

```sh
vdlctl schedule-install \
  --workflow ./workflow.json \
  --device ios-15 \
  --interval-seconds 86400 \
  --app ./Music.ipa
```

This writes and bootstraps a per-user plist in `~/Library/LaunchAgents`. The desktop app never installs schedules silently.

## CI boundary

Public GitHub-hosted runners can build the app and dry-run workflow schemas, but they cannot enable Apple's research-guest policy or provide the required real VM fixture. Real VM execution therefore belongs on a physically controlled Apple-silicon self-hosted runner with no production Apple IDs or secrets inside guests.

For authenticated job submission to such a host, use the file-queue commands documented in [Remote agent](REMOTE_AGENT.md): `agent-init`, `agent-submit`, `agent-run-once`, and `agent-status`. The queue deliberately has no network listener.
