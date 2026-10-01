# v1 completion contract

Version 0.13 adds a single fail-closed finish line over the lab’s existing engineering surfaces. The **v1 Completion** workspace and `vdlctl completion status` read `release-completion.json`; neither converts planned, mocked, stale, or self-declared behavior into release evidence.

## The ten gates

1. **Support contract** — pins product/minimum host/backend versions, arm64, host-control protocol v3, supported iOS major lines, exact hardware-profile IDs, and the six required workflows. Saving produces a candidate only when the schema validates. Approval is a named, timestamped human action and release authorization still requires every other gate.
2. **Guest companion** — source audit verifies concrete reset, accessibility, lifecycle, inject, clear, and status implementations plus their machine-readable backend declaration. A source pass is only `ready`; the running guest must independently negotiate `deterministic_reset`, `accessibility_tree`, `companion_lifecycle`, and `fault_injection` through authenticated, replay-protected protocol v3.
3. **First real VM** — consumes only the existing baseline acceptance report from a real supported IPSW/device/profile/backend tuple.
4. **Compatibility matrix** — every iOS major declared by the support contract must have an approved, evidence-sealed qualification row. The intended research order remains iOS 15, 14, 13, then 12.
5. **Desktop UI automation** — `vdl-ui-smoke` launches the packaged app against an isolated temporary state root in a logged-in macOS session, navigates the real sidebar with Accessibility, verifies critical identifiers, and writes importable schema-v1 JSON. Accessibility permission is required; a missing identifier, missing build revision, or version different from the support contract fails the release gate.
6. **Fault recovery** — cleanup sends `fault_clear`, immediately queries `fault_status`, and passes only when both commands are acknowledged, `active_faults` is empty, and the receipt names a matching successful injection scenario.
7. **Fleet authorization** — policy requires unique enabled subjects, exact 64-character client-certificate pins, and distinct operator/administrator identities. `vdl-fleetd` is a real mTLS coordinator with least-privilege roles, bounded HTTP, durable queue state, cancellation, and JSONL audit. Release evidence additionally requires a passing exercise across at least two distinct Macs.
8. **Reliability** — imported evidence must contain a 24-hour soak and recovered passes for host sleep/wake, restart, external-volume removal, low disk, guest/companion hang, network loss, and interrupted update.
9. **Coverage ratchet** — starts at the current 25% floor, advances only after measured coverage reaches the next floor and real UI evidence passes, and targets 75% for v1. Release evidence must bind coverage and UI results to the same source revision; the ratchet never lowers a floor.
10. **Release exit** — requires a signed/notarized staged update with migration preflight, every public-beta/accessibility/privacy/legal item, and a recorded restore drill on a second volume.

## Packaged tools

```sh
vdlctl completion status
vdl-ui-smoke --app "/Applications/iOS Virtual Device Lab.app" \
  --output "$PWD/ui-smoke.json"
vdl-fleetd --policy ./docs/examples/fleet-server-policy.json
```

`vdl-ui-smoke` must run as a process granted macOS Accessibility permission. `vdl-fleetd` expects its server identity in the Keychain and never stores private keys in its JSON policy.

## Guest implementation boundary

The current vphone companion implements non-system app-data reset, per-app TCC reset, application-scoped keychain reset, network reset, application-root accessibility metadata, checksum-pinned companion replacement, and timed network-offline injection with explicit clear/status. It advertises the accessibility fidelity and supported fault kinds. It does not claim element-level guest accessibility, latency/loss/proxy shaping, audio interruption, Face ID, cellular/baseband, Secure Enclave equivalence, App Store/iCloud, GPU telemetry, or FPS telemetry.

## Evidence that cannot be generated locally

The checked-in implementation can build and self-test without Apple firmware, signing credentials, or a second Mac. It cannot legitimately complete real-IPSW acceptance, the iOS 15→12 matrix, Developer ID/notarization, a 24-hour campaign, a second-volume restore, or a two-Mac exercise unless those resources are actually supplied. Those conditions remain visible as blocked or ready gates.
