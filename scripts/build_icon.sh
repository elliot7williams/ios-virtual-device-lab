#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MASTER="$ROOT/Assets/AppIcon-1024.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUTPUT="$ROOT/Assets/AppIcon.icns"

if [[ ! -f "$MASTER" ]]; then
    echo "Missing icon master: $MASTER" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render() {
    local size="$1"
    local filename="$2"
    sips -s format png -z "$size" "$size" "$MASTER" --out "$ICONSET/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Built: $OUTPUT"
