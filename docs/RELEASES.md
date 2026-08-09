# Release engineering

Every push and pull request runs the Swift tests, packages the application, verifies its ad-hoc signature, and checks required resources. A `v*` tag creates a GitHub Release containing the ZIP and SHA-256 file.

## Local ad-hoc release

```sh
./scripts/release_app.sh 0.2.0
```

## Developer ID release

Import a valid Developer ID Application certificate into the active keychain, then run:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
./scripts/release_app.sh 0.2.0
```

## Notarized release

Store credentials with `xcrun notarytool store-credentials`, then supply the keychain profile:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="ios-virtual-device-lab" \
./scripts/release_app.sh 0.2.0
```

The script submits the ZIP, waits for notarization, staples the ticket, rebuilds the ZIP, emits SHA-256, and verifies the final app. Apple credentials are intentionally not stored in the repository.
