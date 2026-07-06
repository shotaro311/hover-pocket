#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/dist/releases"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
DEFAULT_SPARKLE_FEED_URL="https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml"
DEFAULT_SPARKLE_PUBLIC_ED_KEY="J2afuh/KnvOiS3eoNrMJoCyldAXL+Oku9scoSS5OUJE="
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$DEFAULT_SPARKLE_FEED_URL}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$DEFAULT_SPARKLE_PUBLIC_ED_KEY}"

developer_id_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
}

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(developer_id_identity || true)}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  echo "warning=Developer ID Application identity not found; falling back to build script default signing" >&2
fi

mkdir -p "$RELEASE_DIR"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  APP_VERSION="$APP_VERSION" \
  APP_BUILD="$APP_BUILD" \
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  CODESIGN_HARDENED_RUNTIME=1 \
  HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX=release \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    "$ROOT_DIR/script/build_and_run.sh" --build-only >/dev/null
else
  APP_VERSION="$APP_VERSION" \
  APP_BUILD="$APP_BUILD" \
  HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX=release \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    "$ROOT_DIR/script/build_and_run.sh" --build-only >/dev/null
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$RELEASE_DIR/${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip"
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

APP_VERSION="$APP_VERSION" APP_BUILD="$APP_BUILD" "$ROOT_DIR/script/generate_appcast.sh" >/dev/null

echo "app=$APP_PATH"
echo "zip=$ZIP_PATH"
echo "sha256=$ZIP_PATH.sha256"
echo "appcast=$RELEASE_DIR/appcast.xml"
spctl -a -vv "$APP_PATH" || true
