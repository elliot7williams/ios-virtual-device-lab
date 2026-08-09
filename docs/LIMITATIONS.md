# Security and platform limitations

## Host security configuration

`vphone-cli` requires Apple research-guest/debug allowances that cannot be enabled by this application. The minimal documented Recovery configuration weakens part of System Integrity Protection's debug restrictions. Understand the impact, keep the Mac physically controlled, and restore full SIP if the research environment is no longer needed.

The manager never runs `csrutil`, stores an administrator password, or silently changes host security policy.

## Virtual hardware

A virtual device is not equivalent to a physical iPhone. Secure Enclave behavior, cellular/baseband, Face ID, cameras, motion sensors, Bluetooth accessories, USB accessories, and hardware-backed keys may be absent or incomplete.

## Apple services

App Store, iCloud, activation, DRM-protected media, push notification registration, device registration, and regional services may fail or behave differently. Never use production Apple IDs or production secrets in an experimental VM.

## Diagnostics

The current upstream host socket exposes screenshots and input automation, but not direct guest syslog/crash export. Diagnostic bundles include manager/backend output, host logs, metadata, screenshots, and guest artifacts already present in the bundle. A plugin or upstream capability is required for broader guest-log collection.

## Pause behavior

Pause uses `SIGSTOP`/`SIGCONT` on the VM processes holding the virtual disk. It freezes the process rather than creating a durable suspend image. Stop the VM before snapshots or host shutdown.
