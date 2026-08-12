# Release engineering

Every push and pull request runs the Swift tests, packages the application, verifies its ad-hoc signature, and checks required resources. A `v*` tag creates a GitHub Release containing the ZIP and SHA-256 file.

## Local ad-hoc release

```sh
./scripts/release_app.sh 0.7.0
```

## Developer ID release

Import a valid Developer ID Application certificate into the active keychain, then run:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
./scripts/release_app.sh 0.7.0
```

## Notarized release

Store credentials with `xcrun notarytool store-credentials`, then supply the keychain profile:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="ios-virtual-device-lab" \
./scripts/release_app.sh 0.7.0
```

The script submits the ZIP, waits for notarization, staples the ticket, rebuilds the ZIP, emits SHA-256, and verifies the final app. Apple credentials are intentionally not stored in the repository.

## Protected GitHub production secrets

Tagged releases intentionally fail closed unless these secrets are configured:

- `DEVELOPER_ID_APPLICATION_P12`, `DEVELOPER_ID_PASSWORD`, and `DEVELOPER_ID_APPLICATION_IDENTITY`;
- `BUILD_KEYCHAIN_PASSWORD`;
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`;
- `UPDATE_SIGNING_PRIVATE_KEY_BASE64` and matching `UPDATE_SIGNING_PUBLIC_KEY_BASE64`.

The public update key is embedded only in the production bundle. The release contains a signed `update-manifest.json`, its detached signature, the archive, SHA-256, CycloneDX `sbom.cdx.json`, `supply-chain-manifest.json`, and SLSA-style `build-provenance.json` with a detached signature. Do not reuse the update-signing private key for any other purpose.

The app verifies the signed update manifest and archive checksum before download is marked verified. Staging then checks code signing, Gatekeeper/notarization policy, and schema migration, preserves a rollback copy, and writes explicit user-launched install/rollback commands. Production policy fails closed when the embedded public key or signature assets are absent.
