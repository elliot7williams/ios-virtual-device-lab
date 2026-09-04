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
cp "$BIN_DIR/vdl-ui-smoke" "$CONTENTS/MacOS/vdl-ui-smoke"
cp "$BIN_DIR/vdl-fleetd" "$CONTENTS/MacOS/vdl-fleetd"
cp "$BIN_DIR/vdl-fleetworker" "$CONTENTS/MacOS/vdl-fleetworker"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Resources/compatibility-manifest.json" "$CONTENTS/Resources/compatibility-manifest.json"
cp "$ROOT/Resources/hardware-profiles.json" "$CONTENTS/Resources/hardware-profiles.json"
cp "$ROOT/Resources/host-compatibility.json" "$CONTENTS/Resources/host-compatibility.json"
cp "$ROOT/Resources/backend-catalog.json" "$CONTENTS/Resources/backend-catalog.json"
cp "$ROOT/Resources/third-party-catalog.json" "$CONTENTS/Resources/third-party-catalog.json"
cp "$ROOT/Resources/supply-chain-policy.json" "$CONTENTS/Resources/supply-chain-policy.json"
cp "$ROOT/docs/examples/fleet-server-policy.json" "$CONTENTS/Resources/fleet-server-policy.example.json"
cp "$ROOT/docs/examples/fleet-worker-evidence.json" "$CONTENTS/Resources/fleet-worker-evidence.example.json"
cp "$ROOT/docs/examples/fleet-worker.json" "$CONTENTS/Resources/fleet-worker.example.json"
cp "$ROOT/docs/examples/supply-chain-evidence.json" "$CONTENTS/Resources/supply-chain-evidence.example.json"
mkdir -p "$CONTENTS/Resources/Runbooks"
cp "$ROOT"/docs/runbooks/*.md "$CONTENTS/Resources/Runbooks/"
for localization in "$ROOT"/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    cp -R "$localization" "$CONTENTS/Resources/"
done
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
swift "$ROOT/scripts/check_supply_chain_policy.swift" \
    "$CONTENTS/Resources/supply-chain-policy.json" \
    "$CONTENTS/Resources/sbom.cdx.json" \
    "$CONTENTS/Resources/build-provenance.json"

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
