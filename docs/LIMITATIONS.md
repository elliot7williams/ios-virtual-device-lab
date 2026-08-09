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

## Pause behavior

Pause uses `SIGSTOP`/`SIGCONT` on the VM processes holding the virtual disk. It freezes the process rather than creating a durable suspend image. Stop the VM before snapshots or host shutdown.

The backend resumes a paused VM before asking it to stop so the graceful-stop signal can be processed.

## Audio, network, and performance

Network proxy injection, packet capture, virtual audio input/output fidelity, accessory simulation, GPU utilization, guest FPS, and guest disk-throughput counters depend on engine support. The UI stores these policies and reports unavailable measurements explicitly; it does not claim unsupported simulation.
