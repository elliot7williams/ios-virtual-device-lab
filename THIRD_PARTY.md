# Third-party software, research, and attribution

This file records external software and reference material used, adapted, evaluated, or materially considered by iOS Virtual Device Lab. Listing a project does not imply endorsement, partnership, compatibility, or permission to use proprietary code.

The machine-readable companion is `Resources/third-party-catalog.json`, which is rendered in the **Backends & Attribution** app workspace.

## Project policy

- Prefer an appropriately licensed dependency, then an adapter, then an independent implementation based on permitted documentation.
- Keep backend-specific code behind `LabBackend`; do not merge whole projects into SwiftUI.
- Never copy proprietary source, binaries, assets, or protected materials without authorization.
- Pin the exact version or commit before distributing a third-party component.
- Record source, license/terms, source-code use, modifications, redistribution, obligations, and transitive dependencies.
- Treat architecture and product research as reference material, not proof of implementation or compatibility.

## Current registry

| Component | Role | Status | License / terms | Version or pin | Distributed with app | Source-code use |
|---|---|---|---|---|---:|---|
| [vphone-cli](https://github.com/Lakr233/vphone-cli) | Primary external VM backend | Active adapter | MIT | Upstream `545fd35e0f36f1885d2c4990c2e44048daa24924`; companion `eb6aba798562dd475dd2b60448b3b1aeacd0b73b` | No | External executable; no source copied into manager |
| [Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization) | Platform virtualization API used by vphone | Indirect platform framework | Apple SDK/platform terms | Host macOS SDK | No | Platform API |
| [Swift](https://www.swift.org/) / SwiftUI | Language and native UI | Core platform/toolchain | Swift project licenses; Apple SDK terms for SwiftUI | Host Xcode/Swift toolchain | System/toolchain dependent | Standard language/framework use |
| vphone transitive dependencies | External backend dependencies | Behind backend boundary | Per component | vphone companion `Package.resolved` | No | None in manager |
| [QEMU](https://www.qemu.org/) | Alternative emulation/backend research | Unpinned research only | GPL-2.0 overall; individual components vary | None selected | No | Reference only |
| [Corellium](https://www.corellium.com/) | Commercial feature and UX benchmark | Reference only | Proprietary/commercial | Not applicable | No | None |

## vphone-cli modifications

The companion branch and [draft PR](https://github.com/elliot7williams/vphone-cli/pull/1):

- forward bounded guest directory listing and file download through the existing vphoned API;
- require absolute paths and enforce the advertised maximum file size;
- add versioned host-control protocol bounds, maximum payload, authentication status, and capability identifiers;
- explicitly report unsupported environment policy, accessibility-tree, proxy, and packet-capture behavior;
- do not add a general guest shell.

If vphone source, a binary, or substantial portions are redistributed later, preserve its MIT license and copyright notice and review every shipped transitive dependency. The current manager package does not include vphone, Apple firmware, firmware patches, or guest code.

## QEMU research boundary

QEMU is not currently a dependency or executable option. Its official documentation states that QEMU is GPL version 2 overall and that individual parts can carry specific licenses. Before a QEMU-based adapter is implemented or distributed:

- select and pin the exact upstream release/commit and any iOS research fork;
- identify every component used by the adapter;
- review source, linking, redistribution, notice, copyleft, patent, and transitive obligations;
- record modifications and current repository locations;
- obtain reproducible host and iOS boot evidence;
- keep the adapter disabled until the acceptance gate passes.

Generic QEMU emulation, snapshot, networking, or debugging features are not evidence that a particular iOS version or virtual iPhone profile works.

## Corellium reference boundary

Corellium is a commercial benchmark for device-management, snapshot, developer, diagnostics, and automation experiences. No Corellium source code, binary, service, API, account, screenshot, or asset is integrated. Features inspired by publicly described product concepts must be independently implemented or based on separately reviewed open-source components.

## Code provenance record

If code is copied, adapted, or substantially derived under a compatible license, add a record containing:

```text
Original project:
Original file/component:
Original version/commit:
Original author(s):
License:
Date incorporated:
Modification summary:
Current repository location:
Notices/attribution requirements:
```

No such copied/adapted third-party source is currently recorded in this manager repository.

## Integration checklist

Before incorporating or distributing a component, verify:

- [ ] Exact project, repository, version, and components are recorded.
- [ ] The governing license/terms and copyright owners are identified.
- [ ] Intended use and redistribution are permitted.
- [ ] Attribution, notice, source-offer, and copyleft requirements are satisfied.
- [ ] Patent and trademark provisions are reviewed where applicable.
- [ ] Transitive dependencies and bundled assets are reviewed.
- [ ] Local modifications and current file locations are documented.
- [ ] The machine-readable attribution catalog is updated.
- [ ] Backend capability claims have reproducible evidence.
- [ ] Removal or upgrade procedures are documented.

## Maintenance

Update this file and `Resources/third-party-catalog.json` whenever a dependency is added, removed, upgraded, redistributed, modified, or becomes a material research influence. The catalog is a provenance aid, not legal advice or a substitute for reviewing the exact terms that apply to a release.
