#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.2.0}"
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

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    if [[ "${CODE_SIGN_IDENTITY:--}" == "-" ]]; then
        echo "NOTARYTOOL_PROFILE requires a Developer ID signed build" >&2
        exit 1
    fi
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi

shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "Skipping Gatekeeper assessment for the ad-hoc local build"
fi

echo "Release archive: $ARCHIVE"
echo "Checksum:        $ARCHIVE.sha256"
