# Security and platform limitations

## Host security configuration

`vphone-cli` requires Apple research-guest/debug allowances that cannot be enabled by this application. The minimal documented Recovery configuration weakens part of System Integrity Protection's debug restrictions. Understand the impact, keep the Mac physically controlled, and restore full SIP if the research environment is no longer needed.

The manager never runs `csrutil`, stores an administrator password, or silently changes host security policy.

## Virtual hardware

A virtual device is not equivalent to a physical iPhone. Secure Enclave behavior, cellular/baseband, Face ID, cameras, motion sensors, Bluetooth accessories, USB accessories, and hardware-backed keys may be absent or incomplete.

## Apple services

App Store, iCloud, activation, DRM-protected media, push notification registration, device registration, and regional services may fail or behave differently. Never use production Apple IDs or production secrets in an experimental VM.

## Diagnostics

The lab's [companion vphone patch](https://github.com/elliot7williams/vphone-cli/pull/1) adds bounded guest file listing/download to the host-control socket and can collect existing log/crash files from known roots. It does not provide an unrestricted guest shell or a live unified-log stream. An older installed `vphone-cli` will reject these commands; install the companion build or use a trusted diagnostics plugin.

Guest files that were never persisted, are protected from vphoned, or disappeared during a crash cannot be recovered by the manager.

Standard diagnostic bundles are sanitized before presentation. Secret-like values, home paths, email addresses, and IP addresses are redacted according to the persisted privacy policy; large files and host profiles can be excluded. Redaction is best-effort and cannot guarantee that every project-specific secret format is recognized. Inspect the privacy preview before sharing a bundle.

## Pause behavior

Pause uses `SIGSTOP`/`SIGCONT` on the VM processes holding the virtual disk. It freezes the process rather than creating a durable suspend image. Stop the VM before snapshots or host shutdown.

The backend resumes a paused VM before asking it to stop so the graceful-stop signal can be processed.

## Audio, network, and performance

The current vphone engine provisions real Virtio host audio input and output. Its host-control capability response lets the manager distinguish a running audio-backed VM from a stored policy. Interruption behavior, Bluetooth/headphone simulation, and exact guest routing fidelity remain unavailable.

CPU, resident memory, and process disk-I/O rates are measured from the real host VM processes. Virtualization.framework does not expose guest GPU utilization or rendered FPS, so those remain unavailable.

NAT, bridged, and no-network modes are engine-backed. Proxy injection and packet capture require a separately trusted `network-policy` plugin; the app never claims that merely saving those fields changes guest traffic.

Headless execution means unattended orchestration and reporting. vphone still creates the engine's required macOS VM process/window; this is not a display-less Virtualization.framework backend.

## Backend catalog

Version 0.6 has one runnable adapter: vphone-cli. The QEMU entry is a planned research candidate with no integrated executable, iOS boot evidence, or automatic fallback. The Corellium entry is a reference-only product benchmark; no proprietary code, binary, API, account, or service is incorporated. Capability labels describe recorded evidence and must not be interpreted as equivalence between these projects.
