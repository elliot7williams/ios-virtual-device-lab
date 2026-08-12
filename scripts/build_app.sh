#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/iOS Virtual Device Lab.app"
CONTENTS="$APP/Contents"
BUILD_TEMP="${VDL_BUILD_TMPDIR:-$ROOT/.tmp}"

mkdir -p "$BUILD_TEMP"
export TMPDIR="$BUILD_TEMP"

cd "$ROOT"
"$ROOT/scripts/build_icon.sh"

echo "=== Building iOS Virtual Device Lab ==="
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "=== Packaging app bundle ==="
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/IOSVirtualDeviceLab" "$CONTENTS/MacOS/IOSVirtualDeviceLab"
cp "$BIN_DIR/vdlctl" "$CONTENTS/MacOS/vdlctl"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Resources/compatibility-manifest.json" "$CONTENTS/Resources/compatibility-manifest.json"
cp "$ROOT/Resources/hardware-profiles.json" "$CONTENTS/Resources/hardware-profiles.json"
cp "$ROOT/Resources/host-compatibility.json" "$CONTENTS/Resources/host-compatibility.json"
cp "$ROOT/Resources/backend-catalog.json" "$CONTENTS/Resources/backend-catalog.json"
cp "$ROOT/Resources/third-party-catalog.json" "$CONTENTS/Resources/third-party-catalog.json"
if [[ -n "${UPDATE_PUBLIC_KEY_PATH:-}" ]]; then
    cp "$UPDATE_PUBLIC_KEY_PATH" "$CONTENTS/Resources/update-public-key.pem"
fi

if [[ -n "${APP_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
fi

PACKAGE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist")"
SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
swift "$ROOT/scripts/generate_supply_chain.swift" "$APP" "$PACKAGE_VERSION" "$SOURCE_REVISION"

echo "=== Signing app bundle ==="
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Built: $APP"
echo "Run:   open '$APP'"
