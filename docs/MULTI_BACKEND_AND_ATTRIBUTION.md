# Multi-backend and attribution policy

## Current boundary

The lab combines project strengths through adapters and independent features, not by merging codebases. Version 0.6 records three distinct roles:

| Entry | Role | Runnable | Source-code use in manager |
|---|---|---:|---|
| vphone-cli | Primary VM/boot backend | Yes, when host preflight passes | None; external executable adapter |
| QEMU | Alternative emulation and older-iOS research candidate | No | None; unpinned research only |
| Corellium | Commercial feature and UX benchmark | Never | None; proprietary reference only |

`Resources/backend-catalog.json` is the capability/evidence database. `Resources/third-party-catalog.json` is the machine-readable attribution record. The **Backends & Attribution** screen presents both without turning catalog entries into dependencies.

## Recommendation rules

The recommendation engine combines firmware compatibility status, the active adapter, and host readiness:

- supported firmware may select the active vphone adapter when host preflight passes;
- experimental or unverified firmware is guarded and requires existing acknowledgement flows;
- researching older-iOS firmware reports that no validated backend exists;
- incompatible firmware is blocked;
- planned and research entries may be shown as candidates but are never launched;
- reference-only entries are excluded from candidates.

This is intentionally more conservative than selecting whichever backend has the most promising marketing or research description.

## Adapter promotion gate

Before a future backend can be selected, all of the following are required:

1. Pin the exact repository, version/commit, components, and build configuration.
2. Complete license, notice, redistribution, copyleft, patent, and transitive-dependency review.
3. Implement `LabBackend`; backend-specific syntax stays inside the adapter.
4. Add host discovery/readiness and safe operation cancellation.
5. Record capability evidence rather than inferred generic engine features.
6. Pass firmware-specific boot and acceptance tests.
7. Update both attribution catalogs and `THIRD_PARTY.md`.

## Provenance fields

Every third-party record includes source, license or terms, pinning status, integration state, source-code use, whether it is distributed, local modifications, obligations, and notes. A component must not be packaged if required fields or redistribution obligations are missing.

The catalogs do not grant permission, imply endorsement, establish compatibility, or replace review of the exact source and license files shipped with a future dependency.
