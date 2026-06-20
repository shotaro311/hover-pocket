#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
SPARKLE_TAG="${SPARKLE_TAG:-v${APP_VERSION}-${APP_BUILD}}"
RELEASE_TITLE="${RELEASE_TITLE:-HoverPocket ${APP_VERSION} (${APP_BUILD})}"
RELEASE_NOTES="${RELEASE_NOTES:-Download ${APP_NAME}-macOS-app.zip for manual installation. ${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip is kept for Sparkle updates.}"
PUBLISH_DRY_RUN="${PUBLISH_DRY_RUN:-0}"
PUBLISH_REQUIRE_NOTARIZED="${PUBLISH_REQUIRE_NOTARIZED:-1}"
if [[ -z "${PUBLISH_PREPARE_RELEASE:-}" ]]; then
  if [[ "$PUBLISH_DRY_RUN" == "1" || "$PUBLISH_DRY_RUN" == "true" ]]; then
    PUBLISH_PREPARE_RELEASE=0
  else
    PUBLISH_PREPARE_RELEASE=1
  fi
fi
ZIP_PATH="$ROOT_DIR/dist/releases/${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip"
SHA_PATH="$ZIP_PATH.sha256"
APPCAST_PATH="$ROOT_DIR/dist/releases/appcast.xml"
INSTALL_ZIP_PATH="$ROOT_DIR/dist/releases/${APP_NAME}-macOS-app.zip"

cd "$ROOT_DIR"

verify_notarized_zip_payload() {
  local extract_dir
  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoverpocket-publish-zip.XXXXXX")"
  ditto -x -k "$ZIP_PATH" "$extract_dir"

  local extracted_app="$extract_dir/$APP_NAME.app"
  if [[ ! -d "$extracted_app" ]]; then
    echo "error=extracted app not found in release zip" >&2
    rm -rf "$extract_dir"
    exit 1
  fi

  if ! codesign --verify --deep --strict --verbose=2 "$extracted_app"; then
    rm -rf "$extract_dir"
    exit 1
  fi
  if ! xcrun stapler validate "$extracted_app"; then
    rm -rf "$extract_dir"
    exit 1
  fi
  if ! spctl --assess --type execute --verbose=2 "$extracted_app"; then
    rm -rf "$extract_dir"
    exit 1
  fi
  rm -rf "$extract_dir"
}

prepare_install_zip_alias() {
  cp "$ZIP_PATH" "$INSTALL_ZIP_PATH"
}

if ! command -v gh >/dev/null 2>&1; then
  echo "error=gh CLI is required to publish a GitHub release" >&2
  exit 1
fi

if [[ "$PUBLISH_PREPARE_RELEASE" == "1" || "$PUBLISH_PREPARE_RELEASE" == "true" ]]; then
  if [[ "$PUBLISH_REQUIRE_NOTARIZED" == "1" || "$PUBLISH_REQUIRE_NOTARIZED" == "true" ]]; then
    "$ROOT_DIR/script/notarize_release.sh"
  else
    "$ROOT_DIR/script/package_zip.sh"
  fi
fi

if [[ ! -f "$ZIP_PATH" || ! -f "$SHA_PATH" || ! -f "$APPCAST_PATH" ]]; then
  echo "error=release artifacts are missing" >&2
  exit 1
fi

if [[ "$PUBLISH_REQUIRE_NOTARIZED" == "1" || "$PUBLISH_REQUIRE_NOTARIZED" == "true" ]]; then
  verify_notarized_zip_payload
fi

prepare_install_zip_alias

if [[ "$PUBLISH_DRY_RUN" == "1" || "$PUBLISH_DRY_RUN" == "true" ]]; then
  echo "dry_run=true"
  echo "prepare_release=$PUBLISH_PREPARE_RELEASE"
  echo "require_notarized=$PUBLISH_REQUIRE_NOTARIZED"
  echo "tag=$SPARKLE_TAG"
  echo "install_zip=$INSTALL_ZIP_PATH"
  echo "zip=$ZIP_PATH"
  echo "sha256=$SHA_PATH"
  echo "appcast=$APPCAST_PATH"
  exit 0
fi

if gh release view "$SPARKLE_TAG" >/dev/null 2>&1; then
  gh release upload "$SPARKLE_TAG" "$INSTALL_ZIP_PATH" "$ZIP_PATH" "$SHA_PATH" "$APPCAST_PATH" --clobber
else
  notes_file="$(mktemp)"
  trap 'rm -f "$notes_file"' EXIT
  printf '%s\n' "$RELEASE_NOTES" > "$notes_file"
  gh release create "$SPARKLE_TAG" "$INSTALL_ZIP_PATH" "$ZIP_PATH" "$SHA_PATH" "$APPCAST_PATH" \
    --title "$RELEASE_TITLE" \
    --notes-file "$notes_file"
fi

echo "release=https://github.com/shotaro311/hover-pocket/releases/tag/$SPARKLE_TAG"
