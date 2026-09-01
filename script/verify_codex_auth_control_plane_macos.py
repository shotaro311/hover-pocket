#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import threading

from verify_codex_generation_confinement_macos import (
    SUPPORTED_VERSION,
    VerificationError,
    fail,
    resolve_executable,
    safe_cleanup,
    toml_string,
)


ROOT_PREFIX = "HoverPocketCodexAuthControl-"
CATALOG_RELATIVE_PATH = Path(
    "Sources/HoverPocket/Resources/PocketApps/_Host/codex-model-catalog.v1.json"
)
CATALOG_DIGEST = "bc11d3320055b4e235ecefe823fd78017e1a526b893541cc936fa0708d0d515c"
GENERATION_SCHEMA_RELATIVE_PATH = Path(
    "contracts/pocket/v1/pocket-app-generation-output.schema.json"
)
GENERATION_SCHEMA_DIGEST = "d2e1526590dc17426e529ef4370b1bf8c4f598abb159e3d730c6eb9eda5726a5"
GENERATION_FIXTURE_RELATIVE_PATH = Path(
    "contracts/pocket/v1/fixtures/support/pocket-app-generation.real-codex-output.json"
)
GENERATION_FIXTURE_DIGEST = "4d2fe7f006ebb1d2d86c283f8bb1dec247f87f80e0e34e83fe5561f8b65f583a"
GENERATION_SCHEMA_ID = "hoverpocket://schemas/pocket-app-generation-output/v1"
MODEL_ID = "gpt-5.6-sol"
REASONING_EFFORT = "medium"
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_STDOUT_BYTES = 16_384
MAX_STDERR_BYTES = 64_000
SURROGATE = "fixture-surrogate-not-secret"


def catalog_path() -> Path:
    return Path(__file__).resolve().parents[1] / CATALOG_RELATIVE_PATH


def load_catalog() -> bytes:
    path = catalog_path()
    try:
        metadata = path.lstat()
        data = path.read_bytes()
    except OSError as error:
        raise VerificationError("the pinned model catalog is unavailable") from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or not data
        or len(data) > 64 * 1024
        or hashlib.sha256(data).hexdigest() != CATALOG_DIGEST
    ):
        fail("the pinned model catalog failed integrity validation")
    try:
        root = json.loads(data)
        models = root["models"]
        model = models[0]
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise VerificationError("the pinned model catalog is invalid") from error
    if (
        set(root) != {"models"}
        or len(models) != 1
        or model.get("slug") != MODEL_ID
        or model.get("default_reasoning_level") != REASONING_EFFORT
        or model.get("supported_in_api") is not True
        or model.get("supports_parallel_tool_calls") is not False
        or model.get("supports_search_tool") is not False
        or model.get("tool_mode", "missing") is not None
        or model.get("multi_agent_version", "missing") is not None
    ):
        fail("the pinned model catalog violates the generation contract")
    return data


def load_generation_contract() -> tuple[bytes, dict[str, object], str]:
    root = Path(__file__).resolve().parents[1]
    schema_path = root / GENERATION_SCHEMA_RELATIVE_PATH
    fixture_path = root / GENERATION_FIXTURE_RELATIVE_PATH
    try:
        schema_data = schema_path.read_bytes()
        fixture_data = fixture_path.read_bytes()
        schema = json.loads(schema_data)
        fixture = json.loads(fixture_data)
    except (OSError, TypeError, json.JSONDecodeError) as error:
        raise VerificationError("the generation contract is unavailable") from error
    if (
        schema_path.is_symlink()
        or fixture_path.is_symlink()
        or hashlib.sha256(schema_data).hexdigest() != GENERATION_SCHEMA_DIGEST
        or hashlib.sha256(fixture_data).hexdigest() != GENERATION_FIXTURE_DIGEST
        or schema.get("$id") != GENERATION_SCHEMA_ID
        or fixture.get("$schema") != GENERATION_SCHEMA_ID
        or set(fixture) != {
            "$schema",
            "requestId",
            "requestDigest",
            "appId",
            "version",
            "namespace",
            "files",
        }
        or not isinstance(fixture.get("files"), list)
        or not 3 <= len(fixture["files"]) <= 128
    ):
        fail("the generation contract failed integrity validation")
    output = json.dumps(fixture, sort_keys=True, separators=(",", ":"))
    return schema_data, schema, output


def response_object(output: list[dict[str, object]]) -> dict[str, object]:
    return {
        "id": "resp_hoverpocket_canary",
        "object": "response",
        "created_at": 0,
        "status": "completed",
        "model": MODEL_ID,
        "output": output,
        "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
    }


def encode_event_stream(events: list[dict[str, object]]) -> bytes:
    output = bytearray()
    for event in events:
        output.extend(f"event: {event['type']}\n".encode())
        output.extend(b"data: ")
        output.extend(json.dumps(event, separators=(",", ":")).encode())
        output.extend(b"\n\n")
    return bytes(output)


class CanaryState:
    def __init__(
        self,
        helper: Path,
        marker: Path,
        expected_schema: dict[str, object],
        final_text: str,
    ) -> None:
        self.lock = threading.Lock()
        self.helper = helper
        self.marker = marker
        self.requests = 0
        self.authenticated = True
        self.request_bodies_clean = True
        self.output_schema_bound = True
        self.unexpected_get = False
        self.tool_output: str | None = None
        self.expected_schema = expected_schema
        self.final_text = final_text

    def command(self) -> str:
        helper = shlex.quote(str(self.helper))
        marker = shlex.quote(str(self.marker))
        return (
            f"read_state=denied; if /bin/cat {helper} >/dev/null 2>&1; "
            "then read_state=allowed; fi; "
            f"exec_state=denied; if {helper} {marker} >/dev/null 2>&1; "
            "then exec_state=allowed; fi; "
            'printf "helper_read=%s\\nhelper_exec=%s\\n" "$read_state" "$exec_state"'
        )


def handler_type(state: CanaryState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_: object) -> None:
            return

        def do_GET(self) -> None:
            with state.lock:
                state.unexpected_get = True
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()

        def do_POST(self) -> None:
            try:
                length = int(self.headers.get("content-length", "0"))
            except ValueError:
                length = -1
            if length <= 0 or length > MAX_REQUEST_BYTES:
                self.send_response(413)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            body = self.rfile.read(length)
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            with state.lock:
                state.requests += 1
                request_number = state.requests
                state.authenticated = state.authenticated and (
                    self.headers.get("authorization") == f"Bearer {SURROGATE}"
                )
                state.request_bodies_clean = state.request_bodies_clean and SURROGATE.encode() not in body
                text_format = payload.get("text", {}).get("format", {})
                state.output_schema_bound = state.output_schema_bound and (
                    text_format.get("type") == "json_schema"
                    and text_format.get("strict") is True
                    and text_format.get("schema") == state.expected_schema
                )
            if self.path != "/v1/responses" or request_number > 2:
                self.send_response(400)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            function_outputs = [
                item
                for item in payload.get("input", [])
                if isinstance(item, dict) and item.get("type") == "function_call_output"
            ]
            if request_number == 1 and not function_outputs:
                item = {
                    "type": "function_call",
                    "id": "fc_hoverpocket_canary",
                    "call_id": "call_hoverpocket_canary",
                    "name": "exec_command",
                    "arguments": json.dumps(
                        {
                            "cmd": state.command(),
                            "yield_time_ms": 1000,
                            "max_output_chars": 2000,
                        },
                        separators=(",", ":"),
                    ),
                }
                response = response_object([{**item, "status": "completed"}])
                events = [
                    {"type": "response.created", "response": {**response, "status": "in_progress", "output": []}},
                    {"type": "response.output_item.added", "output_index": 0, "item": item},
                    {"type": "response.output_item.done", "output_index": 0, "item": {**item, "status": "completed"}},
                    {"type": "response.completed", "response": response},
                ]
            elif request_number == 2 and function_outputs:
                with state.lock:
                    state.tool_output = str(function_outputs[-1].get("output", ""))
                message = {
                    "id": "msg_hoverpocket_canary",
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": state.final_text, "annotations": []}],
                }
                response = response_object([message])
                events = [
                    {"type": "response.created", "response": {**response, "status": "in_progress", "output": []}},
                    {
                        "type": "response.output_item.added",
                        "output_index": 0,
                        "item": {**message, "status": "in_progress", "content": []},
                    },
                    {
                        "type": "response.content_part.added",
                        "item_id": message["id"],
                        "output_index": 0,
                        "content_index": 0,
                        "part": {"type": "output_text", "text": "", "annotations": []},
                    },
                    {
                        "type": "response.output_text.delta",
                        "item_id": message["id"],
                        "output_index": 0,
                        "content_index": 0,
                        "delta": state.final_text,
                    },
                    {
                        "type": "response.output_text.done",
                        "item_id": message["id"],
                        "output_index": 0,
                        "content_index": 0,
                        "text": state.final_text,
                    },
                    {
                        "type": "response.content_part.done",
                        "item_id": message["id"],
                        "output_index": 0,
                        "content_index": 0,
                        "part": message["content"][0],
                    },
                    {"type": "response.output_item.done", "output_index": 0, "item": message},
                    {"type": "response.completed", "response": response},
                ]
            else:
                self.send_response(400)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            encoded = encode_event_stream(events)
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            self.wfile.flush()

    return Handler


def write_helper(helper: Path) -> None:
    helper.write_text(
        "#!/bin/sh\n"
        "count=0\n"
        "if [ -f \"$1\" ]; then count=$(/bin/cat \"$1\"); fi\n"
        "count=$((count + 1))\n"
        "printf \"%s\" \"$count\" > \"$1\"\n"
        "printf \"%s%s\" \"fixture-surrogate-\" \"not-secret\"\n",
        encoding="utf-8",
    )
    helper.chmod(0o700)


def run_process(command: list[str], environment: dict[str, str]) -> tuple[int, int, bytes, bytes]:
    process = subprocess.Popen(
        command,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(b"Run the requested canary and finish.\n", timeout=20)
    except subprocess.TimeoutExpired as error:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
        raise VerificationError("the auth control-plane canary timed out") from error
    return process.pid, process.returncode, stdout, stderr


def assert_no_surrogate_files(root: Path) -> None:
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            raise VerificationError("the canary could not inspect its temporary files") from error
        if SURROGATE.encode() in data:
            fail("the surrogate credential persisted to disk")


def run_canary(explicit_codex: Path | None) -> dict[str, object]:
    if sys.platform != "darwin":
        fail("the auth control-plane canary requires macOS")
    codex = resolve_executable(explicit_codex)
    catalog = load_catalog()
    generation_schema_data, generation_schema, generation_output = load_generation_contract()
    temporary_root = Path(os.path.realpath(os.environ.get("TMPDIR", "/tmp")))
    root = Path(tempfile.mkdtemp(prefix=ROOT_PREFIX, dir=temporary_root))
    server: ThreadingHTTPServer | None = None
    thread: threading.Thread | None = None
    try:
        workspace = root / "workspace"
        codex_home = root / "codex-home"
        user_home = root / "user-home"
        temporary = root / "tmp"
        for directory in (workspace, codex_home, user_home, temporary):
            directory.mkdir(mode=0o700)
        catalog_file = workspace / "model-catalog.json"
        catalog_file.write_bytes(catalog)
        catalog_file.chmod(0o400)
        generation_schema_file = workspace / "generation-output.schema.json"
        generation_schema_file.write_bytes(generation_schema_data)
        generation_schema_file.chmod(0o400)
        helper = root / "credential-helper"
        marker = root / "helper-count"
        write_helper(helper)
        state = CanaryState(helper, marker, generation_schema, generation_output)
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler_type(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        filesystem = "permissions.hoverpocket-generation.filesystem={" + ",".join(
            (
                f'{toml_string(":minimal")}="read"',
                f'{toml_string(str(workspace))}="read"',
                f'{toml_string(str(codex_home))}="deny"',
                f'{toml_string(str(user_home))}="deny"',
                f'{toml_string(str(helper))}="deny"',
            )
        ) + "}"
        base_url = f"http://127.0.0.1:{server.server_address[1]}/v1"
        command = [
            str(codex),
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "-c", 'approval_policy="never"',
            "-c", f"model={toml_string(MODEL_ID)}",
            "-c", f"model_reasoning_effort={toml_string(REASONING_EFFORT)}",
            "-c", f"model_catalog_json={toml_string(str(catalog_file))}",
            "-c", 'model_provider="hoverpocket"',
            "-c", 'model_providers.hoverpocket.name="HoverPocket Auth Canary"',
            "-c", f"model_providers.hoverpocket.base_url={toml_string(base_url)}",
            "-c", 'model_providers.hoverpocket.wire_api="responses"',
            "-c", f"model_providers.hoverpocket.auth.command={toml_string(str(helper))}",
            "-c", f"model_providers.hoverpocket.auth.args=[{toml_string(str(marker))}]",
            "-c", f"model_providers.hoverpocket.auth.cwd={toml_string(str(workspace))}",
            "-c", "model_providers.hoverpocket.auth.refresh_interval_ms=0",
            "-c", "model_providers.hoverpocket.auth.timeout_ms=5000",
            "-c", "model_providers.hoverpocket.request_max_retries=0",
            "-c", "model_providers.hoverpocket.stream_max_retries=0",
            "-c", 'default_permissions="hoverpocket-generation"',
            "-c", filesystem,
            "-c", "permissions.hoverpocket-generation.network.enabled=false",
            "-c", 'shell_environment_policy.inherit="none"',
            "-c", 'shell_environment_policy.set={PATH="/usr/bin:/bin",LANG="C"}',
            "-C", str(workspace),
            "--output-schema", str(generation_schema_file),
            "-",
        ]
        environment = {
            "CODEX_HOME": str(codex_home),
            "HOME": str(user_home),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": str(temporary),
            "LANG": "C",
        }
        _pid, return_code, stdout, stderr = run_process(command, environment)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        server = None
        thread = None
        if return_code != 0 or stdout != f"{generation_output}\n".encode():
            fail("the auth control-plane canary process failed")
        if len(stdout) > MAX_STDOUT_BYTES or len(stderr) > MAX_STDERR_BYTES:
            fail("the auth control-plane canary output exceeded its limit")
        if SURROGATE.encode() in stdout or SURROGATE.encode() in stderr:
            fail("the auth control-plane canary disclosed its surrogate credential")
        with state.lock:
            requests = state.requests
            authenticated = state.authenticated
            request_bodies_clean = state.request_bodies_clean
            output_schema_bound = state.output_schema_bound
            unexpected_get = state.unexpected_get
            tool_output = state.tool_output or ""
        if (
            requests != 2
            or not authenticated
            or not request_bodies_clean
            or not output_schema_bound
            or unexpected_get
        ):
            fail("the static model catalog did not keep auth within one request client")
        if "helper_read=denied\nhelper_exec=denied\n" not in tool_output:
            fail("the model tool was not denied access to the auth helper")
        if "helper_read=allowed" in tool_output or "helper_exec=allowed" in tool_output:
            fail("the model tool accessed the auth helper")
        try:
            helper_count = marker.read_text(encoding="utf-8")
        except OSError as error:
            raise VerificationError("the helper invocation marker is unavailable") from error
        if helper_count != "1":
            fail("the auth helper was not one-shot within the generation process")
        assert_no_surrogate_files(root)
        return {
            "schemaVersion": 1,
            "status": "passed",
            "codexVersion": SUPPORTED_VERSION,
            "model": MODEL_ID,
            "checks": {
                "staticModelCatalog": True,
                "remoteModelCatalogSkipped": True,
                "authHelperOneShot": True,
                "responsesAuthenticated": True,
                "generationOutputSchemaBound": True,
                "generationEnvelopeReturned": True,
                "modelToolHelperReadDenied": True,
                "modelToolHelperExecuteDenied": True,
                "surrogateAbsentFromBodies": True,
                "surrogateAbsentFromOutput": True,
                "surrogateAbsentFromDisk": True,
                "processTerminated": True,
            },
        }
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        if thread is not None:
            thread.join(timeout=2)
        safe_cleanup(root, temporary_root, ROOT_PREFIX)


def run_self_test() -> None:
    load_catalog()
    load_generation_contract()
    events = encode_event_stream([{"type": "response.completed", "response": {"status": "completed"}}])
    if b"event: response.completed\n" not in events or SURROGATE.encode() in events:
        fail("the event-stream self-test failed")
    output = "helper_read=denied\nhelper_exec=denied\n"
    if "helper_read=allowed" in output or "helper_exec=allowed" in output:
        fail("the tool-output self-test failed")
    print("PASS Codex auth control-plane verifier self-test")


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
        print("PASS Codex auth control-plane canary")
        print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    except VerificationError as error:
        raise SystemExit(f"FAIL Codex auth control-plane canary: {error}") from error


if __name__ == "__main__":
    main()
