#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.4.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw "$ROOT/Info.plist")}"
DIST="$ROOT/.dist"
APP="$ROOT/.build/iOS Virtual Device Lab.app"
ARCHIVE="$DIST/iOS-Virtual-Device-Lab-$VERSION.zip"

rm -rf "$DIST"
mkdir -p "$DIST"

APP_VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
    "$ROOT/scripts/build_app.sh"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ -n "${NOTARYTOOL_PROFILE:-}" || -n "${NOTARY_KEY_PATH:-}" ]]; then
    if [[ "${CODE_SIGN_IDENTITY:--}" == "-" ]]; then
        echo "Notarization requires a Developer ID signed build" >&2
        exit 1
    fi
    if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    else
        : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
        : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"
        xcrun notarytool submit "$ARCHIVE" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi

shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

UPDATE_MANIFEST="$DIST/update-manifest.json"
plutil -create xml1 "$UPDATE_MANIFEST"
plutil -insert schemaVersion -integer 1 "$UPDATE_MANIFEST"
plutil -insert version -string "$VERSION" "$UPDATE_MANIFEST"
plutil -insert archive -string "$(basename "$ARCHIVE")" "$UPDATE_MANIFEST"
plutil -insert sha256 -string "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" "$UPDATE_MANIFEST"
plutil -insert releaseURL -string "https://github.com/elliot7williams/ios-virtual-device-lab/releases/tag/v$VERSION" "$UPDATE_MANIFEST"
plutil -convert json "$UPDATE_MANIFEST"

if [[ -n "${UPDATE_SIGNING_KEY:-}" ]]; then
    openssl dgst -sha256 -sign "$UPDATE_SIGNING_KEY" -out "$UPDATE_MANIFEST.sig" "$UPDATE_MANIFEST"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "Skipping Gatekeeper assessment for the ad-hoc local build"
fi

echo "Release archive: $ARCHIVE"
echo "Checksum:        $ARCHIVE.sha256"
echo "Update manifest: $UPDATE_MANIFEST"
