#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

if [ -z "${RELEASE_TAG:-}" ]; then
  eval "$("$DIR/scripts/release-metadata.sh")"
fi
: "${RELEASE_TAG:?RELEASE_TAG could not be determined}"

APP_PATH="$DIR/dist/VideoAutoTranslate.app"
RELEASE_DIR="$DIR/dist/release"

echo "==> 1. 验证应用代码签名..."
codesign --verify --deep --strict "$APP_PATH"

echo "==> 2. 准备发布目录: $RELEASE_DIR"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

DMG_NAME="VideoAutoTranslate_${RELEASE_TAG}_macOS_arm64.dmg"
ZIP_NAME="VideoAutoTranslate_${RELEASE_TAG}_macOS_arm64.zip"

echo "==> 3. 打包 ZIP 文件: $ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_DIR/$ZIP_NAME"

echo "==> 4. 打包 DMG 镜像: $DMG_NAME"
DMG_STAGE="$(mktemp -d "$DIR/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT

cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "VideoAutoTranslate" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$RELEASE_DIR/$DMG_NAME"

echo "==> 5. 生成校验和 (SHA256SUMS.txt)..."
cd "$RELEASE_DIR"
shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
cat SHA256SUMS.txt

echo "==> 打包完成！发布产物位于: $RELEASE_DIR"
