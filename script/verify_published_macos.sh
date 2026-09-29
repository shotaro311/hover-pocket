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
EXPECTED_SPARKLE_FEED_URL="https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml"
EXPECTED_SPARKLE_PUBLIC_ED_KEY="J2afuh/KnvOiS3eoNrMJoCyldAXL+Oku9scoSS5OUJE="
EXPECTED_TEAM_IDENTIFIER="N7VVPW44ZA"

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
if (
    not isinstance(snapshot, dict)
    or snapshot.get("versionedReleaseTag") != macos.get("releaseTag")
    or snapshot.get("feedReleaseTag") != macos.get("feedTag")
):
    raise SystemExit("macOS snapshot release tag mismatch")
assets = snapshot.get("assets")
if not isinstance(assets, list) or len(assets) != 6 or not all(isinstance(asset, dict) for asset in assets):
    raise SystemExit("macOS snapshot must contain exactly six assets")
by_role = {asset.get("role"): asset for asset in assets}
if set(by_role) != {
    "versionedSparkle",
    "feedManual",
    "versionedManual",
    "feedAppcast",
    "versionedAppcast",
    "versionedChecksum",
}:
    raise SystemExit("macOS snapshot roles are missing or duplicated")
versioned_tag = snapshot["versionedReleaseTag"]
feed_tag = snapshot["feedReleaseTag"]
version = macos.get("version")
build = macos.get("build")
if not isinstance(versioned_tag, str) or not re.fullmatch(r"v[0-9A-Za-z][0-9A-Za-z._+-]*", versioned_tag):
    raise SystemExit("invalid macOS release tag")
if not isinstance(feed_tag, str) or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", feed_tag):
    raise SystemExit("invalid macOS feed tag")
expected = {
    "versionedSparkle": (versioned_tag, macos.get("asset")),
    "feedManual": (feed_tag, "HoverPocket-macOS-app.zip"),
    "versionedManual": (versioned_tag, "HoverPocket-macOS-app.zip"),
    "feedAppcast": (feed_tag, "appcast.xml"),
    "versionedAppcast": (versioned_tag, "appcast.xml"),
    "versionedChecksum": (versioned_tag, f"{macos.get('asset')}.sha256"),
}
for role, (release_tag, expected_name) in expected.items():
    asset = by_role[role]
    if asset.get("releaseTag") != release_tag or asset.get("name") != expected_name:
        raise SystemExit(f"macOS {role} snapshot identity mismatch")
    size = asset.get("size")
    digest = asset.get("sha256")
    if not isinstance(size, int) or size <= 0 or size > 2 * 1024 * 1024 * 1024:
        raise SystemExit(f"invalid macOS {role} asset size")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit(f"invalid macOS {role} asset digest")
archive_roles = ("versionedSparkle", "feedManual", "versionedManual")
if len({(by_role[role]["size"], by_role[role]["sha256"]) for role in archive_roles}) != 1:
    raise SystemExit("macOS manual and Sparkle archives differ")
if not isinstance(version, str) or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", version):
    raise SystemExit("invalid macOS version")
if not isinstance(build, str) or not re.fullmatch(r"[0-9]+", build):
    raise SystemExit("invalid macOS build")
print(versioned_tag)
print(feed_tag)
for role in (
    "versionedSparkle",
    "feedManual",
    "versionedManual",
    "feedAppcast",
    "versionedAppcast",
    "versionedChecksum",
):
    asset = by_role[role]
    print(asset["name"])
    print(asset["size"])
    print(asset["sha256"])
print(version)
print(build)
PY

IFS= read -r versioned_release_tag < "$metadata_path"
IFS= read -r feed_release_tag < <(sed -n '2p' "$metadata_path")
IFS= read -r asset_name < <(sed -n '3p' "$metadata_path")
IFS= read -r expected_size < <(sed -n '4p' "$metadata_path")
IFS= read -r expected_sha256 < <(sed -n '5p' "$metadata_path")
IFS= read -r feed_manual_name < <(sed -n '6p' "$metadata_path")
IFS= read -r feed_manual_size < <(sed -n '7p' "$metadata_path")
IFS= read -r feed_manual_sha256 < <(sed -n '8p' "$metadata_path")
IFS= read -r versioned_manual_name < <(sed -n '9p' "$metadata_path")
IFS= read -r versioned_manual_size < <(sed -n '10p' "$metadata_path")
IFS= read -r versioned_manual_sha256 < <(sed -n '11p' "$metadata_path")
IFS= read -r feed_appcast_name < <(sed -n '12p' "$metadata_path")
IFS= read -r feed_appcast_size < <(sed -n '13p' "$metadata_path")
IFS= read -r feed_appcast_sha256 < <(sed -n '14p' "$metadata_path")
IFS= read -r versioned_appcast_name < <(sed -n '15p' "$metadata_path")
IFS= read -r versioned_appcast_size < <(sed -n '16p' "$metadata_path")
IFS= read -r versioned_appcast_sha256 < <(sed -n '17p' "$metadata_path")
IFS= read -r versioned_checksum_name < <(sed -n '18p' "$metadata_path")
IFS= read -r versioned_checksum_size < <(sed -n '19p' "$metadata_path")
IFS= read -r versioned_checksum_sha256 < <(sed -n '20p' "$metadata_path")
IFS= read -r expected_version < <(sed -n '21p' "$metadata_path")
IFS= read -r expected_build < <(sed -n '22p' "$metadata_path")

download_dir="$work_dir/download"
extract_dir="$work_dir/extracted"
mkdir -m 700 "$download_dir" "$extract_dir"
downloaded_path=""
download_and_verify() {
  local release_tag="$1"
  local name="$2"
  local size="$3"
  local digest="$4"
  local role="$5"
  local role_dir="$download_dir/$role"
  mkdir -m 700 "$role_dir"
  gh release download "$release_tag" \
    --repo "$REPOSITORY" \
    --pattern "$name" \
    --dir "$role_dir"
  downloaded_path="$role_dir/$name"
  if [[ ! -f "$downloaded_path" ]]; then
    echo "error=published macOS $role archive was not downloaded" >&2
    exit 1
  fi
  local actual_size
  local actual_sha256
  actual_size="$(stat -f '%z' "$downloaded_path")"
  actual_sha256="$(shasum -a 256 "$downloaded_path" | awk '{print $1}')"
  if [[ "$actual_size" != "$size" || "$actual_sha256" != "$digest" ]]; then
    echo "error=published macOS $role archive differs from verified snapshot" >&2
    exit 1
  fi
}

download_and_verify "$versioned_release_tag" "$asset_name" "$expected_size" "$expected_sha256" "versioned-sparkle"
archive_path="$downloaded_path"
download_and_verify "$feed_release_tag" "$feed_manual_name" "$feed_manual_size" "$feed_manual_sha256" "feed-manual"
feed_manual_path="$downloaded_path"
download_and_verify "$versioned_release_tag" "$versioned_manual_name" "$versioned_manual_size" "$versioned_manual_sha256" "versioned-manual"
versioned_manual_path="$downloaded_path"
download_and_verify "$feed_release_tag" "$feed_appcast_name" "$feed_appcast_size" "$feed_appcast_sha256" "feed-appcast"
feed_appcast_path="$downloaded_path"
download_and_verify "$versioned_release_tag" "$versioned_appcast_name" "$versioned_appcast_size" "$versioned_appcast_sha256" "versioned-appcast"
versioned_appcast_path="$downloaded_path"
download_and_verify "$versioned_release_tag" "$versioned_checksum_name" "$versioned_checksum_size" "$versioned_checksum_sha256" "versioned-checksum"
if ! cmp -s "$archive_path" "$feed_manual_path" || ! cmp -s "$archive_path" "$versioned_manual_path"; then
  echo "error=public macOS manual and Sparkle archives are not byte-identical" >&2
  exit 1
fi
if ! cmp -s "$feed_appcast_path" "$versioned_appcast_path"; then
  echo "error=public macOS feed and versioned appcasts are not byte-identical" >&2
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
actual_sparkle_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")"
actual_sparkle_public_ed_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")"
if [[ "$actual_bundle_identifier" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  echo "error=published app bundle identifier differs from HoverPocket" >&2
  exit 1
fi
if [[ "$actual_version" != "$expected_version" || "$actual_build" != "$expected_build" ]]; then
  echo "error=published app version or build differs from appcast" >&2
  exit 1
fi
if [[ "$actual_sparkle_feed_url" != "$EXPECTED_SPARKLE_FEED_URL" ]]; then
  echo "error=published app Sparkle feed URL differs from the canonical macOS feed" >&2
  exit 1
fi
if [[ "$actual_sparkle_public_ed_key" != "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "error=published app Sparkle public key differs from the release verification key" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign_details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
actual_team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<< "$codesign_details")"
if [[ "$actual_team_identifier" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
  echo "error=published app Developer ID team differs from HoverPocket" >&2
  exit 1
fi
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

versioned_release_json="$work_dir/versioned-release.json"
feed_release_json="$work_dir/feed-release.json"
gh api "repos/$REPOSITORY/releases/tags/$versioned_release_tag" > "$versioned_release_json"
gh api "repos/$REPOSITORY/releases/tags/$feed_release_tag" > "$feed_release_json"
python3 - "$EXPECTED_REPORT" "$versioned_release_json" "$feed_release_json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
versioned_release = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
feed_release = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
snapshot = report["macos"]["assetSnapshot"]
releases = {
    snapshot["versionedReleaseTag"]: versioned_release,
    snapshot["feedReleaseTag"]: feed_release,
}
for expected in snapshot["assets"]:
    release = releases[expected["releaseTag"]]
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == expected["name"]]
    if len(matches) != 1:
        raise SystemExit(f"published macOS {expected['role']} asset cardinality changed")
    asset = matches[0]
    if asset.get("size") != expected["size"] or asset.get("digest") != f"sha256:{expected['sha256']}":
        raise SystemExit(f"published macOS {expected['role']} metadata changed during verification")
PY

python3 - "$OUTPUT_PATH" "$EXPECTED_REPORT" "$actual_bundle_identifier" "$actual_version" "$actual_build" "$actual_sparkle_feed_url" "$actual_team_identifier" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))["macos"]
report = {
    "status": "passed",
    "versionedReleaseTag": source["assetSnapshot"]["versionedReleaseTag"],
    "feedReleaseTag": source["assetSnapshot"]["feedReleaseTag"],
    "assets": source["assetSnapshot"]["assets"],
    "codesign": "verified-deep-strict",
    "notarization": "stapled-ticket-validated",
    "gatekeeper": "accepted",
    "bundleIdentifier": sys.argv[3],
    "version": sys.argv[4],
    "build": sys.argv[5],
    "sparkleFeedURL": sys.argv[6],
    "sparklePublicKey": "verified",
    "teamIdentifier": sys.argv[7],
    "manualArchiveParity": "byte-identical",
    "appcastParity": "byte-identical",
    "snapshotReadback": "all-release-metadata-rechecked",
}
path.write_text(json.dumps(report, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
PY
