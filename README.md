# iOS Virtual Device Lab

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="180" alt="iOS Virtual Device Lab icon">
</p>

A native macOS SwiftUI laboratory for virtual iOS research and cross-version app testing. It uses [`vphone-cli`](https://github.com/Lakr233/vphone-cli) as the first replaceable backend behind a typed engine API.

## Implemented MVP

- Native VM library with live running/stopped state, iOS/build metadata, disk, memory, CPU, and networking details.
- Host preflight for Apple Silicon, nested virtualization, SIP, research-guest status, backend discovery, and actual binary launchability.
- Guided end-to-end VM creation with firmware variant, disk size, optional iPhone IPSW, and optional cloudOS IPSW.
- Boot, graceful stop, clone, delete, and hardware/network configuration.
- First-class “Launch & Install” for `.ipa` and `.tipa` packages using the backend guest control channel.
- IPSW catalog that indexes firmware in place instead of duplicating large files.
- Named compressed snapshots and restores using `vphone-cli vm export/import`.
- Persistent, filterable streaming command logs with copy/export support.
- External storage support through the existing `~/.vphone` layout.
- Versioned firmware compatibility evidence, IPSW structure checks, and SHA-256 fingerprints.
- Multi-device deployment runs with screenshots and persistent per-VM results.
- Full baseline acceptance runner covering clone, boot, guest control, stop, snapshot, verify, restore, and cleanup.
- Pause/resume, cancellable operations, timeouts, disk-space guards, and snapshot integrity checks.
- Built-in automation workflows, explicit executable plugins, and diagnostic bundles.
- Versioned iPhone hardware profiles with SoC, RAM, storage, display, GPU, network modes, and supported-iOS ranges.
- Automatic IPSW/device identification, compatibility recommendations, cloudOS pairing, and creation-time enforcement.
- Configurable test assertions, reusable IPA/TIPA artifacts, Markdown/JSON reports, and an ordered workflow editor.
- Networking, audio-test, isolation, performance-monitoring, guest crash/log export, and snapshot-retention controls.
- Xcode Run Script deployment helper plus trusted, checksum-pinned plugin permissions.
- BuildManifest-based IPSW inspection that treats archive metadata—not the filename—as authoritative.
- `vdlctl` headless workflows with resource budgets, launchd scheduling, and JSON/JUnit/HTML evidence.
- Sanitized and optionally encrypted diagnostic exports, deterministic crash classification, and opt-in trusted analyzer plugins.
- Real host-process disk-I/O telemetry, runtime audio capability evidence, richer visual/log/network/resource assertions, and explicit unsupported-feature reporting.
- Developer ID/notarization/update-signing release infrastructure with verified update downloads.
- Operational-readiness dashboard with explicit acceptance gates, host compatibility evidence, migration/rollback status, and interrupted-operation recovery.
- Reproducible environment profiles, versioned guest-protocol negotiation, storage lifecycle governance, and firmware provenance.
- Sandboxed/audited plugins plus an authenticated HMAC-signed `vdlctl` queue for remote and CI execution.
- A multi-backend registry, evidence-based firmware recommendation engine, and in-app capability matrix that keeps unimplemented research adapters non-selectable.
- A machine-readable third-party provenance catalog with exact pins, license/terms, source-use boundaries, modifications, obligations, and distribution status.

## Requirements

- Apple Silicon Mac running macOS 15 or later.
- Homebrew `vphone-cli` or a local signed build.
- The backend’s required Recovery-mode configuration.
- For the minimal host-policy option:

  1. In Recovery Terminal: `csrutil enable --without debug`
  2. In Recovery Terminal: `csrutil allow-research-guests enable`
  3. Back in macOS: `vphone-amfidont`

The lab remains usable as a read-only library and diagnostics viewer before preflight passes, but backend mutations and VM launch are intentionally blocked.

## Build and run

```sh
git clone https://github.com/elliot7williams/ios-virtual-device-lab.git
cd ios-virtual-device-lab
./scripts/build_app.sh
open ".build/iOS Virtual Device Lab.app"
```

For development:

```sh
swift build
swift test
swift run IOSVirtualDeviceLab
swift run vdlctl --help
```

Homebrew and `/Applications/vphone-cli.app` installations are discovered automatically. For a local backend build, set `VPHONE_CLI_BIN` to its executable and, if needed, `VPHONE_VPHONED_PATH` to `vphoned.signed` before launching the manager.

To regenerate the macOS `.icns` bundle from the checked-in 1024 px master:

```sh
./scripts/build_icon.sh
```

To create a versioned ZIP and checksum:

```sh
./scripts/release_app.sh 0.6.0
```

Developer ID signing and notarization are supported through `CODE_SIGN_IDENTITY` and `NOTARYTOOL_PROFILE`; see [Release engineering](docs/RELEASES.md).

## Storage

The default layout follows the backend:

```text
~/.vphone/
├── VMs/                  virtual-device bundles
├── ipsws/                downloaded/imported firmware cache
├── Snapshots/            compressed named restore points
└── VirtualDeviceLab/     profiles, app builds, test reports, diagnostics, plugins, and activity
```

To keep multi-gigabyte firmware and VM disks off the internal system volume, `~/.vphone` may be symlinked to a directory on an external APFS volume before creating devices.

## Safety behavior

- Snapshot creation and hardware edits require a stopped VM.
- VM and snapshot deletion require explicit confirmation.
- Forgetting an imported IPSW removes only its catalog record; it never deletes the source firmware.
- VM creation uses the backend’s native authentication dialog rather than storing a sudo password.
- The manager never weakens SIP/AMFI itself.

See [Architecture](docs/ARCHITECTURE.md), [Backend API](docs/BACKEND_API.md), [Operational readiness](docs/OPERATIONAL_READINESS.md), and [Roadmap](docs/ROADMAP.md) for design boundaries and the older-iOS research track.

Also read [Compatibility](docs/COMPATIBILITY.md), [Multi-backend and attribution](docs/MULTI_BACKEND_AND_ATTRIBUTION.md), [Limitations](docs/LIMITATIONS.md), [Remote agent](docs/REMOTE_AGENT.md), and [Plugin development](docs/PLUGINS.md). An entry marked `researching` or `unverified` is never a support claim.
