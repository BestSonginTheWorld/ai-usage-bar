#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="AIUsageMenuBar"
PRODUCT_NAME="AIUsageMenuBarApp"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
EXECUTABLE_SRC="$BUILD_DIR/$PRODUCT_NAME"
EXECUTABLE_DST="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"

mkdir -p "$DIST_DIR" "$CLANG_MODULE_CACHE_PATH"

env CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  swift build -c release --product "$PRODUCT_NAME" >&2

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE_SRC" "$EXECUTABLE_DST"
cp "$ROOT_DIR/ai_usage_collector.py" "$APP_BUNDLE/Contents/Resources/ai_usage_collector.py"
cp "$ROOT_DIR/config.example.json" "$APP_BUNDLE/Contents/Resources/config.example.json"
chmod +x "$EXECUTABLE_DST"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>local.ai-usage-menubar</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
  </dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "$APP_BUNDLE"
