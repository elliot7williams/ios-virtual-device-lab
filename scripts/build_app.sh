#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/iOS Virtual Device Lab.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
"$ROOT/scripts/build_icon.sh"

echo "=== Building iOS Virtual Device Lab ==="
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "=== Packaging app bundle ==="
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/IOSVirtualDeviceLab" "$CONTENTS/MacOS/IOSVirtualDeviceLab"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Resources/compatibility-manifest.json" "$CONTENTS/Resources/compatibility-manifest.json"

if [[ -n "${APP_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
fi

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
