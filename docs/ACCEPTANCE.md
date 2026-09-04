# Baseline acceptance gate

A release may be built without a runnable research guest, but it may not claim real-VM acceptance until all of the following evidence exists:

1. `vdlctl doctor --json --output <evidence-directory>` reports the Apple-silicon host and backend ready.
2. A real supported IPSW is imported and its parsed BuildManifest identity matches the selected hardware profile.
3. Baseline acceptance completes clone, boot, versioned guest-control negotiation, screenshot, optional app deployment, graceful stop, snapshot, SHA-256 verification, restore, and cleanup.
4. The companion guest-file capability exports bounded logs/crashes from a running guest.
5. The report directory contains JSON/JUnit/HTML results, screenshots, diagnostic privacy preview, and analysis output.

An environment-blocked report is useful evidence but is not a pass. Host Recovery settings, missing IPSWs, unavailable Developer ID identities, unsupported guest capabilities, and insufficient storage remain explicit blockers rather than being mocked.

The **Lab Operations** dashboard expands this into explicit host, firmware identity, boot/control, networking, audio, deployment, snapshot/restore, diagnostics, and sustained-stability gates. Every gate remains pending or blocked until its required evidence exists.

A new backend cannot be promoted from `plannedAdapter` or `researchOnly` to selectable until its exact implementation is pinned, licensing obligations are reviewed, host readiness is implemented, capability claims have evidence, and at least one firmware-specific acceptance run passes. A commercial reference platform is never eligible for promotion without a separately authorized integration.

The baseline result feeds gate 3 of the [v1 completion contract](V1_COMPLETION.md). It does not by itself approve an iOS support range: every declared major version also needs an exact approved qualification row, and the remaining desktop, recovery, fleet, reliability, coverage, signing, accessibility, privacy, legal, and restore gates must pass independently.
