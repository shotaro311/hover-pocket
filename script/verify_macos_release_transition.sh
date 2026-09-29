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

capture_release_snapshot() {
  local tag="$1"
  local destination="$2"
  local response="$destination.response.json"
  gh api "repos/$REPOSITORY/releases/tags/$tag" > "$response"
  python3 - "$REPOSITORY" "$tag" "$response" "$destination" <<'PY'
import json
import pathlib
import re
import sys

repository, expected_tag, response_path, destination_path = sys.argv[1:]
release = json.loads(pathlib.Path(response_path).read_text(encoding="utf-8"))
if (
    release.get("tag_name") != expected_tag
    or release.get("draft") is not False
    or release.get("prerelease") is not False
):
    raise SystemExit(f"release {expected_tag} is not a matching published release")

assets = []
seen_names: set[str] = set()
for asset in release.get("assets", []):
    name = asset.get("name")
    size = asset.get("size")
    digest = asset.get("digest")
    url = asset.get("browser_download_url")
    if not isinstance(name, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) is None:
        raise SystemExit("release contains an unsafe asset name")
    if name in seen_names:
        raise SystemExit(f"release asset {name} is duplicated")
    if not isinstance(size, int) or size < 0:
        raise SystemExit(f"release asset {name} has an invalid size")
    if not isinstance(digest, str) or re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise SystemExit(f"release asset {name} has an invalid digest")
    expected_url = f"https://github.com/{repository}/releases/download/{expected_tag}/{name}"
    if url != expected_url:
        raise SystemExit(f"release asset {name} has an unexpected download URL")
    seen_names.add(name)
    assets.append({"name": name, "size": size, "digest": digest, "url": url})

snapshot = {"tag": expected_tag, "assets": sorted(assets, key=lambda item: item["name"])}
pathlib.Path(destination_path).write_text(
    json.dumps(snapshot, ensure_ascii=True, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

release_asset_field() {
  local snapshot_path="$1"
  local asset_name="$2"
  local field="$3"
  python3 - "$snapshot_path" "$asset_name" "$field" <<'PY'
import json
import pathlib
import sys

snapshot_path, asset_name, field = sys.argv[1:]
if field not in {"url", "size", "digest"}:
    raise SystemExit("unsupported release asset field")
snapshot = json.loads(pathlib.Path(snapshot_path).read_text(encoding="utf-8"))
matches = [asset for asset in snapshot["assets"] if asset["name"] == asset_name]
if len(matches) != 1:
    raise SystemExit(f"release asset {asset_name} is missing or duplicated")
print(matches[0][field], end="")
PY
}

download_asset() {
  local snapshot_path="$1"
  local tag="$2"
  local asset_name="$3"
  local destination="$4"
  local url
  url="$(release_asset_field "$snapshot_path" "$asset_name" url)"
  if [[ "$url" != "https://github.com/$REPOSITORY/releases/download/$tag/$asset_name" ]]; then
    echo "error=unexpected download URL for $asset_name" >&2
    exit 1
  fi
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$url" --output "$destination"
  local expected_size
  expected_size="$(release_asset_field "$snapshot_path" "$asset_name" size)"
  local actual_size
  actual_size="$(stat -f '%z' "$destination")"
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "error=size mismatch for $asset_name" >&2
    exit 1
  fi
  local expected_digest
  expected_digest="$(release_asset_field "$snapshot_path" "$asset_name" digest)"
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
  local snapshot_path="$3"
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

  download_asset "$snapshot_path" "$tag" "$asset_name" "$archive_path"
  download_asset "$snapshot_path" "$tag" "$asset_name.sha256" "$checksum_path"
  download_asset "$snapshot_path" "$tag" "appcast.xml" "$appcast_path"
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

PREVIOUS_SNAPSHOT="$DOWNLOAD_ROOT/previous.snapshot.json"
CURRENT_SNAPSHOT="$DOWNLOAD_ROOT/current.snapshot.json"
capture_release_snapshot "$PREVIOUS_TAG" "$PREVIOUS_SNAPSHOT"
capture_release_snapshot "$CURRENT_TAG" "$CURRENT_SNAPSHOT"

PREVIOUS_APP="$(prepare_release "$PREVIOUS_TAG" previous "$PREVIOUS_SNAPSHOT")"
CURRENT_APP="$(prepare_release "$CURRENT_TAG" current "$CURRENT_SNAPSHOT")"

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

PREVIOUS_FINAL_SNAPSHOT="$DOWNLOAD_ROOT/previous.final.snapshot.json"
CURRENT_FINAL_SNAPSHOT="$DOWNLOAD_ROOT/current.final.snapshot.json"
capture_release_snapshot "$PREVIOUS_TAG" "$PREVIOUS_FINAL_SNAPSHOT"
capture_release_snapshot "$CURRENT_TAG" "$CURRENT_FINAL_SNAPSHOT"
if ! cmp -s "$PREVIOUS_SNAPSHOT" "$PREVIOUS_FINAL_SNAPSHOT"; then
  echo "error=previous release changed during transition verification" >&2
  exit 1
fi
if ! cmp -s "$CURRENT_SNAPSHOT" "$CURRENT_FINAL_SNAPSHOT"; then
  echo "error=current release changed during transition verification" >&2
  exit 1
fi

printf '{"status":"passed","previousTag":"%s","currentTag":"%s","install":"verified","upgrade":"verified","rollback":"verified","uninstall":"verified","reinstall":"verified","userDataPreserved":true}\n' \
  "$PREVIOUS_TAG" "$CURRENT_TAG"
