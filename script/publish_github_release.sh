#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
SPARKLE_TAG="${SPARKLE_TAG:-v${APP_VERSION}-${APP_BUILD}}"
RELEASE_TITLE="${RELEASE_TITLE:-HoverPocket ${APP_VERSION} (${APP_BUILD})}"
RELEASE_NOTES="${RELEASE_NOTES:-Initial Sparkle-enabled build.}"
ZIP_PATH="$ROOT_DIR/dist/releases/${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip"
SHA_PATH="$ZIP_PATH.sha256"
APPCAST_PATH="$ROOT_DIR/dist/releases/appcast.xml"

cd "$ROOT_DIR"

if ! command -v gh >/dev/null 2>&1; then
  echo "error=gh CLI is required to publish a GitHub release" >&2
  exit 1
fi

"$ROOT_DIR/script/package_zip.sh"

if [[ ! -f "$ZIP_PATH" || ! -f "$SHA_PATH" || ! -f "$APPCAST_PATH" ]]; then
  echo "error=release artifacts are missing" >&2
  exit 1
fi

if [[ "${PUBLISH_DRY_RUN:-}" == "1" || "${PUBLISH_DRY_RUN:-}" == "true" ]]; then
  echo "dry_run=true"
  echo "tag=$SPARKLE_TAG"
  echo "zip=$ZIP_PATH"
  echo "sha256=$SHA_PATH"
  echo "appcast=$APPCAST_PATH"
  exit 0
fi

if gh release view "$SPARKLE_TAG" >/dev/null 2>&1; then
  gh release upload "$SPARKLE_TAG" "$ZIP_PATH" "$SHA_PATH" "$APPCAST_PATH" --clobber
else
  notes_file="$(mktemp)"
  trap 'rm -f "$notes_file"' EXIT
  printf '%s\n' "$RELEASE_NOTES" > "$notes_file"
  gh release create "$SPARKLE_TAG" "$ZIP_PATH" "$SHA_PATH" "$APPCAST_PATH" \
    --title "$RELEASE_TITLE" \
    --notes-file "$notes_file"
fi

echo "release=https://github.com/shotaro311/hover-pocket/releases/tag/$SPARKLE_TAG"
