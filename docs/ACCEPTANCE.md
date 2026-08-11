# Baseline acceptance gate

A release may be built without a runnable research guest, but it may not claim real-VM acceptance until all of the following evidence exists:

1. `vdlctl doctor --json --output <evidence-directory>` reports the Apple-silicon host and backend ready.
2. A real supported IPSW is imported and its parsed BuildManifest identity matches the selected hardware profile.
3. Baseline acceptance completes clone, boot, guest control, screenshot, optional app deployment, graceful stop, snapshot, SHA-256 verification, restore, and cleanup.
4. The companion guest-file capability exports bounded logs/crashes from a running guest.
5. The report directory contains JSON/JUnit/HTML results, screenshots, diagnostic privacy preview, and analysis output.

An environment-blocked report is useful evidence but is not a pass. Host Recovery settings, missing IPSWs, unavailable Developer ID identities, unsupported guest capabilities, and insufficient storage remain explicit blockers rather than being mocked.
