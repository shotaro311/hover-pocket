#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/dist/releases"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
ZIP_PATH="$RELEASE_DIR/${APP_NAME}-${APP_VERSION}-${APP_BUILD}.zip"
SUBMISSION_JSON="$RELEASE_DIR/notarytool-${APP_VERSION}-${APP_BUILD}.json"
NOTARYTOOL_TIMEOUT="${NOTARYTOOL_TIMEOUT:-30m}"
NOTARIZE_BUILD="${NOTARIZE_BUILD:-1}"
NOTARIZE_KEEP_JSON="${NOTARIZE_KEEP_JSON:-0}"

cd "$ROOT_DIR"

require_command() {
  local command="$1"
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error=$command is required" >&2
    exit 1
  fi
}

notarytool_auth_args() {
  auth_args=()

  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    auth_args+=(--keychain-profile "$NOTARYTOOL_PROFILE")
    if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
      auth_args+=(--keychain "$NOTARYTOOL_KEYCHAIN")
    fi
    return
  fi

  if [[ -n "${NOTARYTOOL_KEY:-}" && -n "${NOTARYTOOL_KEY_ID:-}" ]]; then
    auth_args+=(--key "$NOTARYTOOL_KEY" --key-id "$NOTARYTOOL_KEY_ID")
    if [[ -n "${NOTARYTOOL_ISSUER:-}" ]]; then
      auth_args+=(--issuer "$NOTARYTOOL_ISSUER")
    fi
    return
  fi

  cat >&2 <<'EOF'
error=missing notarization credentials
Set one of:
  NOTARYTOOL_PROFILE=<keychain-profile>
  NOTARYTOOL_KEY=<AuthKey_XXXX.p8> NOTARYTOOL_KEY_ID=<key-id> [NOTARYTOOL_ISSUER=<issuer-uuid>]

Recommended one-time setup:
  xcrun notarytool store-credentials hover-pocket --apple-id <apple-id> --team-id <team-id>
  NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh
EOF
  exit 1
}

validate_notary_credentials() {
  local validation_output
  validation_output="$(mktemp "${TMPDIR:-/tmp}/hoverpocket-notary-credentials.XXXXXX")"

  if xcrun notarytool history \
    --output-format json \
    --no-progress \
    "${auth_args[@]}" >"$validation_output" 2>&1; then
    rm -f "$validation_output"
    return
  fi

  cat >&2 <<'EOF'
error=notarization credentials validation failed
Create a Keychain profile or pass an App Store Connect API key, then rerun.

Recommended one-time setup:
  xcrun notarytool store-credentials hover-pocket --apple-id <apple-id> --team-id <team-id>
  NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh
EOF
  sed -n '1,40p' "$validation_output" >&2
  rm -f "$validation_output"
  exit 1
}

json_value() {
  local key="$1"
  /usr/bin/plutil -extract "$key" raw -o - "$SUBMISSION_JSON" 2>/dev/null || true
}

verify_app_for_distribution() {
  local app_path="$1"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  xcrun stapler validate "$app_path"
  spctl --assess --type execute --verbose=2 "$app_path"
}

verify_final_zip_payload() {
  local extract_dir
  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoverpocket-notarized-zip.XXXXXX")"
  ditto -x -k "$ZIP_PATH" "$extract_dir"

  local extracted_app="$extract_dir/$APP_NAME.app"
  if [[ ! -d "$extracted_app" ]]; then
    echo "error=extracted app not found in final zip" >&2
    rm -rf "$extract_dir"
    exit 1
  fi

  if ! verify_app_for_distribution "$extracted_app"; then
    rm -rf "$extract_dir"
    exit 1
  fi
  rm -rf "$extract_dir"
}

rezip_stapled_app() {
  rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
  ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"
}

require_command xcrun
require_command ditto
require_command shasum

mkdir -p "$RELEASE_DIR"

notarytool_auth_args
validate_notary_credentials

if [[ "$NOTARIZE_BUILD" != "0" && "$NOTARIZE_BUILD" != "false" ]]; then
  "$ROOT_DIR/script/package_zip.sh" >/dev/null
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error=app bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error=zip not found: $ZIP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -f "$SUBMISSION_JSON"
xcrun notarytool submit "$ZIP_PATH" \
  --wait \
  --timeout "$NOTARYTOOL_TIMEOUT" \
  --output-format json \
  "${auth_args[@]}" > "$SUBMISSION_JSON"

submission_id="$(json_value id)"
submission_status="$(json_value status)"

if [[ "$submission_status" != "Accepted" ]]; then
  echo "notary_submission_id=$submission_id" >&2
  echo "notary_status=$submission_status" >&2
  echo "notary_log_command=xcrun notarytool log $submission_id <credentials>" >&2
  exit 1
fi

xcrun stapler staple "$APP_PATH"
verify_app_for_distribution "$APP_PATH"

rezip_stapled_app
APP_VERSION="$APP_VERSION" APP_BUILD="$APP_BUILD" "$ROOT_DIR/script/generate_appcast.sh" >/dev/null

verify_app_for_distribution "$APP_PATH"
verify_final_zip_payload

if [[ "$NOTARIZE_KEEP_JSON" != "1" && "$NOTARIZE_KEEP_JSON" != "true" ]]; then
  rm -f "$SUBMISSION_JSON"
fi

echo "notary_submission_id=$submission_id"
echo "notary_status=$submission_status"
echo "app=$APP_PATH"
echo "zip=$ZIP_PATH"
echo "sha256=$ZIP_PATH.sha256"
echo "appcast=$RELEASE_DIR/appcast.xml"
