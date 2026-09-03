# Guest-control protocol

The manager and vphone companion negotiate a small versioned contract over the VM bundle's local Unix-domain socket.

## Request

```json
{
  "t": "capabilities",
  "protocol_min": 1,
  "protocol_max": 3,
  "screen": false
}
```

## Version 3 authentication

Protocol v3 adds a per-VM HMAC-SHA256 credential and replay protection. The request includes `auth_timestamp`, a UUID `auth_nonce`, `auth_key_id: "local-v1"`, and `auth_signature` over the sorted JSON request before the signature field is added. The key is stored beside the VM socket as `.vdl-host-control-key` with mode `0600`; the socket is also restricted to its owner.

The companion accepts a 30-second timestamp window and remembers accepted nonces for 120 seconds. Every command except capability negotiation rejects unauthenticated requests. The app also performs an authenticated v3 capability preflight before screenshot, input, or guest-diagnostic operations, so a legacy companion cannot accidentally receive mutations.

## Response fields

| Field | Meaning |
|---|---|
| `protocol_version` | Version selected by the backend |
| `capabilities` | Stable capability identifiers |
| `maximum_message_bytes` | Declared payload ceiling |
| `authenticated` | Whether the protocol itself authenticated the peer |
| `replay_protection` | Whether accepted nonces are rejected on reuse |
| `authentication_clock_skew_seconds` | Maximum accepted request timestamp window |
| `screenshots`, `hardware_keys`, `guest_files`, `audio_input`, `audio_output` | Boolean compatibility fields |
| `network_modes` | Actual modes supported by the runtime |

Known capability identifiers are `screenshots`, `hardware_keys`, `guest_files`, `audio_input`, `audio_output`, `network_modes`, `environment_policy`, `accessibility_tree`, `deterministic_reset`, `companion_lifecycle`, `fault_injection`, `fault_clear`, and `fault_status`. The host publishes the guest's raw capabilities separately and exposes a capability only while a connected guest advertises it.

Version 1 responses without `protocol_version` remain readable as legacy metadata. Version 2 remains negotiable for compatibility inspection, but its unauthenticated channel cannot pass mutation or acceptance policy. A response outside versions 1–3 is incompatible, and unavailable sockets never become passing acceptance evidence.

The transport is local, bounded, newline-delimited JSON. Authentication proves possession of the local per-VM host-control key; it does not authenticate an iOS account or expose a network endpoint. Companion installation uses `companion_install`; bounded faults use `fault_injection`, `fault_clear`, and `fault_status`. All mutations include their normal v3 authentication envelope and are sent only after the connected guest advertises the matching capability.

The current vphone guest reports `accessibility_fidelity: application-root` and `fault_kinds: [network-offline]`. It returns a structured frontmost-application root, not an element-level tree. Network-offline faults preserve original interface flags and restore them on explicit clear or timeout. Latency, loss, proxy, and audio faults fail as unsupported instead of producing false success.
