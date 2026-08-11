# Roadmap

## Delivered in the MVP

| Plan stage | Current implementation |
|---|---|
| Backend baseline | `vphone-cli` adapter, host preflight, external storage, direct bundle discovery |
| SwiftUI shell | Native device library, detail view, lifecycle controls, status and settings |
| Firmware management | In-place IPSW catalog, metadata parsing, guided VM creation inputs |
| Snapshots | Named exports, restore-as-new-device, archive management, VM cloning |
| Developer workflow | Launch-and-install IPA/TIPA path, repeatable per-VM actions |
| Diagnostics | Persistent streaming activity console and actionable host preflight |
| Safety and integrity | Cancellation, timeouts, storage guards, firmware SHA-256, snapshot verification |
| Multi-version testing | Persistent multi-VM deployment runs, screenshots, and full baseline acceptance runner |
| Automation and extensions | Built-in workflows plus explicit executable plugin registry |
| Release engineering | CI, packaged artifacts, tagged releases, optional Developer ID/notarization tooling |
| Backend architecture | Typed replaceable engine requests, capability reporting, progress events, performance and diagnostic contracts |
| Hardware and compatibility | Versioned device profiles, automatic import recommendations, pairing enforcement, evidence database |
| Developer lab | App artifact library, configurable assertions/reports, workflow editor, Xcode helper |
| Lab controls | Network/audio/isolation policy, performance dashboard, guest crash/log export, snapshot retention |
| Extension security | Plugin API version, permissions, explicit trust, and checksum pinning |
| Firmware truth | BuildManifest parsing overrides misleading filenames and preserves build identities |
| Headless lab | `vdlctl`, resource admission, launchd schedules, and JSON/JUnit/HTML output |
| Diagnostic privacy | Sanitization, preview, encrypted export, local classification, opt-in analyzer extension |
| Production delivery | Developer ID/notary/update signing pipeline and verified update downloads |

## Next engineering milestones

1. Complete and publish the first real baseline acceptance result after the required host restart and supported IPSW import.
2. Validate guest diagnostic export against the companion vphone host-control build on a running guest.
3. Run the ordered iOS 15 → 14 → 13 → 12 research matrix and update evidence only from reproducible results.
4. Add a guest accessibility-tree API before claiming UI-element assertions; screenshot-diff and host/log/resource assertions are implemented.
5. Populate Apple Developer credentials and update-signing keys, then publish the first Developer ID signed and notarized release.
6. Expand full application UI automation after a stable real-VM fixture exists.
7. Research audio interruption/background-media and proxy/capture extensions without presenting unsupported simulation as available.

## Older-iOS compatibility research

Older releases are not represented as supported until they boot and complete a documented validation matrix. Research proceeds one release at a time:

1. iOS 15
2. iOS 14
3. iOS 13
4. iOS 12

For each release, record:

- compatible IPSW/device model and signing inputs;
- boot-chain and firmware-container differences;
- device-tree and virtual hardware expectations;
- kernel and driver compatibility gaps;
- restore, guest-agent, networking, graphics, and input behavior;
- app deployment and developer API limitations;
- reproducible failure logs and required patches.

An IPSW appearing in the firmware catalog is not a support claim. The UI should eventually distinguish `supported`, `experimental`, `researching`, and `incompatible` pairings based on a versioned compatibility manifest.
