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

mkdir -p "$DIST_DIR"

swift build -c release --product "$PRODUCT_NAME" >&2

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE_SRC" "$EXECUTABLE_DST"
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
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
  </dict>
</plist>
PLIST

echo "$APP_BUNDLE"
