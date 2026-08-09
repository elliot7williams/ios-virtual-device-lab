# Third-party integration

| Component | Source | License | Version | Integration/modifications | Attribution |
|---|---|---|---|---|---|
| vphone-cli | Upstream: <https://github.com/Lakr233/vphone-cli>; companion patch: <https://github.com/elliot7williams/vphone-cli/pull/1> | MIT | Upstream `545fd35` + companion `9e28d44` | External signed executable, VM bundle formats, local host-control socket. Companion patch exposes bounded `guest_file_list` and `guest_file_get` by forwarding the existing vphoned file API. | Preserve upstream license and copyright notice. |
| Apple Virtualization.framework | Apple platform framework | Apple SDK terms | Host macOS SDK | Used by vphone-cli, not linked directly by this manager. | Follow Apple SDK and platform terms. |
| Swift Argument Parser and vphone transitive dependencies | See the vphone-cli dependency lock and repository | Per-component | Companion checkout | Remain behind the external backend boundary; no source copied into this repository. | Follow each upstream notice. |

The manager expects users to install or build the backend separately. Backend entitlements, firmware patching, guest code, firmware licensing, and transitive dependency obligations remain with the backend project. Any future engine adapter must add its source, license, pinned version, modifications, and attribution requirements to this table before distribution.
