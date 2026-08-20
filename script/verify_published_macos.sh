#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <release-readback-report.json>" >&2
  exit 2
fi

EXPECTED_REPORT="$1"
REPOSITORY="${GITHUB_REPOSITORY:-shotaro311/hover-pocket}"
OUTPUT_PATH="${MACOS_READBACK_OUTPUT:-macos-gatekeeper-readback-report.json}"
EXPECTED_BUNDLE_IDENTIFIER="local.codex.hover-pocket"

if [[ ! -f "$EXPECTED_REPORT" ]]; then
  echo "error=release readback report not found" >&2
  exit 1
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error=invalid repository" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoverpocket-published-macos.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
metadata_path="$work_dir/expected.txt"

python3 - "$EXPECTED_REPORT" > "$metadata_path" <<'PY'
import json
import pathlib
import re
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if report.get("status") != "passed":
    raise SystemExit("release readback report did not pass")
macos = report.get("macos")
if not isinstance(macos, dict):
    raise SystemExit("macOS readback is missing")
snapshot = macos.get("assetSnapshot")
if not isinstance(snapshot, dict) or snapshot.get("releaseTag") != macos.get("releaseTag"):
    raise SystemExit("macOS snapshot release tag mismatch")
assets = snapshot.get("assets")
if not isinstance(assets, list) or len(assets) != 1 or not isinstance(assets[0], dict):
    raise SystemExit("macOS snapshot must contain exactly one asset")
asset = assets[0]
tag = snapshot["releaseTag"]
name = asset.get("name")
size = asset.get("size")
digest = asset.get("sha256")
version = macos.get("version")
build = macos.get("build")
if not isinstance(tag, str) or not re.fullmatch(r"v[0-9A-Za-z][0-9A-Za-z._+-]*", tag):
    raise SystemExit("invalid macOS release tag")
if not isinstance(name, str) or not re.fullmatch(r"HoverPocket-[0-9A-Za-z][0-9A-Za-z._+-]*\.zip", name):
    raise SystemExit("invalid macOS archive name")
if name != macos.get("asset"):
    raise SystemExit("macOS snapshot asset mismatch")
if not isinstance(size, int) or size <= 0 or size > 2 * 1024 * 1024 * 1024:
    raise SystemExit("invalid macOS archive size")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("invalid macOS archive digest")
if not isinstance(version, str) or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", version):
    raise SystemExit("invalid macOS version")
if not isinstance(build, str) or not re.fullmatch(r"[0-9]+", build):
    raise SystemExit("invalid macOS build")
print(tag)
print(name)
print(size)
print(digest)
print(version)
print(build)
PY

IFS= read -r release_tag < "$metadata_path"
IFS= read -r asset_name < <(sed -n '2p' "$metadata_path")
IFS= read -r expected_size < <(sed -n '3p' "$metadata_path")
IFS= read -r expected_sha256 < <(sed -n '4p' "$metadata_path")
IFS= read -r expected_version < <(sed -n '5p' "$metadata_path")
IFS= read -r expected_build < <(sed -n '6p' "$metadata_path")

download_dir="$work_dir/download"
extract_dir="$work_dir/extracted"
mkdir -m 700 "$download_dir" "$extract_dir"
gh release download "$release_tag" \
  --repo "$REPOSITORY" \
  --pattern "$asset_name" \
  --dir "$download_dir"

archive_path="$download_dir/$asset_name"
if [[ ! -f "$archive_path" ]]; then
  echo "error=published macOS archive was not downloaded" >&2
  exit 1
fi
actual_size="$(stat -f '%z' "$archive_path")"
actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_size" != "$expected_size" || "$actual_sha256" != "$expected_sha256" ]]; then
  echo "error=published macOS archive differs from verified snapshot" >&2
  exit 1
fi

ditto -x -k "$archive_path" "$extract_dir"
app_path="$extract_dir/HoverPocket.app"
if [[ ! -d "$app_path" ]]; then
  echo "error=HoverPocket.app not found in published archive" >&2
  exit 1
fi
if find "$extract_dir" -mindepth 1 -maxdepth 1 ! -name 'HoverPocket.app' -print -quit | grep -q .; then
  echo "error=published archive has an unexpected top-level payload" >&2
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  echo "error=published app Info.plist not found" >&2
  exit 1
fi
actual_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
if [[ "$actual_bundle_identifier" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  echo "error=published app bundle identifier differs from HoverPocket" >&2
  exit 1
fi
if [[ "$actual_version" != "$expected_version" || "$actual_build" != "$expected_build" ]]; then
  echo "error=published app version or build differs from appcast" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

release_json="$work_dir/release.json"
gh api "repos/$REPOSITORY/releases/tags/$release_tag" > "$release_json"
python3 - "$release_json" "$asset_name" "$expected_size" "$expected_sha256" <<'PY'
import json
import pathlib
import sys

release = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
name, expected_size, expected_sha256 = sys.argv[2], int(sys.argv[3]), sys.argv[4]
matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
if len(matches) != 1:
    raise SystemExit("published macOS asset cardinality changed")
asset = matches[0]
if asset.get("size") != expected_size or asset.get("digest") != f"sha256:{expected_sha256}":
    raise SystemExit("published macOS asset metadata changed during verification")
PY

python3 - "$OUTPUT_PATH" "$release_tag" "$asset_name" "$actual_size" "$actual_sha256" "$actual_bundle_identifier" "$actual_version" "$actual_build" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
report = {
    "status": "passed",
    "releaseTag": sys.argv[2],
    "asset": {
        "name": sys.argv[3],
        "size": int(sys.argv[4]),
        "sha256": sys.argv[5],
    },
    "codesign": "verified-deep-strict",
    "notarization": "stapled-ticket-validated",
    "gatekeeper": "accepted",
    "bundleIdentifier": sys.argv[6],
    "version": sys.argv[7],
    "build": sys.argv[8],
    "snapshotReadback": "release-metadata-rechecked",
}
path.write_text(json.dumps(report, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
PY
