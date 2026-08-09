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

echo "=== Signing app bundle ==="
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Built: $APP"
echo "Run:   open '$APP'"
