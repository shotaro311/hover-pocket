#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time


SUPPORTED_VERSION = "codex-cli 0.145.0"
OPENAI_TEAM_ID = "2DC432GLL2"
OPENAI_AUTHORITY = "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)"
ROOT_PREFIX = "HoverPocketCodexConfinement-"
FOREIGN_PREFIX = "HoverPocketCodexForeign-"
MAX_STDOUT_BYTES = 16_384
MAX_STDERR_BYTES = 32_768
FIXED_CANDIDATES = (
    Path(
        "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/"
        "@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
    ),
    Path(
        "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/"
        "@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
    ),
    Path(
        "/usr/local/lib/node_modules/@openai/codex/node_modules/"
        "@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
    ),
    Path(
        "/usr/local/lib/node_modules/@openai/codex/node_modules/"
        "@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
    ),
)

PROBE_SCRIPT = r"""
import json
from pathlib import Path
import socket
import sys

workspace, codex_home, user_home, foreign_root, port = sys.argv[1:]

def readable(path):
    try:
        Path(path).read_bytes()
        return True
    except OSError:
        return False

def writable(path):
    try:
        Path(path).write_text("write-canary", encoding="utf-8")
        return True
    except OSError:
        return False

client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.settimeout(1)
try:
    network_connected = client.connect_ex(("127.0.0.1", int(port))) == 0
except OSError:
    network_connected = False
finally:
    client.close()

print(json.dumps({
    "codex_home_read": readable(Path(codex_home) / "denied.txt"),
    "foreign_read": readable(Path(foreign_root) / "denied.txt"),
    "network_connected": network_connected,
    "user_home_read": readable(Path(user_home) / "denied.txt"),
    "workspace_read": readable(Path(workspace) / "allowed.txt"),
    "workspace_write": writable(Path(workspace) / "write-attempt.txt"),
}, sort_keys=True, separators=(",", ":")))
"""

EXPECTED_PROBE = {
    "codex_home_read": False,
    "foreign_read": False,
    "network_connected": False,
    "user_home_read": False,
    "workspace_read": True,
    "workspace_write": False,
}


class VerificationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def run_trusted(arguments: list[str], *, capture_stderr: bool = False) -> str:
    result = subprocess.run(
        arguments,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if capture_stderr else subprocess.PIPE,
        timeout=5,
        check=False,
    )
    if result.returncode != 0:
        fail("trusted executable verification failed")
    output = result.stdout
    if len(output) > MAX_STDERR_BYTES:
        fail("trusted executable verification output exceeded its limit")
    try:
        return output.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError("trusted executable verification output was not UTF-8") from error


def verify_executable(candidate: Path) -> Path:
    try:
        info = candidate.lstat()
    except OSError as error:
        raise VerificationError("the pinned Codex executable is unavailable") from error
    if not stat.S_ISREG(info.st_mode) or candidate.is_symlink():
        fail("the pinned Codex executable is not a regular file")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("the pinned Codex executable is group- or world-writable")
    if info.st_uid not in {0, os.geteuid()} or not os.access(candidate, os.X_OK):
        fail("the pinned Codex executable owner or mode is invalid")

    signature = run_trusted(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(candidate)],
        capture_stderr=True,
    )
    signature_lines = set(signature.splitlines())
    if f"TeamIdentifier={OPENAI_TEAM_ID}" not in signature_lines:
        fail("the pinned Codex executable has an unexpected signing team")
    if f"Authority={OPENAI_AUTHORITY}" not in signature_lines:
        fail("the pinned Codex executable has an unexpected signing authority")
    run_trusted(["/usr/bin/codesign", "--verify", "--strict", str(candidate)])
    version = run_trusted([str(candidate), "--version"]).strip()
    if version != SUPPORTED_VERSION:
        fail("the pinned Codex executable version is unsupported")
    return candidate


def resolve_executable(explicit: Path | None) -> Path:
    if explicit is not None:
        return verify_executable(explicit)
    for candidate in FIXED_CANDIDATES:
        try:
            return verify_executable(candidate)
        except VerificationError:
            continue
    fail("no signed, pinned Codex executable passed verification")


def toml_string(value: str) -> str:
    if any(ord(character) < 32 for character in value):
        fail("a confinement path contains a control character")
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def permission_arguments(workspace: Path, codex_home: Path, user_home: Path) -> list[str]:
    roots = (workspace, codex_home, user_home)
    if len({root.parent for root in roots}) != 1 or len(set(roots)) != len(roots):
        fail("confinement roots must be distinct siblings")
    filesystem = "permissions.hoverpocket-generation.filesystem={" + ",".join(
        (
            f'{toml_string(":minimal")}="read"',
            f'{toml_string(str(workspace))}="read"',
            f'{toml_string(str(codex_home))}="deny"',
            f'{toml_string(str(user_home))}="deny"',
        )
    ) + "}"
    return [
        "-c",
        'default_permissions="hoverpocket-generation"',
        "-c",
        filesystem,
        "-c",
        "permissions.hoverpocket-generation.network.enabled=false",
        "-c",
        'shell_environment_policy.inherit="none"',
        "-c",
        'shell_environment_policy.set={PATH="/usr/bin:/bin",LANG="C"}',
    ]


def parse_probe(stdout: bytes) -> dict[str, bool]:
    if len(stdout) > MAX_STDOUT_BYTES:
        fail("sandbox probe stdout exceeded its limit")
    try:
        text = stdout.decode("utf-8")
        if text.count("\n") > 1:
            fail("sandbox probe emitted unexpected additional output")
        payload = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError("sandbox probe output could not be decoded") from error
    if payload != EXPECTED_PROBE:
        fail("sandbox probe did not enforce the exact file and network boundary")
    return payload


def run_bounded(command: list[str], environment: dict[str, str]) -> tuple[int, bytes, bytes]:
    process = subprocess.Popen(
        command,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=10)
    except subprocess.TimeoutExpired as error:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
        raise VerificationError("sandbox probe timed out") from error
    return process.returncode, stdout, stderr


def safe_cleanup(root: Path, temporary_root: Path, expected_prefix: str) -> None:
    try:
        info = root.lstat()
        if (
            root.parent.resolve(strict=True) != temporary_root
            or not root.name.startswith(expected_prefix)
            or root.is_symlink()
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
        ):
            fail("temporary confinement root failed cleanup validation")
        shutil.rmtree(root)
    except FileNotFoundError:
        return


def run_canary(explicit_codex: Path | None) -> dict[str, object]:
    if sys.platform != "darwin":
        fail("the executable canary requires macOS Seatbelt")
    codex = resolve_executable(explicit_codex)
    temporary_root = Path(os.path.realpath(os.environ.get("TMPDIR", "/tmp")))
    root = Path(tempfile.mkdtemp(prefix=ROOT_PREFIX, dir=temporary_root))
    foreign_root = Path(tempfile.mkdtemp(prefix=FOREIGN_PREFIX, dir=temporary_root))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    accepted = threading.Event()
    try:
        roots = {
            name: root / name
            for name in ("workspace", "codex-home", "user-home", "tmp")
        }
        for directory in roots.values():
            directory.mkdir(mode=0o700)
        (roots["workspace"] / "allowed.txt").write_text("allowed-canary", encoding="utf-8")
        (roots["codex-home"] / "denied.txt").write_text("codex-home-canary", encoding="utf-8")
        (roots["user-home"] / "denied.txt").write_text("user-home-canary", encoding="utf-8")
        (foreign_root / "denied.txt").write_text("outside-root-canary", encoding="utf-8")

        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(2)
        port = listener.getsockname()[1]

        def accept_once() -> None:
            try:
                connection, _ = listener.accept()
                accepted.set()
                connection.close()
            except OSError:
                return

        listener_thread = threading.Thread(target=accept_once, daemon=True)
        listener_thread.start()
        command = [
            str(codex),
            "sandbox",
            "-P",
            "hoverpocket-generation",
            *permission_arguments(
                roots["workspace"],
                roots["codex-home"],
                roots["user-home"],
            ),
            "-C",
            str(roots["workspace"]),
            "/usr/bin/python3",
            "-c",
            PROBE_SCRIPT,
            str(roots["workspace"]),
            str(roots["codex-home"]),
            str(roots["user-home"]),
            str(foreign_root),
            str(port),
        ]
        environment = {
            "CODEX_HOME": str(roots["codex-home"]),
            "HOME": str(roots["user-home"]),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": str(roots["tmp"]),
            "LANG": "C",
        }
        return_code, stdout, stderr = run_bounded(command, environment)
        listener.close()
        listener_thread.join(timeout=3)
        if return_code != 0:
            fail("sandbox probe process failed")
        if len(stderr) > MAX_STDERR_BYTES:
            fail("sandbox probe stderr exceeded its limit")
        forbidden_markers = (b"allowed-canary", b"codex-home-canary", b"outside-root-canary")
        if any(marker in stderr for marker in forbidden_markers):
            fail("sandbox probe stderr disclosed a canary value")
        parse_probe(stdout)
        if accepted.is_set():
            fail("sandbox probe reached the loopback listener")
        if (roots["workspace"] / "write-attempt.txt").exists():
            fail("sandbox probe wrote inside its read-only workspace")
        return {
            "schemaVersion": 1,
            "status": "passed",
            "codexVersion": SUPPORTED_VERSION,
            "checks": {
                "signedExecutable": True,
                "workspaceRead": True,
                "workspaceWriteDenied": True,
                "codexHomeReadDenied": True,
                "userHomeReadDenied": True,
                "outsideRootReadDenied": True,
                "networkDenied": True,
                "listenerUnreached": True,
                "stderrBounded": True,
            },
        }
    finally:
        listener.close()
        safe_cleanup(foreign_root, temporary_root, FOREIGN_PREFIX)
        safe_cleanup(root, temporary_root, ROOT_PREFIX)


def run_self_test() -> None:
    parse_probe(json.dumps(EXPECTED_PROBE, sort_keys=True, separators=(",", ":")).encode())
    for key in EXPECTED_PROBE:
        rejected = dict(EXPECTED_PROBE)
        rejected[key] = not rejected[key]
        try:
            parse_probe(json.dumps(rejected, sort_keys=True).encode())
        except VerificationError:
            continue
        fail(f"self-test accepted an invalid {key} result")
    root = Path("/private/tmp/fixture")
    arguments = permission_arguments(root / "workspace", root / "codex-home", root / "user-home")
    joined = "\n".join(arguments)
    required = (
        'default_permissions="hoverpocket-generation"',
        '"/private/tmp/fixture/workspace"="read"',
        '"/private/tmp/fixture/codex-home"="deny"',
        '"/private/tmp/fixture/user-home"="deny"',
        "network.enabled=false",
        'shell_environment_policy.inherit="none"',
    )
    if not all(marker in joined for marker in required):
        fail("self-test confinement arguments differ from the expected contract")
    print("PASS Codex generation confinement verifier self-test")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-bin", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.self_test:
            if arguments.codex_bin is not None:
                parser.error("--self-test cannot be combined with --codex-bin")
            run_self_test()
            return
        receipt = run_canary(arguments.codex_bin)
        print("PASS Codex generation confinement canary")
        print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    except VerificationError as error:
        raise SystemExit(f"FAIL Codex generation confinement canary: {error}") from error


if __name__ == "__main__":
    main()
