#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HoverPocket"
DISPLAY_NAME="ホバーポケット"
PRODUCT_NAME="HoverPocket"
LEGACY_PROCESS_NAMES=("NotchPocket" "NotchPokke" "HoverMenuPreview")
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE_PATH="$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
APP_ICON_NAME="AppIcon"
APP_ICON_SOURCE="$ROOT_DIR/Resources/$APP_ICON_NAME.png"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/Resources/HoverPocket.entitlements}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
DEFAULT_SPARKLE_FEED_URL="${DEFAULT_SPARKLE_FEED_URL:-}"
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

BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-$(read_env_key BUNDLE_IDENTIFIER)}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-local.codex.hover-pocket}"
GOOGLE_SIGN_IN_CLIENT_ID="${GOOGLE_SIGN_IN_CLIENT_ID:-$(read_env_key GOOGLE_SIGN_IN_CLIENT_ID)}"
GOOGLE_SIGN_IN_REVERSED_CLIENT_ID="${GOOGLE_SIGN_IN_REVERSED_CLIENT_ID:-$(read_env_key GOOGLE_SIGN_IN_REVERSED_CLIENT_ID)}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-$(read_env_key GOOGLE_CLIENT_ID)}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-$(read_env_key GOOGLE_CLIENT_SECRET)}"
GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK="${GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK:-$(read_env_key GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK)}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(read_env_key CODESIGN_IDENTITY)}"
CODESIGN_HARDENED_RUNTIME="${CODESIGN_HARDENED_RUNTIME:-$(read_env_key CODESIGN_HARDENED_RUNTIME)}"
HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX="${HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX:-$(read_env_key HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX)}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$(read_env_key SPARKLE_FEED_URL)}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(read_env_key SPARKLE_PUBLIC_ED_KEY)}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$DEFAULT_SPARKLE_FEED_URL}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$DEFAULT_SPARKLE_PUBLIC_ED_KEY}"
if [[ -z "$HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX" ]]; then
  if [[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX="release"
  else
    HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX="development"
  fi
fi
GOOGLE_OAUTH_PLIST=""
GOOGLE_SIGN_IN_PLIST=""
SPARKLE_PLIST=""
if [[ -n "$GOOGLE_SIGN_IN_CLIENT_ID" && -z "$GOOGLE_SIGN_IN_REVERSED_CLIENT_ID" ]]; then
  GOOGLE_SIGN_IN_REVERSED_CLIENT_ID="$(awk -F. '{ for (i=NF; i>=1; i--) printf "%s%s", $i, (i == 1 ? "" : ".") }' <<< "$GOOGLE_SIGN_IN_CLIENT_ID")"
fi
if [[ -n "$GOOGLE_SIGN_IN_CLIENT_ID" ]]; then
  GOOGLE_SIGN_IN_PLIST+="  <key>GIDClientID</key>
  <string>$(xml_escape "$GOOGLE_SIGN_IN_CLIENT_ID")</string>
"
fi
if [[ -n "$GOOGLE_SIGN_IN_REVERSED_CLIENT_ID" ]]; then
  GOOGLE_SIGN_IN_PLIST+="  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$(xml_escape "$GOOGLE_SIGN_IN_REVERSED_CLIENT_ID")</string>
      </array>
    </dict>
  </array>
"
fi
if [[ -n "$GOOGLE_CLIENT_ID" && ( -z "$GOOGLE_SIGN_IN_CLIENT_ID" || "$GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK" == "1" || "$GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK" == "true" ) ]]; then
  GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthClientID</key>
  <string>$(xml_escape "$GOOGLE_CLIENT_ID")</string>
"
  if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
    GOOGLE_OAUTH_PLIST+="  <key>GoogleOAuthClientSecret</key>
  <string>$(xml_escape "$GOOGLE_CLIENT_SECRET")</string>
"
  fi
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

install_app_icon() {
  [[ -f "$APP_ICON_SOURCE" ]] || return 0

  local resources_dir="$BUNDLE_DIR/Contents/Resources"
  local iconset_dir
  iconset_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoverpocket-iconset.XXXXXX")/$APP_ICON_NAME.iconset"
  mkdir -p "$iconset_dir"

  sips -z 16 16 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$APP_ICON_SOURCE" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset_dir" -o "$resources_dir/$APP_ICON_NAME.icns"
  rm -rf "$(dirname "$iconset_dir")"
}

for process_name in "$APP_NAME" "${LEGACY_PROCESS_NAMES[@]}"; do
  if pgrep -x "$process_name" >/dev/null 2>&1; then
    pkill -x "$process_name" || true
    sleep 0.2
  fi
done

swift build

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Frameworks" "$BUNDLE_DIR/Contents/Resources"
cp ".build/debug/$PRODUCT_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"
install_app_icon

SPARKLE_FRAMEWORK_PATH="$(find "$ROOT_DIR/.build" -maxdepth 5 -path '*/debug/Sparkle.framework' -type d 2>/dev/null | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK_PATH" ]]; then
  ditto "$SPARKLE_FRAMEWORK_PATH" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$EXECUTABLE_PATH" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH"
  fi
fi

# mediaremote-adapter: メディア操作コマンドを Apple 署名の perl 経由で送るための dylib と
# スクリプト。macOS 15.4+ ではこれがないと再生/停止・シークが効かない。
ADAPTER_DYLIB_PATH="$(find "$ROOT_DIR/.build" -maxdepth 3 -path '*/debug/libMediaRemoteAdapter.dylib' -type f 2>/dev/null | head -1)"
ADAPTER_RUN_SCRIPT="$(find "$ROOT_DIR/.build" -maxdepth 4 -path '*/debug/MediaRemoteAdapter_MediaRemoteAdapter.bundle/run.pl' -type f 2>/dev/null | head -1)"
if [[ -n "$ADAPTER_DYLIB_PATH" && -n "$ADAPTER_RUN_SCRIPT" ]]; then
  cp "$ADAPTER_DYLIB_PATH" "$BUNDLE_DIR/Contents/Frameworks/libMediaRemoteAdapter.dylib"
  cp "$ADAPTER_RUN_SCRIPT" "$BUNDLE_DIR/Contents/Resources/mediaremote-adapter.pl"
  if ! otool -l "$EXECUTABLE_PATH" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH"
  fi
else
  echo "warning: mediaremote-adapter artifacts not found; media commands will not work" >&2
fi

cat > "$BUNDLE_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$(xml_escape "$BUNDLE_IDENTIFIER")</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
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
  <key>HoverPocketKeychainServiceSuffix</key>
  <string>$(xml_escape "$HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX")</string>
${GOOGLE_SIGN_IN_PLIST}${GOOGLE_OAUTH_PLIST}  <key>NSAppTransportSecurity</key>
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
  <key>NSAppleEventsUsageDescription</key>
  <string>macOS の再生中メディアを取得できない場合に、ブラウザで再生中のメディアを検出するために使用します。</string>
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
  if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    codesign_args+=(--entitlements "$ENTITLEMENTS_PATH")
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
