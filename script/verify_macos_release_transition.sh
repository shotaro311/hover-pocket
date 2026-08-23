#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${REPOSITORY:-shotaro311/hover-pocket}"
PREVIOUS_TAG="${1:-}"
CURRENT_TAG="${2:-}"

if [[ ! "$PREVIOUS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
  echo "error=previous tag must match vMAJOR.MINOR.PATCH-BUILD" >&2
  exit 1
fi
if [[ ! "$CURRENT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
  echo "error=current tag must match vMAJOR.MINOR.PATCH-BUILD" >&2
  exit 1
fi
if [[ "$PREVIOUS_TAG" == "$CURRENT_TAG" ]]; then
  echo "error=previous and current tags must differ" >&2
  exit 1
fi

python3 - "$PREVIOUS_TAG" "$CURRENT_TAG" <<'PY'
import re
import sys

def version(tag: str) -> tuple[int, int, int, int]:
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)-(\d+)", tag)
    if match is None:
        raise SystemExit("invalid release tag")
    return tuple(int(part) for part in match.groups())

if version(sys.argv[1]) >= version(sys.argv[2]):
    raise SystemExit("previous tag must be older than current tag")
PY

for command in gh curl ditto codesign xcrun spctl plutil openssl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error=required command is missing: $command" >&2
    exit 1
  fi
done

TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hoverpocket-macos-transition.XXXXXX")"
DOWNLOAD_ROOT="$TEMPORARY_ROOT/downloads"
INSTALL_ROOT="$TEMPORARY_ROOT/Applications"
HISTORY_ROOT="$TEMPORARY_ROOT/history"
USER_DATA_ROOT="$TEMPORARY_ROOT/UserData/HoverPocket"
mkdir -p "$DOWNLOAD_ROOT" "$INSTALL_ROOT" "$HISTORY_ROOT" "$USER_DATA_ROOT"
printf '{"owner":"an8-transition"}\n' > "$USER_DATA_ROOT/sentinel.json"

move_temporary_root_to_trash() {
  if [[ ! -d "$TEMPORARY_ROOT" ]]; then
    return
  fi
  local trash_root="$HOME/.Trash"
  mkdir -p "$trash_root"
  local destination="$trash_root/$(basename "$TEMPORARY_ROOT")-$(date +%Y%m%d%H%M%S)"
  mv "$TEMPORARY_ROOT" "$destination"
  echo "temporary_result=$destination" >&2
}
trap move_temporary_root_to_trash EXIT

release_asset_field() {
  local tag="$1"
  local asset_name="$2"
  local field="$3"
  local result
  result="$(gh api "repos/$REPOSITORY/releases/tags/$tag" \
    --jq "[.assets[] | select(.name == \"$asset_name\") | .$field] | if length == 1 then .[0] else error(\"asset missing or duplicated\") end")"
  if [[ -z "$result" || "$result" == "null" ]]; then
    echo "error=missing $field for $asset_name" >&2
    exit 1
  fi
  printf '%s' "$result"
}

download_asset() {
  local tag="$1"
  local asset_name="$2"
  local destination="$3"
  local url
  url="$(release_asset_field "$tag" "$asset_name" browser_download_url)"
  if [[ "$url" != "https://github.com/$REPOSITORY/releases/download/$tag/$asset_name" ]]; then
    echo "error=unexpected download URL for $asset_name" >&2
    exit 1
  fi
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$url" --output "$destination"
  local expected_size
  expected_size="$(release_asset_field "$tag" "$asset_name" size)"
  local actual_size
  actual_size="$(stat -f '%z' "$destination")"
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "error=size mismatch for $asset_name" >&2
    exit 1
  fi
  local expected_digest
  expected_digest="$(release_asset_field "$tag" "$asset_name" digest)"
  local actual_digest
  actual_digest="sha256:$(shasum -a 256 "$destination" | awk '{print $1}')"
  if [[ "$actual_digest" != "$expected_digest" ]]; then
    echo "error=GitHub digest mismatch for $asset_name" >&2
    exit 1
  fi
}

prepare_release() {
  local tag="$1"
  local label="$2"
  local version_build="${tag#v}"
  local version="${version_build%-*}"
  local build="${version_build##*-}"
  local asset_name="HoverPocket-$version-$build.zip"
  local release_dir="$DOWNLOAD_ROOT/$label"
  local archive_path="$release_dir/$asset_name"
  local checksum_path="$archive_path.sha256"
  local appcast_path="$release_dir/appcast.xml"
  local extract_root="$release_dir/extracted"
  mkdir -p "$release_dir" "$extract_root"

  download_asset "$tag" "$asset_name" "$archive_path"
  download_asset "$tag" "$asset_name.sha256" "$checksum_path"
  download_asset "$tag" "appcast.xml" "$appcast_path"
  local checksum_digest
  checksum_digest="$(awk 'NF { print tolower($1); exit }' "$checksum_path")"
  if [[ ! "$checksum_digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error=invalid checksum file for $asset_name" >&2
    exit 1
  fi
  if [[ "$(shasum -a 256 "$archive_path" | awk '{print $1}')" != "$checksum_digest" ]]; then
    echo "error=checksum file mismatch for $asset_name" >&2
    exit 1
  fi

  python3 - "$ROOT_DIR" "$appcast_path" "$archive_path" "$tag" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "verify_release_readback",
    root / "script" / "verify_release_readback.py",
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
appcast = module.parse_appcast(pathlib.Path(sys.argv[2]).read_bytes(), "shotaro311/hover-pocket")
if appcast.release_tag != sys.argv[4]:
    raise SystemExit("appcast release tag mismatch")
module.verify_ed25519_signature(
    module.DEFAULT_SPARKLE_PUBLIC_KEY,
    appcast.signature,
    pathlib.Path(sys.argv[3]),
)
PY

  ditto -x -k "$archive_path" "$extract_root"
  local app_path="$extract_root/HoverPocket.app"
  if [[ ! -d "$app_path" ]]; then
    echo "error=HoverPocket.app is missing from $asset_name" >&2
    exit 1
  fi
  if [[ "$(find "$extract_root" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" != "1" ]]; then
    echo "error=release ZIP contains unexpected top-level entries" >&2
    exit 1
  fi
  if [[ "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" != "$version" ]]; then
    echo "error=app version mismatch for $tag" >&2
    exit 1
  fi
  if [[ "$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" != "$build" ]]; then
    echo "error=app build mismatch for $tag" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app_path" >&2
  xcrun stapler validate "$app_path" >&2
  spctl --assess --type execute "$app_path" >&2
  printf '%s' "$app_path"
}

assert_installed() {
  local expected_tag="$1"
  local app_path="$INSTALL_ROOT/HoverPocket.app"
  local version_build="${expected_tag#v}"
  local version="${version_build%-*}"
  local build="${version_build##*-}"
  if [[ ! -d "$app_path" ]]; then
    echo "error=installed app is missing" >&2
    exit 1
  fi
  if [[ "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" != "$version" ]] || \
     [[ "$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" != "$build" ]]; then
    echo "error=installed app identity mismatch" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app_path" >&2
  xcrun stapler validate "$app_path" >&2
  spctl --assess --type execute "$app_path" >&2
}

replace_installed_app() {
  local source_app="$1"
  local phase="$2"
  local installed_app="$INSTALL_ROOT/HoverPocket.app"
  if [[ -d "$installed_app" ]]; then
    mv "$installed_app" "$HISTORY_ROOT/$phase-previous.app"
  fi
  ditto "$source_app" "$installed_app"
}

PREVIOUS_APP="$(prepare_release "$PREVIOUS_TAG" previous)"
CURRENT_APP="$(prepare_release "$CURRENT_TAG" current)"

replace_installed_app "$PREVIOUS_APP" install
assert_installed "$PREVIOUS_TAG"
replace_installed_app "$CURRENT_APP" upgrade
assert_installed "$CURRENT_TAG"
replace_installed_app "$PREVIOUS_APP" rollback
assert_installed "$PREVIOUS_TAG"
replace_installed_app "$CURRENT_APP" reupgrade
assert_installed "$CURRENT_TAG"

mv "$INSTALL_ROOT/HoverPocket.app" "$HISTORY_ROOT/uninstalled.app"
if [[ -e "$INSTALL_ROOT/HoverPocket.app" ]]; then
  echo "error=uninstall transition did not remove the app" >&2
  exit 1
fi
if [[ ! -f "$USER_DATA_ROOT/sentinel.json" ]]; then
  echo "error=uninstall transition removed user data" >&2
  exit 1
fi

ditto "$CURRENT_APP" "$INSTALL_ROOT/HoverPocket.app"
assert_installed "$CURRENT_TAG"
if [[ ! -f "$USER_DATA_ROOT/sentinel.json" ]]; then
  echo "error=reinstall transition did not preserve user data" >&2
  exit 1
fi

printf '{"status":"passed","previousTag":"%s","currentTag":"%s","install":"verified","upgrade":"verified","rollback":"verified","uninstall":"verified","reinstall":"verified","userDataPreserved":true}\n' \
  "$PREVIOUS_TAG" "$CURRENT_TAG"
