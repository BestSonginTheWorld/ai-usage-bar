#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/release"
DIST_APP_PATH="$ROOT_DIR/dist/AIUsageMenuBar.app"
USE_PREBUILT=0
VERSION_OVERRIDE=""
BUILD_OVERRIDE="${APP_BUILD:-1}"

for arg in "$@"; do
  case "$arg" in
    --use-prebuilt)
      USE_PREBUILT=1
      ;;
    --version=*)
      VERSION_OVERRIDE="${arg#*=}"
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

APP_SOURCE=""
VERSION="$VERSION_OVERRIDE"
if [[ "$USE_PREBUILT" -eq 1 ]]; then
  if [[ ! -d "$DIST_APP_PATH" ]]; then
    echo "Prebuilt app not found: $DIST_APP_PATH" >&2
    exit 1
  fi
  APP_SOURCE="$DIST_APP_PATH"
else
  if [[ -z "$VERSION" ]]; then
    VERSION="${APP_VERSION:-0.1.0}"
  fi
  APP_SOURCE="$(APP_VERSION="$VERSION" APP_BUILD="$BUILD_OVERRIDE" "$ROOT_DIR/scripts/build_app.sh")"
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_SOURCE/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="0.1.0"
fi

PACKAGE_NAME="AIUsageMenuBar-${VERSION}"
STAGE_DIR="$OUTPUT_DIR/$PACKAGE_NAME"
ZIP_PATH="$OUTPUT_DIR/${PACKAGE_NAME}.zip"
SHA_PATH="$OUTPUT_DIR/${PACKAGE_NAME}.sha256"

rm -rf "$STAGE_DIR" "$ZIP_PATH" "$SHA_PATH"
mkdir -p "$STAGE_DIR"

cp -R "$APP_SOURCE" "$STAGE_DIR/AIUsageMenuBar.app"
cp "$ROOT_DIR/ai_usage_collector.py" "$STAGE_DIR/ai_usage_collector.py"
cp "$ROOT_DIR/config.example.json" "$STAGE_DIR/config.example.json"
cp "$ROOT_DIR/scripts/install.sh" "$STAGE_DIR/install.sh"
cp "$ROOT_DIR/scripts/uninstall.sh" "$STAGE_DIR/uninstall.sh"
cp "$ROOT_DIR/INSTALL.txt" "$STAGE_DIR/README.txt"
chmod +x "$STAGE_DIR/install.sh" "$STAGE_DIR/uninstall.sh"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$STAGE_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" >"$SHA_PATH"

echo "$ZIP_PATH"
echo "$SHA_PATH"
