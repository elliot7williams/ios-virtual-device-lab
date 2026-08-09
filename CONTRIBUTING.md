# Contributing

1. Build on Apple Silicon with macOS 15 or later.
2. Keep `vphone-cli` behind `LabBackend`; do not call its syntax from SwiftUI views.
3. Run `swift test` and `./scripts/build_app.sh` before submitting a change.
4. Do not mark a firmware pairing supported without the evidence defined in `docs/COMPATIBILITY.md`.
5. Do not commit IPSWs, VM archives, signing identities, Apple credentials, or diagnostic bundles containing private data.

Changes to destructive operations require confirmation UX and tests. Changes to the compatibility manifest should include the corresponding validation evidence in the pull request.
