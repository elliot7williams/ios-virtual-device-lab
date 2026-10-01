# Plugin development

Plugins are deliberately small executable integrations, not in-process dynamic libraries. This prevents third-party code from being loaded into the SwiftUI process.

Place a JSON descriptor in `~/.vphone/VirtualDeviceLab/Plugins/`:

```json
{
  "id": "com.example.lab-tools",
  "name": "Example Lab Tools",
  "version": "1.0.0",
  "executable": "/absolute/path/to/lab-tools",
  "capabilities": ["diagnostics"],
  "arguments": [],
  "description": "Exports additional guest diagnostics",
  "apiVersion": 1,
  "trusted": false,
  "permissions": ["diagnostics"],
  "sandbox": {
    "enabled": true,
    "allowNetwork": false,
    "allowDeviceRead": false,
    "allowTemporaryFiles": true,
    "timeoutSeconds": 120,
    "maximumOutputBytes": 5242880,
    "requirePerRunApproval": true
  }
}
```

When the user clicks Run, the manager invokes:

```text
<executable> <descriptor arguments...> <capability>
```

Context environment variables:

- `LAB_DATA_ROOT`
- `LAB_OUTPUT_ROOT`
- `LAB_DEVICE_NAME` when a VM is selected
- `LAB_DEVICE_BUNDLE` when a VM is selected

Plugins must declare a capability before it can be selected. They are never discovered outside the Plugins directory and never execute automatically at startup.

The Plugins screen must be used to grant trust. Trust records the executable SHA-256 in the descriptor and grants the declared permissions. If the executable changes, execution is refused until it is reviewed and trusted again. The current plugin API version is `1`.

The default sandbox denies network access and limits writes to the plugin output and temporary roots. Device-bundle reads and network access require explicit descriptor policy. Every executed capability records start/end time, device context, sandbox/network state, exit status, timeout, and output size in `plugin-audit.json`. Output beyond the declared limit is rejected even when the executable exits successfully.
