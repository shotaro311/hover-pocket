#!/usr/bin/env python3
"""Verify HoverPocket's published macOS and Windows release surfaces.

The verifier intentionally reads the two operating-system release channels
independently. GitHub's generic ``latest`` endpoint is read only to assert that
Windows publication did not replace the macOS release; it is never used for
release selection.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Any


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DEFAULT_SPARKLE_PUBLIC_KEY = "J2afuh/KnvOiS3eoNrMJoCyldAXL+Oku9scoSS5OUJE="
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RELEASE_DOWNLOAD_RE = re.compile(r"/releases/download/([^/]+)/([^/?#]+)$")
WINDOWS_REQUIRED_STATIC_ASSETS = {
    "RELEASES",
    "assets.win.json",
    "release-manifest.win.json",
    "releases.win.json",
    "SHA256SUMS-win.txt",
}
WINDOWS_TAG_RE = re.compile(r"^win-v(\d+)\.(\d+)\.(\d+)$")
MAX_RELEASE_ASSET_BYTES = 512 * 1024 * 1024


class VerificationError(RuntimeError):
    pass


@dataclass(frozen=True)
class MacAppcast:
    version: str
    build: str
    asset_url: str
    asset_name: str
    asset_length: int
    signature: str
    release_tag: str


@dataclass(frozen=True)
class DownloadedAsset:
    name: str
    path: pathlib.Path
    size: int
    sha256: str
    sha1: str


class Verifier:
    def __init__(self) -> None:
        self.checks: list[str] = []

    def require(self, condition: bool, name: str, detail: str) -> None:
        if not condition:
            raise VerificationError(f"{name}: {detail}")
        self.checks.append(name)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.startswith("sha256:"):
        raise VerificationError(f"{field}: missing GitHub sha256 digest")
    digest = value.removeprefix("sha256:").lower()
    if not SHA256_RE.fullmatch(digest):
        raise VerificationError(f"{field}: invalid GitHub sha256 digest")
    return digest


def asset_map(release: dict[str, Any]) -> dict[str, dict[str, Any]]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise VerificationError("release.assets: expected an array")
    result: dict[str, dict[str, Any]] = {}
    for item in assets:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            raise VerificationError("release.assets: malformed asset")
        name = item["name"]
        if name in {"", ".", ".."} or "/" in name or "\\" in name:
            raise VerificationError(f"release.assets: invalid asset name {name!r}")
        if name in result:
            raise VerificationError(f"release.assets: duplicate asset {name}")
        result[name] = item
    return result


def parse_sha256_sums(data: bytes, *, allow_path_basename: bool = False) -> dict[str, str]:
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise VerificationError("checksums: file must be ASCII") from error
    result: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        match = re.fullmatch(r"([0-9A-Fa-f]{64})  ([^\r\n]+)", raw_line)
        if match is None:
            raise VerificationError(f"checksums:{line_number}: malformed line")
        digest, raw_name = match.group(1).lower(), match.group(2)
        if "/" in raw_name or "\\" in raw_name:
            if not allow_path_basename:
                raise VerificationError(f"checksums:{line_number}: paths are not allowed")
            name = raw_name.replace("\\", "/").rsplit("/", 1)[-1]
        else:
            name = raw_name
        if name in {"", ".", ".."}:
            raise VerificationError(f"checksums:{line_number}: invalid name")
        if name in result:
            raise VerificationError(f"checksums:{line_number}: duplicate {name}")
        result[name] = digest
    if not result:
        raise VerificationError("checksums: no entries")
    return result


def parse_appcast(data: bytes, repository: str) -> MacAppcast:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise VerificationError("macos.appcast: invalid XML") from error
    item = root.find("./channel/item")
    enclosure = root.find("./channel/item/enclosure")
    if item is None or enclosure is None:
        raise VerificationError("macos.appcast: missing enclosure")
    asset_url = enclosure.get("url") or ""
    parsed = urllib.parse.urlparse(asset_url)
    expected_prefix = f"/{repository}/releases/download/"
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith(expected_prefix)
    ):
        raise VerificationError("macos.appcast: enclosure is not the expected GitHub repository")
    match = RELEASE_DOWNLOAD_RE.search(parsed.path)
    if match is None:
        raise VerificationError("macos.appcast: cannot derive versioned release tag")
    release_tag = urllib.parse.unquote(match.group(1))
    asset_name = urllib.parse.unquote(match.group(2))
    build = (
        enclosure.get(f"{{{SPARKLE_NS}}}version")
        or item.findtext(f"{{{SPARKLE_NS}}}version")
        or ""
    )
    version = (
        enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString")
        or item.findtext(f"{{{SPARKLE_NS}}}shortVersionString")
        or ""
    )
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature") or ""
    try:
        asset_length = int(enclosure.get("length") or "0")
    except ValueError as error:
        raise VerificationError("macos.appcast: invalid enclosure length") from error
    if not version or not build or asset_length <= 0:
        raise VerificationError("macos.appcast: incomplete version or length metadata")
    decode_fixed_base64(signature, expected_length=64, field="macos.appcast_ed_signature")
    return MacAppcast(
        version=version,
        build=build,
        asset_url=asset_url,
        asset_name=asset_name,
        asset_length=asset_length,
        signature=signature,
        release_tag=release_tag,
    )


def decode_fixed_base64(value: str, *, expected_length: int, field: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise VerificationError(f"{field}: invalid base64 encoding") from error
    if len(decoded) != expected_length:
        raise VerificationError(f"{field}: expected {expected_length} bytes")
    return decoded


def verify_ed25519_signature(
    public_key_base64: str,
    signature_base64: str,
    message_path: pathlib.Path,
) -> None:
    """Verify Sparkle's Ed25519 signature over the exact downloaded archive."""

    public_key = decode_fixed_base64(
        public_key_base64,
        expected_length=32,
        field="macos.sparkle_public_key",
    )
    signature = decode_fixed_base64(
        signature_base64,
        expected_length=64,
        field="macos.sparkle_signature",
    )
    if not message_path.is_file():
        raise VerificationError("macos.sparkle_signature: downloaded archive is missing")

    # RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
    public_key_der = bytes.fromhex("302a300506032b6570032100") + public_key
    try:
        with tempfile.TemporaryDirectory(prefix="hoverpocket-ed25519-") as directory:
            directory_path = pathlib.Path(directory)
            key_path = directory_path / "public-key.der"
            signature_path = directory_path / "signature.bin"
            key_path.write_bytes(public_key_der)
            signature_path.write_bytes(signature)
            try:
                result = subprocess.run(
                    [
                        "openssl",
                        "pkeyutl",
                        "-verify",
                        "-pubin",
                        "-inkey",
                        str(key_path),
                        "-keyform",
                        "DER",
                        "-rawin",
                        "-in",
                        str(message_path),
                        "-sigfile",
                        str(signature_path),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                    check=False,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired) as error:
                raise VerificationError("macos.sparkle_signature: OpenSSL verification is unavailable") from error
    except OSError as error:
        raise VerificationError("macos.sparkle_signature: could not prepare verification") from error
    if result.returncode != 0:
        raise VerificationError("macos.sparkle_signature: signature does not match downloaded archive")


def validate_macos(
    verifier: Verifier,
    repository: str,
    feed_release: dict[str, Any],
    feed_appcast: bytes,
    version_release: dict[str, Any],
    version_appcast: bytes,
    checksum_data: bytes,
) -> MacAppcast:
    appcast = parse_appcast(feed_appcast, repository)
    verifier.require(feed_release.get("tag_name") == "macos-latest", "macos.feed_tag", "feed tag is not macos-latest")
    verifier.require(version_release.get("tag_name") == appcast.release_tag, "macos.version_tag", "appcast tag and release tag differ")
    verifier.require(
        appcast.release_tag == f"v{appcast.version}-{appcast.build}",
        "macos.release_identity",
        "versioned tag does not match appcast version and build",
    )
    verifier.require(
        appcast.asset_name == f"HoverPocket-{appcast.version}-{appcast.build}.zip",
        "macos.asset_identity",
        "appcast archive name does not match version and build",
    )
    feed_assets = asset_map(feed_release)
    version_assets = asset_map(version_release)
    verifier.require(
        {"appcast.xml", "HoverPocket-macOS-app.zip"}.issubset(feed_assets),
        "macos.feed_assets",
        "stable feed is missing appcast or manual install ZIP",
    )
    required_version_assets = {
        "appcast.xml",
        "HoverPocket-macOS-app.zip",
        appcast.asset_name,
        f"{appcast.asset_name}.sha256",
    }
    verifier.require(required_version_assets.issubset(version_assets), "macos.version_assets", "versioned release is incomplete")
    verifier.require(feed_appcast == version_appcast, "macos.appcast_parity", "stable and versioned appcasts differ")
    verifier.require(
        parse_digest(feed_assets["appcast.xml"].get("digest"), "macos.feed_appcast") == sha256(feed_appcast),
        "macos.feed_appcast_digest",
        "stable appcast digest differs from GitHub metadata",
    )
    version_zip = version_assets[appcast.asset_name]
    zip_digest = parse_digest(version_zip.get("digest"), "macos.version_zip")
    checksum_entries = parse_sha256_sums(checksum_data, allow_path_basename=True)
    verifier.require(checksum_entries.get(appcast.asset_name) == zip_digest, "macos.zip_checksum", "ZIP checksum file differs")
    verifier.require(version_zip.get("size") == appcast.asset_length, "macos.zip_length", "appcast length differs from release asset")
    verifier.require(
        parse_digest(feed_assets["HoverPocket-macOS-app.zip"].get("digest"), "macos.feed_manual_zip") == zip_digest,
        "macos.manual_zip_parity",
        "stable manual ZIP differs from versioned ZIP",
    )
    verifier.require(
        parse_digest(version_assets["appcast.xml"].get("digest"), "macos.version_appcast") == sha256(version_appcast),
        "macos.version_appcast_digest",
        "versioned appcast digest differs from GitHub metadata",
    )
    verifier.require(
        parse_digest(version_assets[f"{appcast.asset_name}.sha256"].get("digest"), "macos.checksum_file")
        == sha256(checksum_data),
        "macos.checksum_file_digest",
        "checksum file differs from GitHub metadata",
    )
    verifier.require(
        len(decode_fixed_base64(appcast.signature, expected_length=64, field="macos.sparkle_signature")) == 64,
        "macos.sparkle_signature_format",
        "invalid Sparkle signature",
    )
    return appcast


def validate_windows(
    verifier: Verifier,
    release: dict[str, Any],
    feed_data: bytes,
    manifest_data: bytes,
    checksum_data: bytes,
    signing_gate: str,
) -> tuple[str, str]:
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not tag.startswith("win-v"):
        raise VerificationError("windows.release_tag: expected win-v... tag")
    verifier.require(
        release.get("draft") is not True and release.get("prerelease") is not True,
        "windows.published_release",
        "Windows client channel excludes draft and prerelease releases",
    )
    assets = asset_map(release)
    verifier.require(WINDOWS_REQUIRED_STATIC_ASSETS.issubset(assets), "windows.static_assets", "release metadata is incomplete")
    checksums = parse_sha256_sums(checksum_data)
    expected_checksum_names = set(assets) - {"SHA256SUMS-win.txt"}
    verifier.require(set(checksums) == expected_checksum_names, "windows.checksum_coverage", "checksum list does not exactly cover release assets")
    for name, digest in checksums.items():
        verifier.require(
            parse_digest(assets[name].get("digest"), f"windows.asset.{name}") == digest,
            f"windows.digest.{name}",
            "checksum differs from GitHub metadata",
        )
    try:
        feed = json.loads(feed_data)
        manifest = json.loads(manifest_data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError("windows.metadata: invalid JSON") from error
    feed_assets = feed.get("Assets") if isinstance(feed, dict) else None
    if not isinstance(feed_assets, list) or len(feed_assets) != 1 or not isinstance(feed_assets[0], dict):
        raise VerificationError("windows.feed: expected one full package")
    package = feed_assets[0]
    version = manifest.get("version") if isinstance(manifest, dict) else None
    package_name = package.get("FileName")
    verifier.require(manifest.get("schemaVersion") == 1, "windows.manifest_schema", "unsupported manifest schema")
    verifier.require(manifest.get("product") == "HoverPocket", "windows.product", "unexpected product")
    verifier.require(manifest.get("packageId") == "HoverPocketWin", "windows.package_id", "unexpected package ID")
    verifier.require(manifest.get("runtime") == "win-x64", "windows.runtime", "unexpected runtime")
    verifier.require(manifest.get("updateChannel") == "win", "windows.channel", "unexpected update channel")
    verifier.require(manifest.get("updateFeed") == "releases.win.json", "windows.feed_name", "unexpected feed name")
    verifier.require(manifest.get("oauthMetadata") == "embedded-and-verified", "windows.oauth_metadata", "OAuth metadata was not verified at packaging")
    verifier.require(tag == f"win-v{version}", "windows.version_tag", "manifest version and release tag differ")
    verifier.require(package.get("Version") == version, "windows.feed_version", "feed and manifest versions differ")
    verifier.require(package.get("PackageId") == "HoverPocketWin", "windows.feed_package", "feed package ID differs")
    verifier.require(package.get("Type") == "Full", "windows.feed_type", "feed is not a full package")
    verifier.require(
        isinstance(package_name, str) and package_name == f"HoverPocketWin-{version}-full.nupkg",
        "windows.feed_full_package_name",
        "feed target is not the versioned full update package",
    )
    verifier.require(isinstance(package_name, str) and package_name in assets, "windows.feed_asset", "feed package asset is missing")
    verifier.require(
        isinstance(package.get("SHA256"), str)
        and package["SHA256"].lower() == checksums.get(package_name),
        "windows.feed_digest",
        "feed package checksum differs",
    )
    verifier.require(package.get("Size") == assets[package_name].get("size"), "windows.feed_size", "feed package size differs")
    verifier.require(
        isinstance(package.get("SHA1"), str) and re.fullmatch(r"[0-9A-Fa-f]{40}", package["SHA1"]) is not None,
        "windows.feed_sha1_format",
        "feed package SHA-1 is missing or malformed",
    )
    verifier.require(any(name.endswith("-Setup.exe") for name in assets), "windows.setup_asset", "Setup executable is missing")
    verifier.require(any(name.endswith("-Portable.zip") for name in assets), "windows.portable_asset", "Portable ZIP is missing")
    authenticode = manifest.get("authenticode")
    if signing_gate == "formal":
        verifier.require(
            authenticode == "signed-timestamped-verified",
            "windows.authenticode_formal",
            "formal release requires timestamped Authenticode readback",
        )
    else:
        verifier.require(authenticode in {"unsigned", "signed-timestamped-verified"}, "windows.authenticode_beta", "unknown signing state")
    return str(version), str(authenticode)


class GitHubReader:
    def __init__(self, repository: str) -> None:
        self.repository = repository
        self.token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    @staticmethod
    def _require_github_response(url: str, final_url: str) -> None:
        requested = urllib.parse.urlparse(url)
        final = urllib.parse.urlparse(final_url)
        requested_host = requested.hostname or ""
        final_host = final.hostname or ""
        if requested.scheme != "https" or requested_host not in {"api.github.com", "github.com"}:
            raise VerificationError(f"network: unexpected source host for {url}")
        if (
            final.scheme != "https"
            or final.username is not None
            or final.password is not None
            or final.port is not None
            or not (final_host in {"api.github.com", "github.com"} or final_host.endswith(".githubusercontent.com"))
        ):
            raise VerificationError(f"network: unexpected redirect for {url}")

    def bytes(self, url: str, limit: int = 8 * 1024 * 1024) -> bytes:
        headers = {"User-Agent": "HoverPocket-release-readback/1"}
        if self.token and urllib.parse.urlparse(url).netloc == "api.github.com":
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                self._require_github_response(url, response.geturl())
                data = response.read(limit + 1)
        except (urllib.error.URLError, TimeoutError) as error:
            raise VerificationError(f"network: failed to read {url}") from error
        if len(data) > limit:
            raise VerificationError(f"network: response too large for {url}")
        return data

    def json(self, url: str) -> dict[str, Any]:
        try:
            value = json.loads(self.bytes(url).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise VerificationError(f"network: invalid JSON from {url}") from error
        if not isinstance(value, dict):
            raise VerificationError(f"network: expected JSON object from {url}")
        return value

    def release(self, tag: str) -> dict[str, Any]:
        encoded_tag = urllib.parse.quote(tag, safe="")
        return self.json(f"https://api.github.com/repos/{self.repository}/releases/tags/{encoded_tag}")

    def latest_release(self) -> dict[str, Any]:
        return self.json(f"https://api.github.com/repos/{self.repository}/releases/latest")

    def latest_windows_release(self) -> dict[str, Any]:
        candidates: list[tuple[tuple[int, int, int], dict[str, Any]]] = []
        for page in range(1, 11):
            value = json.loads(
                self.bytes(
                    f"https://api.github.com/repos/{self.repository}/releases?per_page=100&page={page}"
                ).decode("utf-8")
            )
            if not isinstance(value, list):
                raise VerificationError("windows.release_discovery: expected an array")
            for item in value:
                if (
                    not isinstance(item, dict)
                    or item.get("draft") is True
                    or item.get("prerelease") is True
                ):
                    continue
                tag = item.get("tag_name")
                match = WINDOWS_TAG_RE.fullmatch(tag) if isinstance(tag, str) else None
                if match is not None:
                    candidates.append((tuple(int(part) for part in match.groups()), item))
            if len(value) < 100:
                break
        else:
            raise VerificationError("windows.release_discovery: release history exceeds supported pagination")
        if not candidates:
            raise VerificationError("windows.release_discovery: no win-v... release found")
        return max(candidates, key=lambda pair: pair[0])[1]

    def asset(self, release: dict[str, Any], name: str, limit: int = 8 * 1024 * 1024) -> bytes:
        item = asset_map(release).get(name)
        if item is None or not isinstance(item.get("browser_download_url"), str):
            raise VerificationError(f"release.asset: missing {name}")
        return self.bytes(item["browser_download_url"], limit=limit)

    def download_asset(
        self,
        release: dict[str, Any],
        name: str,
        destination: pathlib.Path,
    ) -> DownloadedAsset:
        item = asset_map(release).get(name)
        if item is None or not isinstance(item.get("browser_download_url"), str):
            raise VerificationError(f"release.asset: missing {name}")
        expected_size = item.get("size")
        if not isinstance(expected_size, int) or expected_size < 0 or expected_size > MAX_RELEASE_ASSET_BYTES:
            raise VerificationError(f"release.asset: invalid size for {name}")
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        output_path = destination / name
        if output_path.exists():
            raise VerificationError(f"release.asset: duplicate download target {name}")

        headers = {"User-Agent": "HoverPocket-release-readback/1"}
        request = urllib.request.Request(item["browser_download_url"], headers=headers)
        sha256_hash = hashlib.sha256()
        sha1_hash = hashlib.sha1()
        size = 0
        try:
            with urllib.request.urlopen(request, timeout=60) as response, output_path.open("xb") as output:
                self._require_github_response(item["browser_download_url"], response.geturl())
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > expected_size or size > MAX_RELEASE_ASSET_BYTES:
                        raise VerificationError(f"release.asset: response too large for {name}")
                    sha256_hash.update(chunk)
                    sha1_hash.update(chunk)
                    output.write(chunk)
        except VerificationError:
            output_path.unlink(missing_ok=True)
            raise
        except (OSError, urllib.error.URLError, TimeoutError) as error:
            output_path.unlink(missing_ok=True)
            raise VerificationError(f"network: failed to download {name}") from error
        if size != expected_size:
            output_path.unlink(missing_ok=True)
            raise VerificationError(f"release.asset: downloaded size differs for {name}")
        return DownloadedAsset(
            name=name,
            path=output_path,
            size=size,
            sha256=sha256_hash.hexdigest(),
            sha1=sha1_hash.hexdigest(),
        )


def resolve_windows_release(
    reader: GitHubReader,
    requested_tag: str,
) -> dict[str, Any]:
    if requested_tag == "auto":
        release = reader.latest_windows_release()
    else:
        if WINDOWS_TAG_RE.fullmatch(requested_tag) is None:
            raise VerificationError("windows.release_tag: expected win-vMAJOR.MINOR.PATCH")
        release = reader.release(requested_tag)

    tag = release.get("tag_name")
    if not isinstance(tag, str) or WINDOWS_TAG_RE.fullmatch(tag) is None:
        raise VerificationError("windows.release_tag: expected win-vMAJOR.MINOR.PATCH")
    if release.get("draft") is True or release.get("prerelease") is True:
        raise VerificationError("windows.published_release: release must be published and non-prerelease")
    return release


def require_download_matches_release(
    verifier: Verifier,
    release: dict[str, Any],
    downloaded: DownloadedAsset,
    check_prefix: str,
) -> None:
    item = asset_map(release).get(downloaded.name)
    if item is None:
        raise VerificationError(f"{check_prefix}: downloaded asset is absent from release")
    verifier.require(
        downloaded.size == item.get("size"),
        f"{check_prefix}.size",
        "downloaded size differs from GitHub metadata",
    )
    verifier.require(
        downloaded.sha256 == parse_digest(item.get("digest"), check_prefix),
        f"{check_prefix}.sha256",
        "downloaded SHA-256 differs from GitHub metadata",
    )


def require_windows_downloads(
    verifier: Verifier,
    release: dict[str, Any],
    checksum_data: bytes,
    feed_data: bytes,
    downloads: dict[str, DownloadedAsset],
) -> None:
    assets = asset_map(release)
    verifier.require(set(downloads) == set(assets), "windows.download_coverage", "not every public asset was downloaded")
    checksums = parse_sha256_sums(checksum_data)
    for name, downloaded in downloads.items():
        require_download_matches_release(verifier, release, downloaded, f"windows.download.{name}")
        if name != "SHA256SUMS-win.txt":
            verifier.require(
                downloaded.sha256 == checksums.get(name),
                f"windows.download_checksum.{name}",
                "downloaded SHA-256 differs from checksum file",
            )
    verifier.require(
        downloads["SHA256SUMS-win.txt"].sha256
        == parse_digest(assets["SHA256SUMS-win.txt"].get("digest"), "windows.checksum_file"),
        "windows.checksum_file_digest",
        "downloaded checksum file differs from GitHub metadata",
    )
    try:
        feed = json.loads(feed_data)
        package = feed["Assets"][0]
        package_name = package["FileName"]
        expected_sha1 = package["SHA1"].lower()
    except (KeyError, IndexError, TypeError, json.JSONDecodeError, UnicodeDecodeError) as error:
        raise VerificationError("windows.feed_sha1: malformed feed") from error
    verifier.require(
        downloads[package_name].sha1 == expected_sha1,
        "windows.feed_sha1",
        "downloaded package SHA-1 differs from update feed",
    )


def require_macos_downloads(
    verifier: Verifier,
    mac_feed_release: dict[str, Any],
    mac_version_release: dict[str, Any],
    appcast: MacAppcast,
    checksum_data: bytes,
    version_zip: DownloadedAsset,
    stable_manual_zip: DownloadedAsset,
    version_manual_zip: DownloadedAsset,
) -> None:
    require_download_matches_release(
        verifier,
        mac_version_release,
        version_zip,
        "macos.download.version_zip",
    )
    require_download_matches_release(
        verifier,
        mac_feed_release,
        stable_manual_zip,
        "macos.download.stable_manual_zip",
    )
    require_download_matches_release(
        verifier,
        mac_version_release,
        version_manual_zip,
        "macos.download.version_manual_zip",
    )
    mac_checksums = parse_sha256_sums(checksum_data, allow_path_basename=True)
    verifier.require(
        version_zip.sha256 == mac_checksums.get(appcast.asset_name),
        "macos.download.zip_checksum",
        "downloaded ZIP differs from checksum file",
    )
    verifier.require(
        version_zip.size == appcast.asset_length,
        "macos.download.zip_length",
        "downloaded ZIP length differs from appcast",
    )
    verifier.require(
        (stable_manual_zip.sha256, stable_manual_zip.size)
        == (version_zip.sha256, version_zip.size),
        "macos.download.stable_manual_zip_parity",
        "stable manual ZIP differs from versioned Sparkle ZIP",
    )
    verifier.require(
        (version_manual_zip.sha256, version_manual_zip.size)
        == (version_zip.sha256, version_zip.size),
        "macos.download.version_manual_zip_parity",
        "versioned manual ZIP differs from versioned Sparkle ZIP",
    )


def validate_cross_platform_release_policy(
    verifier: Verifier,
    macos_release_tag: str,
    windows_release_tag: str,
    github_latest_release: dict[str, Any],
) -> None:
    verifier.require(
        macos_release_tag != windows_release_tag,
        "cross_platform.release_tags_separate",
        "macOS and Windows release tags must be separate",
    )
    verifier.require(
        github_latest_release.get("draft") is not True
        and github_latest_release.get("prerelease") is not True,
        "cross_platform.github_latest_published",
        "GitHub Latest must be a published non-prerelease",
    )
    verifier.require(
        github_latest_release.get("tag_name") == macos_release_tag,
        "cross_platform.github_latest_is_macos",
        "Windows release replaced the expected macOS GitHub Latest release",
    )


def verify_downloaded_releases(
    verifier: Verifier,
    reader: GitHubReader,
    mac_feed_release: dict[str, Any],
    mac_version_release: dict[str, Any],
    appcast: MacAppcast,
    mac_checksum_data: bytes,
    windows_release: dict[str, Any],
    windows_feed_data: bytes,
    windows_checksum_data: bytes,
    sparkle_public_key: str,
) -> None:
    with tempfile.TemporaryDirectory(prefix="hoverpocket-release-readback-") as directory:
        root = pathlib.Path(directory)
        mac_version_zip = reader.download_asset(
            mac_version_release,
            appcast.asset_name,
            root / "mac-version",
        )
        mac_manual_zip = reader.download_asset(
            mac_feed_release,
            "HoverPocket-macOS-app.zip",
            root / "mac-feed",
        )
        mac_version_manual_zip = reader.download_asset(
            mac_version_release,
            "HoverPocket-macOS-app.zip",
            root / "mac-version-manual",
        )
        require_macos_downloads(
            verifier,
            mac_feed_release,
            mac_version_release,
            appcast,
            mac_checksum_data,
            mac_version_zip,
            mac_manual_zip,
            mac_version_manual_zip,
        )
        verify_ed25519_signature(
            sparkle_public_key,
            appcast.signature,
            mac_version_zip.path,
        )
        verifier.require(True, "macos.sparkle_signature_verified", "Sparkle signature verification failed")

        windows_downloads = {
            name: reader.download_asset(windows_release, name, root / "windows")
            for name in asset_map(windows_release)
        }
        require_windows_downloads(
            verifier,
            windows_release,
            windows_checksum_data,
            windows_feed_data,
            windows_downloads,
        )


def run(args: argparse.Namespace) -> dict[str, Any]:
    repository = args.repository
    reader = GitHubReader(repository)
    verifier = Verifier()

    mac_feed_release = reader.release(args.macos_feed_tag)
    mac_feed_appcast = reader.asset(mac_feed_release, "appcast.xml")
    parsed_appcast = parse_appcast(mac_feed_appcast, repository)
    mac_version_release = reader.release(parsed_appcast.release_tag)
    mac_version_appcast = reader.asset(mac_version_release, "appcast.xml")
    mac_checksum = reader.asset(mac_version_release, f"{parsed_appcast.asset_name}.sha256")
    appcast = validate_macos(
        verifier,
        repository,
        mac_feed_release,
        mac_feed_appcast,
        mac_version_release,
        mac_version_appcast,
        mac_checksum,
    )

    windows_release = resolve_windows_release(reader, args.windows_tag)
    windows_tag = windows_release.get("tag_name")
    if not isinstance(windows_tag, str):
        raise VerificationError("windows.release_tag: missing tag")
    windows_feed = reader.asset(windows_release, "releases.win.json")
    windows_manifest = reader.asset(windows_release, "release-manifest.win.json")
    windows_checksums = reader.asset(windows_release, "SHA256SUMS-win.txt")
    windows_version, windows_authenticode = validate_windows(
        verifier,
        windows_release,
        windows_feed,
        windows_manifest,
        windows_checksums,
        args.windows_signing_gate,
    )
    github_latest_release = reader.latest_release()
    verify_downloaded_releases(
        verifier,
        reader,
        mac_feed_release,
        mac_version_release,
        appcast,
        mac_checksum,
        windows_release,
        windows_feed,
        windows_checksums,
        args.sparkle_public_key,
    )
    validate_cross_platform_release_policy(
        verifier,
        appcast.release_tag,
        windows_tag,
        github_latest_release,
    )
    return {
        "status": "passed",
        "repository": repository,
        "macos": {
            "feedTag": args.macos_feed_tag,
            "releaseTag": appcast.release_tag,
            "version": appcast.version,
            "build": appcast.build,
            "asset": appcast.asset_name,
            "signature": "sparkle-ed25519-verified",
            "assetReadback": "downloaded-and-hashed",
        },
        "windows": {
            "releaseTag": windows_tag,
            "version": windows_version,
            "authenticode": windows_authenticode,
            "signingGate": args.windows_signing_gate,
            "assetReadback": "all-assets-downloaded-and-hashed",
            "authenticodeEvidence": "manifest-declared",
        },
        "checks": verifier.checks,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="shotaro311/hover-pocket")
    parser.add_argument("--macos-feed-tag", default="macos-latest")
    parser.add_argument(
        "--windows-tag",
        default="auto",
        help="Windows release tag, or auto to select the greatest semantic win-v... tag without using GitHub latest",
    )
    parser.add_argument(
        "--resolve-windows-tag-only",
        action="store_true",
        help="resolve and print one published Windows tag without downloading release assets",
    )
    parser.add_argument("--windows-signing-gate", choices=("beta", "formal"), default="formal")
    parser.add_argument(
        "--sparkle-public-key",
        default=DEFAULT_SPARKLE_PUBLIC_KEY,
        help="base64-encoded raw Ed25519 public key embedded in the release app",
    )
    parser.add_argument("--json", action="store_true", dest="json_output")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.resolve_windows_tag_only:
            release = resolve_windows_release(GitHubReader(args.repository), args.windows_tag)
            print(release["tag_name"])
            return 0
        report = run(args)
    except VerificationError as error:
        if args.json_output:
            print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False, sort_keys=True))
        else:
            print(f"FAIL release readback: {error}", file=sys.stderr)
        return 1
    if args.json_output:
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    else:
        print(
            "PASS release readback: "
            f"macOS {report['macos']['version']} ({report['macos']['build']}), "
            f"Windows {report['windows']['version']} ({report['windows']['authenticode']})"
        )
        for check in report["checks"]:
            print(f"{check}=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
