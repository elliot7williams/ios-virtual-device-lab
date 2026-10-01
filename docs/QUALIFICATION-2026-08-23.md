# Qualification record — 2026-08-23

## Result

The iOS Virtual Device Lab 0.8 manager is locally qualified to build, install, launch, preserve its code-signing seal, and reach its `ready` lifecycle phase on this host. VM boot qualification remains blocked and no iOS compatibility claim is made.

## Fixture

- Host: Apple silicon Mac14,3, arm64
- macOS: 15.7.9 (24G830)
- Manager: 0.8.0 (build 8)
- Companion contract: vphone-cli 0.8.0, schema 1, host-control protocol 3
- Companion revision: `48896066820a41ab2c9629be3137eb211fbe05b6`
- VM library: external volume through `~/.vphone`, 374,806,437,888 bytes available at final doctor run
- Firmware/VM fixture: unavailable; no owned IPSW or restored VM was present

## Passing evidence

- `swift test`: 48 tests passed, 0 failed.
- Production app and companion bundles built successfully from source.
- Both installed bundles passed `codesign --verify --deep --strict`.
- The manager remained running and wrote `lastPhase: ready`, version 0.8.0, with safe mode disabled.
- The manager bundle passed strict code-sign verification again after launch, proving bundled catalog reads did not mutate the signed resource seal.
- The installed companion's bundled contract declared credential-free exports and pinned the expected revision.

## Blocking evidence

- `csrutil allow-research-guests status` requires a Recovery selection because this Mac has multiple macOS installations. The VM executable is rejected before launch until the selected installation permits Research Guests.
- No Developer ID Application identity is installed, so a public notarized release cannot be produced on this host.
- No owned IPSW and no restored VM are available, so boot, guest control, app deployment, audio, networking, snapshot, performance, and matrix assertions remain unexecuted.
- The companion's full upstream test suite includes private firmware-comparison fixtures absent from the repository. The modified `BundleOpsTests` suite passed; fixture-dependent comparisons were not represented as passing.

The machine-readable doctor result is generated at `.dist/qualification-0.8/host-readiness.json` and is intentionally not treated as a passing real-VM campaign.
