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
PKG_PATH="$OUTPUT_DIR/${PACKAGE_NAME}.pkg"
SHA_PATH="$OUTPUT_DIR/${PACKAGE_NAME}.sha256"

rm -f "$PKG_PATH" "$SHA_PATH"
mkdir -p "$OUTPUT_DIR"

pkgbuild \
  --identifier "local.ai-usage-menubar" \
  --version "$VERSION" \
  --component "$APP_SOURCE" \
  --install-location "/Applications" \
  "$PKG_PATH"

shasum -a 256 "$PKG_PATH" >"$SHA_PATH"

echo "$PKG_PATH"
echo "$SHA_PATH"
