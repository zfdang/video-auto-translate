#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/video-auto-translate-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET_DIR="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/assets/app-icon.png" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$PROJECT_DIR/assets/app-icon.png" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$PROJECT_DIR/assets/AppIcon.icns"
echo "Created assets/AppIcon.icns"
