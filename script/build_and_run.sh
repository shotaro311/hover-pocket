#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
DISPLAY_NAME="ホバーポケット"
PRODUCT_NAME="HoverPocket"
LEGACY_PROCESS_NAMES=("NotchPocket" "NotchPokke" "HoverMenuPreview")
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE_PATH="$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
DEFAULT_SPARKLE_FEED_URL="https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml"
DEFAULT_SPARKLE_PUBLIC_ED_KEY="J2afuh/KnvOiS3eoNrMJoCyldAXL+Oku9scoSS5OUJE="

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
GOOGLE_OAUTH_CHROME_PROFILE="${GOOGLE_OAUTH_CHROME_PROFILE:-$(read_env_key GOOGLE_OAUTH_CHROME_PROFILE)}"
GOOGLE_OAUTH_CHROME_USER_DATA_DIR="${GOOGLE_OAUTH_CHROME_USER_DATA_DIR:-$(read_env_key GOOGLE_OAUTH_CHROME_USER_DATA_DIR)}"
GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT="${GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT:-$(read_env_key GOOGLE_OAUTH_CHROME_REMOTE_DEBUGGING_PORT)}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(read_env_key CODESIGN_IDENTITY)}"
CODESIGN_HARDENED_RUNTIME="${CODESIGN_HARDENED_RUNTIME:-$(read_env_key CODESIGN_HARDENED_RUNTIME)}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$(read_env_key SPARKLE_FEED_URL)}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(read_env_key SPARKLE_PUBLIC_ED_KEY)}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$DEFAULT_SPARKLE_FEED_URL}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$DEFAULT_SPARKLE_PUBLIC_ED_KEY}"
GOOGLE_OAUTH_PLIST=""
SPARKLE_PLIST=""
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthClientID</key>
  <string>$(xml_escape "$GOOGLE_CLIENT_ID")</string>
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
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  SPARKLE_PLIST+="  <key>SUFeedURL</key>
  <string>$(xml_escape "$SPARKLE_FEED_URL")</string>
"
fi
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  SPARKLE_PLIST+="  <key>SUPublicEDKey</key>
  <string>$(xml_escape "$SPARKLE_PUBLIC_ED_KEY")</string>
"
fi

default_codesign_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Apple Development:/ { print $2; exit }'
}

for process_name in "$APP_NAME" "${LEGACY_PROCESS_NAMES[@]}"; do
  if pgrep -x "$process_name" >/dev/null 2>&1; then
    pkill -x "$process_name" || true
    sleep 0.2
  fi
done

swift build

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Frameworks"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

SPARKLE_FRAMEWORK_PATH="$(find "$ROOT_DIR/.build" -maxdepth 5 -path '*/debug/Sparkle.framework' -type d 2>/dev/null | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK_PATH" ]]; then
  ditto "$SPARKLE_FRAMEWORK_PATH" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$EXECUTABLE_PATH" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH"
  fi
fi

cat > "$BUNDLE_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.hover-pocket</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$(xml_escape "$APP_VERSION")</string>
  <key>CFBundleVersion</key>
  <string>$(xml_escape "$APP_BUILD")</string>
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
${SPARKLE_PLIST}  <key>SUEnableInstallerLauncherService</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>ホバーポケット uses the Mac camera to show a mirror preview while the hover panel is open.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>ホバーポケット uses the microphone only for the mirror microphone check.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(default_codesign_identity || true)"
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  codesign_args=(--force --deep --sign "$CODESIGN_IDENTITY")
  if [[ "$CODESIGN_HARDENED_RUNTIME" == "1" || "$CODESIGN_HARDENED_RUNTIME" == "true" ]]; then
    codesign_args+=(--options runtime --timestamp)
  fi
  codesign "${codesign_args[@]}" "$BUNDLE_DIR" >/dev/null
  echo "Signed $APP_NAME.app with $CODESIGN_IDENTITY"
else
  echo "No codesigning identity found; using SwiftPM ad-hoc signature"
fi

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
