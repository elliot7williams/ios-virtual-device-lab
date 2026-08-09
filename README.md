# iOS Virtual Device Lab

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="180" alt="iOS Virtual Device Lab icon">
</p>

A native macOS SwiftUI manager for virtual iOS research and developer testing. The MVP uses [`vphone-cli`](https://github.com/Lakr233/vphone-cli) as a replaceable process-level backend and leaves its upstream checkout unmodified.

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
```

Homebrew and `/Applications/vphone-cli.app` installations are discovered automatically. For a local backend build, set `VPHONE_CLI_BIN` to its executable and, if needed, `VPHONE_VPHONED_PATH` to `vphoned.signed` before launching the manager.

To regenerate the macOS `.icns` bundle from the checked-in 1024 px master:

```sh
./scripts/build_icon.sh
```

## Storage

The default layout follows the backend:

```text
~/.vphone/
├── VMs/                  virtual-device bundles
├── ipsws/                downloaded/imported firmware cache
├── Snapshots/            compressed named restore points
└── VirtualDeviceLab/     firmware index and activity history
```

To keep multi-gigabyte firmware and VM disks off the internal system volume, `~/.vphone` may be symlinked to a directory on an external APFS volume before creating devices.

## Safety behavior

- Snapshot creation and hardware edits require a stopped VM.
- VM and snapshot deletion require explicit confirmation.
- Forgetting an imported IPSW removes only its catalog record; it never deletes the source firmware.
- VM creation uses the backend’s native authentication dialog rather than storing a sudo password.
- The manager never weakens SIP/AMFI itself.

See [Architecture](docs/ARCHITECTURE.md) and [Roadmap](docs/ROADMAP.md) for design boundaries and the older-iOS research track.
