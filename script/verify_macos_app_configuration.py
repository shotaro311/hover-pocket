#!/usr/bin/env python3
"""Reject incomplete production app configuration without printing OAuth values."""

import argparse
import pathlib
import plistlib
import re
import subprocess
import sys


def validate(info: dict, entitlements: dict) -> None:
    client_id = info.get("GIDClientID", "")
    if not isinstance(client_id, str) or not re.fullmatch(
        r"[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com", client_id
    ):
        raise ValueError("GIDClientID is missing or invalid; configure GOOGLE_SIGN_IN_CLIENT_ID before packaging")
    expected_scheme = ".".join(reversed(client_id.split(".")))
    schemes = [scheme for item in info.get("CFBundleURLTypes", [])
               for scheme in item.get("CFBundleURLSchemes", [])]
    if expected_scheme not in schemes:
        raise ValueError("Google Sign-In callback URL scheme does not match GIDClientID")
    if entitlements.get("com.apple.security.personal-information.location") is not True:
        raise ValueError("Location entitlement is missing from the signed app")
    if not info.get("NSLocationUsageDescription"):
        raise ValueError("NSLocationUsageDescription is missing")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    args = parser.parse_args()
    try:
        info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
        result = subprocess.run(
            ["codesign", "--display", "--entitlements", "-", "--xml", str(args.app)],
            capture_output=True, check=True,
        )
        validate(info, plistlib.loads(result.stdout))
    except ValueError as error:
        print(f"release_configuration=failed: {error}", file=sys.stderr)
        return 1
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        print("release_configuration=failed: cannot read app metadata or signed entitlements", file=sys.stderr)
        return 1
    print("release_configuration=ok: Google Sign-In callback and location access")
    return 0


if __name__ == "__main__":
    sys.exit(main())
