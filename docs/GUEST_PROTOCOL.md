# Guest-control protocol

The manager and vphone companion negotiate a small versioned contract over the VM bundle's local Unix-domain socket.

## Request

```json
{
  "t": "capabilities",
  "protocol_min": 1,
  "protocol_max": 2,
  "screen": false
}
```

## Version 2 response fields

| Field | Meaning |
|---|---|
| `protocol_version` | Version selected by the backend |
| `capabilities` | Stable capability identifiers |
| `maximum_message_bytes` | Declared payload ceiling |
| `authenticated` | Whether the protocol itself authenticated the peer |
| `screenshots`, `hardware_keys`, `guest_files`, `audio_input`, `audio_output` | Boolean compatibility fields |
| `network_modes` | Actual modes supported by the runtime |

Known capability identifiers are `screenshots`, `hardware_keys`, `guest_files`, `audio_input`, `audio_output`, `network_modes`, `environment_policy`, and `accessibility_tree`.

Version 1 responses without `protocol_version` remain readable as legacy responses. A response outside the supported range is incompatible, and unavailable sockets never become passing acceptance evidence.

The transport is local, bounded, newline-delimited JSON. The current host socket is not a cryptographically authenticated guest channel, so the response reports `authenticated: false`. Future authentication must include replay protection, key provisioning/rotation, and an explicit protocol-version transition.
