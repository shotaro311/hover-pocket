import base64
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "verify_release_readback.py"
WORKFLOW = pathlib.Path(__file__).parents[2] / ".github/workflows/release-readback-verify.yml"
SPEC = importlib.util.spec_from_file_location("verify_release_readback", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def release(tag, assets):
    return {
        "tag_name": tag,
        "assets": [
            {
                "name": name,
                "size": len(data),
                "digest": f"sha256:{MODULE.sha256(data)}",
                "browser_download_url": f"https://example.invalid/{name}",
            }
            for name, data in assets.items()
        ],
    }


class ReleaseReadbackTests(unittest.TestCase):
    def mac_fixture(self):
        zip_name = "HoverPocket-1.2.3-456.zip"
        zip_data = b"signed-notarized-app"
        signature = base64.b64encode(b"s" * 64).decode("ascii")
        appcast = f'''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item><sparkle:version>456</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure
    url="https://github.com/shotaro311/hover-pocket/releases/download/v1.2.3-456/{zip_name}"
    length="{len(zip_data)}"
    sparkle:edSignature="{signature}" /></item></channel>
</rss>'''.encode()
        checksum = f"{MODULE.sha256(zip_data)}  {zip_name}\n".encode("ascii")
        feed_assets = {"appcast.xml": appcast, "HoverPocket-macOS-app.zip": zip_data}
        version_assets = {
            "appcast.xml": appcast,
            "HoverPocket-macOS-app.zip": zip_data,
            zip_name: zip_data,
            f"{zip_name}.sha256": checksum,
        }
        return appcast, checksum, release("macos-latest", feed_assets), release("v1.2.3-456", version_assets)

    def windows_fixture(self, authenticode="unsigned"):
        version = "1.2.3"
        package_name = f"HoverPocketWin-{version}-full.nupkg"
        assets = {
            package_name: b"package",
            "HoverPocketWin-win-Portable.zip": b"portable",
            "HoverPocketWin-win-Setup.exe": b"setup",
            "RELEASES": b"releases",
            "assets.win.json": b"assets",
        }
        feed = json.dumps({
            "Assets": [{
                "PackageId": "HoverPocketWin",
                "Version": version,
                "Type": "Full",
                "FileName": package_name,
                "SHA1": hashlib.sha1(assets[package_name]).hexdigest().upper(),
                "SHA256": MODULE.sha256(assets[package_name]).upper(),
                "Size": len(assets[package_name]),
            }]
        }, separators=(",", ":")).encode()
        manifest = json.dumps({
            "schemaVersion": 1,
            "product": "HoverPocket",
            "packageId": "HoverPocketWin",
            "version": version,
            "runtime": "win-x64",
            "updateChannel": "win",
            "updateFeed": "releases.win.json",
            "oauthMetadata": "embedded-and-verified",
            "authenticode": authenticode,
        }, separators=(",", ":")).encode()
        assets["releases.win.json"] = feed
        assets["release-manifest.win.json"] = manifest
        checksums = "".join(f"{MODULE.sha256(data)}  {name}\n" for name, data in sorted(assets.items())).encode("ascii")
        assets["SHA256SUMS-win.txt"] = checksums
        return release(f"win-v{version}", assets), feed, manifest, checksums

    def test_valid_macos_release(self):
        appcast, checksum, feed_release, version_release = self.mac_fixture()
        verifier = MODULE.Verifier()
        parsed = MODULE.validate_macos(
            verifier,
            "shotaro311/hover-pocket",
            feed_release,
            appcast,
            version_release,
            appcast,
            checksum,
        )
        self.assertEqual(parsed.release_tag, "v1.2.3-456")
        self.assertIn("macos.sparkle_signature_format", verifier.checks)

    def test_sparkle_signature_verifies_exact_downloaded_bytes(self):
        public_key = base64.b64encode(bytes.fromhex(
            "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
        )).decode("ascii")
        signature = base64.b64encode(bytes.fromhex(
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69d"
            "a085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
        )).decode("ascii")
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "archive.zip"
            archive.write_bytes(b"\x72")
            MODULE.verify_ed25519_signature(public_key, signature, archive)
            archive.write_bytes(b"\x73")
            with self.assertRaises(MODULE.VerificationError):
                MODULE.verify_ed25519_signature(public_key, signature, archive)

    def test_macos_rejects_stable_version_mismatch(self):
        appcast, checksum, feed_release, version_release = self.mac_fixture()
        feed_release["assets"][1]["digest"] = "sha256:" + "0" * 64
        with self.assertRaises(MODULE.VerificationError):
            MODULE.validate_macos(
                MODULE.Verifier(),
                "shotaro311/hover-pocket",
                feed_release,
                appcast,
                version_release,
                appcast,
                checksum,
            )

    def test_windows_beta_allows_declared_unsigned_release(self):
        release_value, feed, manifest, checksums = self.windows_fixture()
        verifier = MODULE.Verifier()
        version, signing = MODULE.validate_windows(
            verifier, release_value, feed, manifest, checksums, "beta"
        )
        self.assertEqual((version, signing), ("1.2.3", "unsigned"))

    def test_windows_beta_rejects_non_nupkg_full_feed_target(self):
        release_value, feed, manifest, checksums = self.windows_fixture()
        feed_value = json.loads(feed)
        wrong_name = "HoverPocketWin-win-Setup.exe"
        wrong_bytes = b"setup"
        package = feed_value["Assets"][0]
        package["FileName"] = wrong_name
        package["SHA1"] = hashlib.sha1(wrong_bytes).hexdigest().upper()
        package["SHA256"] = MODULE.sha256(wrong_bytes).upper()
        package["Size"] = len(wrong_bytes)

        with self.assertRaises(MODULE.VerificationError):
            MODULE.validate_windows(
                MODULE.Verifier(),
                release_value,
                json.dumps(feed_value, separators=(",", ":")).encode(),
                manifest,
                checksums,
                "beta",
            )

    def test_windows_beta_requires_canonical_download_asset_names(self):
        release_value, feed, manifest, checksums = self.windows_fixture()
        renamed = {
            MODULE.WINDOWS_SETUP_ASSET: "Old-Setup.exe",
            MODULE.WINDOWS_PORTABLE_ASSET: "Old-Portable.zip",
        }
        for asset in release_value["assets"]:
            if asset["name"] in renamed:
                asset["name"] = renamed[asset["name"]]
        checksum_text = checksums.decode("ascii")
        for canonical, stale in renamed.items():
            checksum_text = checksum_text.replace(canonical, stale)

        with self.assertRaises(MODULE.VerificationError):
            MODULE.validate_windows(
                MODULE.Verifier(),
                release_value,
                feed,
                manifest,
                checksum_text.encode("ascii"),
                "beta",
            )

    def test_windows_formal_rejects_unsigned_release(self):
        release_value, feed, manifest, checksums = self.windows_fixture()
        with self.assertRaises(MODULE.VerificationError):
            MODULE.validate_windows(
                MODULE.Verifier(), release_value, feed, manifest, checksums, "formal"
            )

    def test_windows_formal_accepts_timestamped_signature_readback(self):
        release_value, feed, manifest, checksums = self.windows_fixture(
            authenticode="signed-timestamped-verified"
        )
        verifier = MODULE.Verifier()
        _, signing = MODULE.validate_windows(
            verifier, release_value, feed, manifest, checksums, "formal"
        )
        self.assertEqual(signing, "signed-timestamped-verified")

    def test_checksum_parser_rejects_paths_and_duplicates(self):
        with self.assertRaises(MODULE.VerificationError):
            MODULE.parse_sha256_sums(("0" * 64 + "  ../asset.zip\n").encode())
        with self.assertRaises(MODULE.VerificationError):
            MODULE.parse_sha256_sums(("0" * 64 + "  a.zip\n" + "1" * 64 + "  a.zip\n").encode())

    def test_release_asset_names_cannot_escape_download_directory(self):
        with self.assertRaises(MODULE.VerificationError):
            MODULE.asset_map({"assets": [{"name": "../asset.zip"}]})

    def test_windows_download_readback_uses_actual_bytes_and_feed_sha1(self):
        release_value, feed, _manifest, checksums = self.windows_fixture()
        assets = MODULE.asset_map(release_value)
        parsed_checksums = MODULE.parse_sha256_sums(checksums)
        downloads = {}
        for name, item in assets.items():
            digest = MODULE.parse_digest(item["digest"], name)
            downloads[name] = MODULE.DownloadedAsset(
                name=name,
                path=pathlib.Path(name),
                size=item["size"],
                sha256=digest,
                sha1="",
            )
        package_name = json.loads(feed)["Assets"][0]["FileName"]
        downloads[package_name] = MODULE.DownloadedAsset(
            name=package_name,
            path=pathlib.Path(package_name),
            size=assets[package_name]["size"],
            sha256=parsed_checksums[package_name],
            sha1=json.loads(feed)["Assets"][0]["SHA1"].lower(),
        )
        verifier = MODULE.Verifier()
        MODULE.require_windows_downloads(verifier, release_value, checksums, feed, downloads)
        self.assertIn("windows.feed_sha1", verifier.checks)

        downloads[package_name] = MODULE.DownloadedAsset(
            name=package_name,
            path=pathlib.Path(package_name),
            size=assets[package_name]["size"],
            sha256=parsed_checksums[package_name],
            sha1="0" * 40,
        )
        with self.assertRaises(MODULE.VerificationError):
            MODULE.require_windows_downloads(
                MODULE.Verifier(), release_value, checksums, feed, downloads
            )

    def test_macos_download_readback_requires_both_manual_zip_copies(self):
        appcast_data, checksum, feed_release, version_release = self.mac_fixture()
        appcast = MODULE.parse_appcast(appcast_data, "shotaro311/hover-pocket")
        zip_data = b"signed-notarized-app"

        def downloaded(name):
            return MODULE.DownloadedAsset(
                name=name,
                path=pathlib.Path(name),
                size=len(zip_data),
                sha256=MODULE.sha256(zip_data),
                sha1=hashlib.sha1(zip_data).hexdigest(),
            )

        version_zip = downloaded(appcast.asset_name)
        stable_manual_zip = downloaded("HoverPocket-macOS-app.zip")
        version_manual_zip = downloaded("HoverPocket-macOS-app.zip")
        verifier = MODULE.Verifier()
        MODULE.require_macos_downloads(
            verifier,
            feed_release,
            version_release,
            appcast,
            checksum,
            version_zip,
            stable_manual_zip,
            version_manual_zip,
        )
        self.assertIn("macos.download.version_manual_zip.sha256", verifier.checks)
        self.assertIn("macos.download.version_manual_zip_parity", verifier.checks)

        mismatched_version_manual = MODULE.DownloadedAsset(
            name="HoverPocket-macOS-app.zip",
            path=pathlib.Path("HoverPocket-macOS-app.zip"),
            size=len(zip_data),
            sha256="0" * 64,
            sha1=hashlib.sha1(zip_data).hexdigest(),
        )
        with self.assertRaises(MODULE.VerificationError):
            MODULE.require_macos_downloads(
                MODULE.Verifier(),
                feed_release,
                version_release,
                appcast,
                checksum,
                version_zip,
                stable_manual_zip,
                mismatched_version_manual,
            )

    def test_windows_release_discovery_uses_numeric_version_and_ignores_drafts(self):
        releases = [
            {"tag_name": "v9.0.0", "draft": False, "prerelease": False},
            {"tag_name": "win-v0.2.9", "draft": False, "prerelease": False},
            {"tag_name": "win-v0.2.10", "draft": False, "prerelease": False},
            {"tag_name": "win-v8.0.0", "draft": False, "prerelease": True},
            {"tag_name": "win-v9.0.0", "draft": True, "prerelease": False},
        ]
        reader = MODULE.GitHubReader("shotaro311/hover-pocket")
        reader.bytes = lambda _url: json.dumps(releases).encode()
        self.assertEqual(reader.latest_windows_release()["tag_name"], "win-v0.2.10")

    def test_windows_release_resolution_rejects_unpublished_explicit_tag(self):
        reader = MODULE.GitHubReader("shotaro311/hover-pocket")
        reader.release = lambda _tag: {
            "tag_name": "win-v1.2.3",
            "draft": False,
            "prerelease": True,
        }
        with self.assertRaises(MODULE.VerificationError):
            MODULE.resolve_windows_release(reader, "win-v1.2.3")

    def test_formal_workflow_pins_one_windows_tag_for_both_readbacks(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        pinned = "WINDOWS_TAG: ${{ needs.resolve-windows-release.outputs.windows_tag }}"
        self.assertEqual(workflow.count(pinned), 2)
        self.assertIn("needs: [resolve-windows-release]", workflow)
        self.assertNotIn("WINDOWS_TAG: ${{ inputs.windows_tag }}", workflow)
        upload_artifact_sha = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
        self.assertEqual(workflow.count(f"actions/upload-artifact@{upload_artifact_sha}"), 2)
        self.assertIn("- name: Verify published release surfaces\n        shell: bash", workflow)

    def test_github_latest_must_remain_the_macos_release(self):
        verifier = MODULE.Verifier()
        MODULE.validate_cross_platform_release_policy(
            verifier,
            "v1.2.3-456",
            "win-v1.2.3",
            {"tag_name": "v1.2.3-456", "draft": False, "prerelease": False},
        )
        self.assertIn("cross_platform.github_latest_is_macos", verifier.checks)

        with self.assertRaises(MODULE.VerificationError):
            MODULE.validate_cross_platform_release_policy(
                MODULE.Verifier(),
                "v1.2.3-456",
                "win-v1.2.4",
                {"tag_name": "win-v1.2.4", "draft": False, "prerelease": False},
            )


if __name__ == "__main__":
    unittest.main()
