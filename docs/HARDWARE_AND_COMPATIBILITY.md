# Hardware profiles and compatibility evidence

`Resources/hardware-profiles.json` is the virtual-device profile database. A profile records product type, SoC, CPU, RAM, default storage, display, GPU expectations, network modes, iOS range, validation status, and notes.

`Resources/compatibility-manifest.json` is the firmware evidence database. An entry may record:

- iOS version and build;
- compatible hardware profile IDs;
- required cloudOS version/build;
- boot status and validation hosts;
- known issues and required patches;
- app-deployment support;
- supported, experimental, researching, incompatible, or unverified status.

Import follows this pipeline:

```text
IPSW → filename/device/build detection → ZIP and BuildManifest validation → SHA-256
     → compatibility lookup → hardware recommendation → cloudOS pairing recommendation
     → allowed / warning-with-acknowledgement / blocked creation decision
```

Hardware profiles for iOS 12–15 are research hypotheses, not emulation claims. Their status changes only after the ordered acceptance evidence in `docs/research/` exists.
