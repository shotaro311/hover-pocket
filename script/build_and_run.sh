#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NotchPokke"
DISPLAY_NAME="ノッチポッケ"
PRODUCT_NAME="NotchPokke"
LEGACY_PROCESS_NAME="HoverMenuPreview"
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE_PATH="$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

read_env_key() {
  local key="$1"
  local file
  for file in "$ROOT_DIR/.env.local" "$ROOT_DIR/.env"; do
    if [[ -f "$file" ]]; then
      local value
      value="$(awk -F= -v key="$key" '
        $0 !~ /^[[:space:]]*#/ && $1 == key {
          sub(/^[^=]*=/, "")
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          gsub(/^"|"$/, "")
          gsub(/^'\''|'\''$/, "")
          print
          exit
        }
      ' "$file")"
      if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return
      fi
    fi
  done
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  printf '%s' "$value"
}

GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-$(read_env_key GOOGLE_CLIENT_ID)}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-$(read_env_key GOOGLE_CLIENT_SECRET)}"
GOOGLE_OAUTH_CHROME_PROFILE="${GOOGLE_OAUTH_CHROME_PROFILE:-$(read_env_key GOOGLE_OAUTH_CHROME_PROFILE)}"
GOOGLE_OAUTH_CHROME_USER_DATA_DIR="${GOOGLE_OAUTH_CHROME_USER_DATA_DIR:-$(read_env_key GOOGLE_OAUTH_CHROME_USER_DATA_DIR)}"
GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT="${GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT:-$(read_env_key GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT)}"
GOOGLE_OAUTH_PLIST=""
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthClientID</key>
  <string>$(xml_escape "$GOOGLE_CLIENT_ID")</string>
"
fi
if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthClientSecret</key>
  <string>$(xml_escape "$GOOGLE_CLIENT_SECRET")</string>
"
fi
if [[ -n "$GOOGLE_OAUTH_CHROME_PROFILE" ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthChromeProfileDirectory</key>
  <string>$(xml_escape "$GOOGLE_OAUTH_CHROME_PROFILE")</string>
"
fi
if [[ -n "$GOOGLE_OAUTH_CHROME_USER_DATA_DIR" ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthChromeUserDataDirectory</key>
  <string>$(xml_escape "$GOOGLE_OAUTH_CHROME_USER_DATA_DIR")</string>
"
fi
if [[ -n "$GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT" ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthChromeRemoteDebuggingPort</key>
  <string>$(xml_escape "$GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT")</string>
"
fi

for process_name in "$APP_NAME" "$LEGACY_PROCESS_NAME"; do
  if pgrep -x "$process_name" >/dev/null 2>&1; then
    pkill -x "$process_name" || true
    sleep 0.2
  fi
done

swift build

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

cat > "$BUNDLE_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.notch-pokke</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
${GOOGLE_OAUTH_PLIST}  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSCameraUsageDescription</key>
  <string>ノッチポッケ uses the Mac camera to show a mirror preview while the notch panel is open.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>ノッチポッケ uses the microphone only for the mirror microphone check.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "${1:-}" == "--verify" ]]; then
  /usr/bin/open -n "$BUNDLE_DIR"
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
  echo "$APP_NAME launched"
elif [[ "${1:-}" == "--build-only" ]]; then
  printf '%s\n' "$BUNDLE_DIR"
else
  /usr/bin/open -n "$BUNDLE_DIR"
fi
