# Backend API contract

`LabBackend` is the only VM-engine interface used by `LabAppModel`. SwiftUI views do not import an engine SDK, invoke commands, inspect process arguments, or depend on vphone bundle syntax.

## Required surfaces

An adapter provides:

- a stable `BackendDescriptor` and `BackendCapabilities`;
- host preparation and readiness checks;
- VM discovery and lifecycle operations;
- typed `VMCreationRequest` and `VMConfigurationRequest` handling;
- firmware import, structure validation, and compatibility association;
- snapshot create, verify, restore, retention support, and deletion;
- app deployment, screenshots, hardware input, and cancellation;
- a versioned guest-protocol handshake with capabilities, payload limit, transport, and authentication status;
- diagnostic bundles, bounded guest diagnostic export, and performance samples;
- `LabProgressEvent` callbacks with operation, phase, fraction, and message.

Unsupported capabilities must be reported as unavailable and return an explanatory result. They must not silently ignore a request while claiming success.

Environment profiles are accepted as lab test intent. An adapter may apply only fields it can reproduce and must identify the rest as unsupported; saving a profile is not evidence that the guest changed.

## Engine adapter rule

Only an adapter translates a typed request to CLI arguments, SDK objects, sockets, or engine configuration files. Backend-specific progress text may supplement structured progress, but it is not the application state model.

The vphone adapter stores lab-only profile, network, audio, and isolation metadata in `lab-metadata.json` beside each VM. vphone-native `config.plist` and restore metadata remain owned by vphone.

## Combining projects

New engines should be added as separate adapters. Code from another project should not be pasted into SwiftUI or merged wholesale. Record its provenance, preserve its license boundary, implement this contract, and expose only capabilities that were validated.

The backend registry is descriptive, not executable. Adding an entry to `backend-catalog.json` does not register process launch code. A backend becomes selectable only after a concrete `LabBackend` implementation exists and its catalog record is marked `activeAdapter` and `selectable`. Reference-only entries are permanently excluded from recommendation candidates.
