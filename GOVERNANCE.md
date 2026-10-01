# Project governance

Maintainers review changes to backend contracts, destructive operations, credential handling, compatibility claims, update signing, and release workflows. Those changes require tests and an explicit security/rollback review in the pull request.

Releases require passing CI, CodeQL, dependency review, secret scanning, reproducible SBOM/provenance generation, Developer ID signing, notarization, signed update metadata, and GitHub artifact attestation. A real-VM compatibility claim additionally requires a passing qualification campaign linked to reviewed evidence.

GitHub Actions are pinned to full commit SHAs. Dependabot may propose updates, but maintainers must verify the action repository and release before accepting a new pin.

