# Compatibility policy

The compatibility manifest at `Resources/compatibility-manifest.json` is the machine-readable source of truth. A firmware file appearing in the library is not evidence that it boots.

## Status meanings

| Status | Meaning |
|---|---|
| `supported` | A concrete iOS build, device model, cloudOS pairing, and host family appear in upstream or project validation evidence. |
| `experimental` | It has boot evidence but is a beta, incomplete, or requires unstable patches. |
| `researching` | It is an active ordered research target with no support claim. |
| `incompatible` | A reproducible blocker has been documented. |
| `unverified` | No sufficiently specific evidence has been recorded. |

## Required acceptance evidence

A pairing moves to `supported` only after a recorded run passes:

1. host preflight;
2. VM clone or creation;
3. boot and guest-agent connection;
4. screenshot and hardware-key control;
5. optional IPA/TIPA deployment;
6. graceful stop;
7. snapshot export and SHA-256 verification;
8. restore as a new VM;
9. cleanup without damaging the source VM.

Record the host model/macOS version, iPhone IPSW version/build/device, cloudOS version/build, firmware variant, vphone-cli commit/version, result bundle, and known limitations.

## Older-iOS order

Research remains strictly ordered: iOS 15, then 14, 13, and 12. Worksheets live under `docs/research/`. Do not change a status merely because an IPSW parses or patches.
