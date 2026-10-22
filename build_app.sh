#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

DIST_DIR="$DIR/dist"
APP_NAME="VideoAutoTranslate.app"
APP_DIR="$DIST_DIR/$APP_NAME"

echo "==> 1. 正在以 Release 模式编译 macOS 原生应用..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

echo "==> 2. 正在打包为原生应用至 dist 目录: $APP_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$DIR/.build/arm64-apple-macosx/release/VideoAutoTranslateApp" "$APP_DIR/Contents/MacOS/VideoAutoTranslateApp"
chmod +x "$APP_DIR/Contents/MacOS/VideoAutoTranslateApp"

# 复制 ASR 依赖脚本与资源
mkdir -p "$APP_DIR/Contents/Resources/scripts"
cp -r "$DIR/scripts/"* "$APP_DIR/Contents/Resources/scripts/"

echo "==> 2.1 正在打包内嵌独立 Portable Python 运行环境..."
"$DIR/scripts/prepare-embedded-runtime.sh" "$DIR/.build/embedded-runtime"
mkdir -p "$APP_DIR/Contents/Resources/runtime"
rsync -a "$DIR/.build/embedded-runtime/" "$APP_DIR/Contents/Resources/runtime/"
chmod -R u+w "$APP_DIR/Contents/Resources/runtime"
chmod +x "$APP_DIR/Contents/Resources/runtime/bin/"* 2>/dev/null || true

if [ -f "$DIR/assets/AppIcon.icns" ]; then
    cp "$DIR/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

BUNDLE_VERSION="${RELEASE_BUNDLE_VERSION:-1.0.0}"
BUILD_VERSION="${RELEASE_COMMIT_COUNT:-1}"

cat << EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VideoAutoTranslateApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.videoautotranslate.macos</string>
    <key>CFBundleName</key>
    <string>VideoAutoTranslate</string>
    <key>CFBundleDisplayName</key>
    <string>VideoAutoTranslate</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> 3. 对应用进行 Ad-hoc 签名..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> 4. 打包完成！应用位于: $APP_DIR"
echo "您可以直接运行: open \"$APP_DIR\""
