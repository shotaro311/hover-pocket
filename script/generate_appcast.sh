#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
RELEASE_DIR="$ROOT_DIR/dist/releases"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-hover-pocket}"
SPARKLE_TAG="${SPARKLE_TAG:-v${APP_VERSION}-${APP_BUILD}}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/shotaro311/hover-pocket/releases/download/${SPARKLE_TAG}/}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
CURRENT_ZIP="$RELEASE_DIR/${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip"

if [[ ! -x "$SPARKLE_GENERATE_APPCAST" ]]; then
  echo "error=Sparkle generate_appcast tool not found. Run swift build first." >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR"

if [[ ! -f "$CURRENT_ZIP" ]]; then
  echo "error=update archive not found: $CURRENT_ZIP" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hoverpocket-appcast.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$CURRENT_ZIP" "$WORK_DIR/"
for notes_ext in html md txt; do
  notes_path="${CURRENT_ZIP%.*}.$notes_ext"
  if [[ -f "$notes_path" ]]; then
    cp "$notes_path" "$WORK_DIR/"
  fi
done
if [[ -f "$RELEASE_DIR/appcast.xml" ]]; then
  cp "$RELEASE_DIR/appcast.xml" "$WORK_DIR/appcast.xml"
fi

"$SPARKLE_GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX" \
  --versions "$APP_BUILD" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  "$WORK_DIR"

cp "$WORK_DIR/appcast.xml" "$RELEASE_DIR/appcast.xml"

echo "appcast=$RELEASE_DIR/appcast.xml"
