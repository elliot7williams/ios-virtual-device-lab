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
  "description": "Exports additional guest diagnostics"
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
