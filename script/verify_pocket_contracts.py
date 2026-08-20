#!/usr/bin/env python3
"""Deterministic AN0 contract verifier for HoverPocket.

The verifier intentionally uses only the Python standard library. It validates the
Draft 2020-12 subset used by contracts/pocket/v1 and then applies Host-owned
security, privacy, versioning, workflow, readback, root-scope, and geometry
invariants that JSON Schema alone cannot express.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, NoReturn, Sequence

DRAFT_2020_12 = "https://json-schema.org/draft/2020-12/schema"
CONTRACT_NAME = "hoverpocket.pocket/v1"

EXPECTED_SCHEMAS: dict[str, str] = {
    "agent-session-summary.schema.json": "hoverpocket://schemas/agent-session-summary/v1",
    "approval-request.schema.json": "hoverpocket://schemas/approval-request/v1",
    "capability-descriptor.schema.json": "hoverpocket://schemas/capability-descriptor/v1",
    "error.schema.json": "hoverpocket://schemas/error/v1",
    "execution-plan.schema.json": "hoverpocket://schemas/execution-plan/v1",
    "invocation.schema.json": "hoverpocket://schemas/invocation/v1",
    "pocket-app.schema.json": "hoverpocket://schemas/pocket-app/v1",
    "pocket-app-generation-output.schema.json": "hoverpocket://schemas/pocket-app-generation-output/v1",
    "pocket-surface.schema.json": "hoverpocket://schemas/pocket-surface/v1",
    "pocket-workflow.schema.json": "hoverpocket://schemas/pocket-workflow/v1",
    "receipt.schema.json": "hoverpocket://schemas/receipt/v1",
    "voice-lane-state.schema.json": "hoverpocket://schemas/voice-lane-state/v1",
    "voice-transcript-event.schema.json": "hoverpocket://schemas/voice-transcript-event/v1",
}

SUPPORTED_SCHEMA_KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "$defs",
        "$ref",
        "title",
        "type",
        "required",
        "properties",
        "additionalProperties",
        "propertyNames",
        "oneOf",
        "const",
        "enum",
        "items",
        "minItems",
        "maxItems",
        "uniqueItems",
        "minLength",
        "maxLength",
        "pattern",
        "format",
        "minimum",
        "maximum",
        "default",
    }
)

STABLE_ERROR_CODES = (
    "APP_CONTEXT_MISMATCH",
    "APP_PATH_UNSAFE",
    "APP_REFERENCE_INVALID",
    "APP_WORKSPACE_POLICY",
    "APPROVAL_EXPIRED",
    "APPROVAL_PLAN_MISMATCH",
    "AUDIT_BINDING_MISMATCH",
    "AUDIT_FORBIDDEN_FIELD",
    "AUDIT_KEYSET_MISMATCH",
    "AUDIT_VALUE_UNSAFE",
    "CAPABILITY_ARGUMENT_INVALID",
    "CAPABILITY_DESCRIPTOR_POLICY",
    "CAPABILITY_RUNTIME_PROHIBITED",
    "CAPABILITY_UNKNOWN",
    "CAPABILITY_VERSION_MISMATCH",
    "FIXTURE_DIGEST_MISMATCH",
    "FIXTURE_MANIFEST_MISMATCH",
    "GEOMETRY_EXPANSION_DIRECTION",
    "GEOMETRY_FULLSCREEN_FORBIDDEN",
    "GEOMETRY_OVERLAP",
    "GEOMETRY_PROVIDER_RECT_INVARIANT",
    "GEOMETRY_SHELL_TOP_INVARIANT",
    "GEOMETRY_TOKEN_MISMATCH",
    "PLAN_APPROVAL_REQUIRED",
    "PLAN_DEPENDENCY_INVALID",
    "PLAN_DIGEST_MISMATCH",
    "PLAN_PERMISSION_MISMATCH",
    "RECEIPT_BINDING_MISMATCH",
    "RECEIPT_OUTPUT_INVALID",
    "RECEIPT_READBACK_REQUIRED",
    "SCHEMA_ADDITIONAL_PROPERTY",
    "SCHEMA_CONST_MISMATCH",
    "SCHEMA_FORMAT_INVALID",
    "SCHEMA_ONE_OF_MISMATCH",
    "SCHEMA_POLICY_VIOLATION",
    "SCHEMA_REQUIRED_PROPERTY",
    "SCHEMA_TYPE_MISMATCH",
    "SCHEMA_VALUE_INVALID",
    "SESSION_SUMMARY_UNSAFE",
    "VOICE_DISABLED_STATE_INVALID",
    "VOICE_FULLSCREEN_FORBIDDEN",
    "VOICE_ROOT_SCOPE_VIOLATION",
    "VOICE_VISIBLE_COUNT_MISMATCH",
    "WORKFLOW_APPROVAL_REQUIRED",
    "WORKFLOW_DEPENDENCY_INVALID",
    "WORKFLOW_INPUT_TYPE_MISMATCH",
    "WORKFLOW_LIMIT_INVALID",
    "WORKFLOW_REFERENCE_INVALID",
)

AUDIT_ALLOWED_KEYS = (
    "approvalDecision",
    "approvalPolicy",
    "auditEntryId",
    "capability",
    "durationMs",
    "idempotencyReplay",
    "inputDigest",
    "invocationId",
    "origin",
    "permissionDecision",
    "pocketApp",
    "principalPseudonym",
    "readback",
    "retryCount",
    "safeErrorCode",
    "status",
    "timestamp",
    "traceId",
)

AUDIT_FORBIDDEN_KEYS = (
    "arguments",
    "authorization",
    "calendarLocation",
    "calendarNotes",
    "calendarTitle",
    "clipboardContent",
    "filesystemPath",
    "oauthToken",
    "output",
    "processCommandLine",
    "rawException",
    "rawTranscript",
    "sourcePrompt",
    "stickyBody",
)

BASELINE_DIMENSIONS: dict[str, tuple[int, int]] = {
    "small": (520, 372),
    "medium": (600, 430),
    "large": (680, 488),
    "extraLarge": (760, 546),
}
EXPANDED_HEIGHTS: dict[str, int] = {
    "small": 190,
    "medium": 220,
    "large": 250,
    "extraLarge": 280,
}
COMPACT_HEIGHT = 64
HEADER_HEIGHT = 54
MAX_APPROVAL_LIFETIME_SECONDS = 600
MAX_SURFACE_DEPTH = 16
MAX_SURFACE_NODES = 256
MAX_SCHEMA_DEPTH = 128

STABLE_KEY_PATTERN = re.compile(
    r"^[a-z][a-z0-9-]{0,31}:[A-Za-z0-9][A-Za-z0-9._-]{0,62}$",
    re.ASCII,
)


def valid_stable_key(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) <= 96
        and value.isascii()
        and STABLE_KEY_PATTERN.fullmatch(value) is not None
    )


V1_CONTEXT_BINDINGS = {
    "today": "string",
    "selectedEvent.title": "string",
    "todayFocusStableKey": "string",
    "timezone": "string",
}

V1_CONTEXT_SAMPLES = {
    "today": "2026-08-15",
    "selectedEvent.title": "Focus",
    "todayFocusStableKey": "today-focus:2026-08-15",
    "timezone": "Etc/UTC",
}

V1_CAPABILITY_SCOPES: Mapping[str, tuple[str, ...]] = {
    "calendar.events.list": ("range",),
    "sticky.note.get": ("namespace",),
    "sticky.note.upsert": ("namespace",),
    "system.native.authority": (),
    "timer.countdown.get": (),
    "timer.countdown.start": (),
}

WRITE_EFFECTS = frozenset(
    {
        "reversible_local_write",
        "external_write",
        "destructive_sensitive",
        "native_authority",
    }
)

EXPECTED_APPROVAL_POLICY = {
    "pure": "none",
    "private_read": "permission_grant",
    "reversible_local_write": "broker_policy",
    "external_write": "per_call",
    "destructive_sensitive": "strong_per_call",
    "native_authority": "runtime_prohibited",
}

EXPECTED_IDEMPOTENCY = {
    "pure": frozenset({"not_applicable", "optional"}),
    "private_read": frozenset({"not_applicable", "optional"}),
    "reversible_local_write": frozenset({"required"}),
    "external_write": frozenset({"required"}),
    "destructive_sensitive": frozenset({"required"}),
    "native_authority": frozenset({"required"}),
}

SAFE_RUNTIME_ERROR_FIELDS = frozenset(
    {
        "field",
        "expected",
        "actual",
        "capabilityId",
        "capabilityVersion",
        "traceId",
        "reasonKey",
    }
)

SAFE_RECEIPT_ERROR_CODES = frozenset(
    {
        "APPROVAL_REJECTED",
        "CAPABILITY_RUNTIME_PROHIBITED",
        "EXECUTION_FAILED",
        "PERMISSION_DENIED",
        "READBACK_MISMATCH",
    }
)


class DuplicateKeyError(ValueError):
    pass


@dataclass(frozen=True)
class VerifyError(Exception):
    code: str
    location: str
    detail: str

    def __str__(self) -> str:
        return f"{self.code} at {self.location}: {self.detail}"


@dataclass(frozen=True)
class CapabilityRegistry:
    by_key: Mapping[tuple[str, int], Mapping[str, Any]]
    versions_by_id: Mapping[str, tuple[int, ...]]

    def resolve(self, capability_id: str, version: int, location: str) -> Mapping[str, Any]:
        descriptor = self.by_key.get((capability_id, version))
        if descriptor is not None:
            return descriptor
        if capability_id not in self.versions_by_id:
            fail("CAPABILITY_UNKNOWN", location, f"unknown capability {capability_id!r}")
        versions = ",".join(str(item) for item in self.versions_by_id[capability_id])
        fail(
            "CAPABILITY_VERSION_MISMATCH",
            location,
            f"capability {capability_id!r} has version(s) {versions}, not {version}",
        )


@dataclass(frozen=True)
class FixtureContext:
    contract_dir: Path
    fixture_dir: Path
    schemas_by_filename: Mapping[str, Mapping[str, Any]]
    schemas_by_id: Mapping[str, Mapping[str, Any]]
    registry: CapabilityRegistry
    plans_by_id: Mapping[str, Mapping[str, Any]]
    invocations_by_id: Mapping[str, Mapping[str, Any]]
    app_workflow_ids: frozenset[str]
    app_requested_capabilities: Mapping[tuple[str, int], Mapping[str, Any]]
    reference_app: Mapping[str, Any] | None
    app_package_files: frozenset[str]
    host_observations: Mapping[str, Mapping[str, Any]]


@dataclass(frozen=True)
class FixtureSupport:
    plans_by_id: Mapping[str, Mapping[str, Any]]
    invocations_by_id: Mapping[str, Mapping[str, Any]]
    reference_app: Mapping[str, Any]
    workflows_by_id: Mapping[str, Mapping[str, Any]]
    surfaces_by_id: Mapping[str, Mapping[str, Any]]


@dataclass(frozen=True)
class CaseResult:
    case_id: str
    expected: str
    observed: str
    matched: bool
    error_code: str | None
    error_location: str | None

    def to_json(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "id": self.case_id,
            "expected": self.expected,
            "observed": self.observed,
            "matched": self.matched,
        }
        if self.error_code is not None:
            result["errorCode"] = self.error_code
        if self.error_location is not None:
            result["errorLocation"] = self.error_location
        return result


def fail(code: str, location: str, detail: str) -> NoReturn:
    if code not in STABLE_ERROR_CODES:
        raise RuntimeError(f"verifier used undeclared error code {code!r}")
    raise VerifyError(code, location, detail)


def duplicate_key_hook(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate object key {key!r}")
        result[key] = value
    return result


def reject_non_finite(token: str) -> NoReturn:
    raise ValueError(f"non-finite JSON number {token!r}")


def load_json(path: Path, *, location: str | None = None) -> Any:
    label = location or path.name
    try:
        raw = path.read_bytes()
    except OSError as exc:
        fail("FIXTURE_MANIFEST_MISMATCH", label, f"cannot read JSON file: {exc.__class__.__name__}")
    if raw.startswith(b"\xef\xbb\xbf"):
        fail("SCHEMA_POLICY_VIOLATION", label, "UTF-8 BOM is not permitted")
    try:
        text = raw.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=duplicate_key_hook,
            parse_constant=reject_non_finite,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, DuplicateKeyError, ValueError) as exc:
        fail("SCHEMA_VALUE_INVALID", label, f"invalid deterministic JSON: {exc}")


def canonical_bytes(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        fail("SCHEMA_VALUE_INVALID", "$", f"value is not canonical JSON: {exc}")


def digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_bytes(value)).hexdigest()


def semantic_json_key(value: Any) -> Any:
    """Return a hashable key using JSON Schema equality semantics.

    JSON booleans remain distinct from numbers, while mathematically equal JSON
    numbers such as 1 and 1.0 compare equal. Object member order is irrelevant.
    """
    if value is None:
        return ("null",)
    if isinstance(value, bool):
        return ("boolean", value)
    if isinstance(value, (int, float)):
        if not math.isfinite(float(value)):
            fail("SCHEMA_VALUE_INVALID", "$", "non-finite number cannot be compared")
        return ("number", Decimal(str(value)))
    if isinstance(value, str):
        return ("string", value)
    if isinstance(value, list):
        return ("array", tuple(semantic_json_key(item) for item in value))
    if isinstance(value, dict):
        return (
            "object",
            tuple((key, semantic_json_key(value[key])) for key in sorted(value)),
        )
    fail("SCHEMA_VALUE_INVALID", "$", f"unsupported JSON value type {type(value).__name__}")


def json_equal(left: Any, right: Any) -> bool:
    return semantic_json_key(left) == semantic_json_key(right)


def json_pointer_token(token: str) -> str:
    return token.replace("~1", "/").replace("~0", "~")


def safe_location(parent: str, token: str | int) -> str:
    if isinstance(token, int):
        return f"{parent}[{token}]"
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token):
        return f"{parent}.{token}"
    return f"{parent}[{json.dumps(token, ensure_ascii=False)}]"


def schema_type_matches(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
        )
    if expected == "string":
        return isinstance(value, str)
    if expected == "array":
        return isinstance(value, list)
    if expected == "object":
        return isinstance(value, dict)
    return False


def parse_rfc3339(value: str, location: str) -> datetime:
    pattern = re.compile(
        r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"
    )
    if not pattern.fullmatch(value):
        fail("SCHEMA_FORMAT_INVALID", location, "expected an RFC 3339 date-time with an explicit offset")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        fail("SCHEMA_FORMAT_INVALID", location, "invalid calendar date-time")
    if parsed.tzinfo is None:
        fail("SCHEMA_FORMAT_INVALID", location, "date-time has no timezone offset")
    return parsed.astimezone(timezone.utc)


def validate_format(value: Any, format_name: str, location: str) -> None:
    if not isinstance(value, str):
        return
    if format_name == "date-time":
        parse_rfc3339(value, location)
        return
    if format_name == "date":
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            fail("SCHEMA_FORMAT_INVALID", location, "expected YYYY-MM-DD")
        try:
            datetime.strptime(value, "%Y-%m-%d")
        except ValueError:
            fail("SCHEMA_FORMAT_INVALID", location, "invalid calendar date")
        return
    if format_name == "uuid":
        if not re.fullmatch(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}",
            value,
        ):
            fail("SCHEMA_FORMAT_INVALID", location, "expected an RFC 4122 UUID")
        return
    fail("SCHEMA_POLICY_VIOLATION", location, f"unsupported format {format_name!r}")


class SchemaEngine:
    def __init__(self, schemas_by_id: Mapping[str, Mapping[str, Any]]) -> None:
        self._schemas_by_id = schemas_by_id

    def validate(
        self,
        instance: Any,
        schema: Mapping[str, Any],
        *,
        document: Mapping[str, Any],
        location: str = "$",
        depth: int = 0,
    ) -> None:
        if depth > MAX_SCHEMA_DEPTH:
            fail("SCHEMA_POLICY_VIOLATION", location, "schema recursion limit exceeded")

        ref = schema.get("$ref")
        if ref is not None:
            target, target_document = self._resolve_ref(ref, document, location)
            self.validate(
                instance,
                target,
                document=target_document,
                location=location,
                depth=depth + 1,
            )

        if "oneOf" in schema:
            matches = 0
            for candidate in schema["oneOf"]:
                try:
                    self.validate(
                        instance,
                        candidate,
                        document=document,
                        location=location,
                        depth=depth + 1,
                    )
                except VerifyError:
                    continue
                matches += 1
            if matches != 1:
                fail(
                    "SCHEMA_ONE_OF_MISMATCH",
                    location,
                    f"expected exactly one oneOf branch, matched {matches}",
                )

        if "type" in schema:
            expected_types = schema["type"]
            if isinstance(expected_types, str):
                expected = (expected_types,)
            else:
                expected = tuple(expected_types)
            if not any(schema_type_matches(instance, item) for item in expected):
                fail(
                    "SCHEMA_TYPE_MISMATCH",
                    location,
                    "expected " + "|".join(expected),
                )

        if "const" in schema and not json_equal(instance, schema["const"]):
            fail("SCHEMA_CONST_MISMATCH", location, "value does not match const")

        if "enum" in schema and not any(json_equal(instance, item) for item in schema["enum"]):
            fail("SCHEMA_VALUE_INVALID", location, "value is not in enum")

        if isinstance(instance, dict):
            required = schema.get("required", [])
            for key in required:
                if key not in instance:
                    fail(
                        "SCHEMA_REQUIRED_PROPERTY",
                        safe_location(location, key),
                        "required property is missing",
                    )

            properties = schema.get("properties", {})
            additional = schema.get("additionalProperties", True)
            for key, value in instance.items():
                child_location = safe_location(location, key)
                if key in properties:
                    self.validate(
                        value,
                        properties[key],
                        document=document,
                        location=child_location,
                        depth=depth + 1,
                    )
                elif additional is False:
                    fail(
                        "SCHEMA_ADDITIONAL_PROPERTY",
                        child_location,
                        "property is not allowed",
                    )
                elif isinstance(additional, dict):
                    self.validate(
                        value,
                        additional,
                        document=document,
                        location=child_location,
                        depth=depth + 1,
                    )

            if "propertyNames" in schema:
                for key in instance:
                    self.validate(
                        key,
                        schema["propertyNames"],
                        document=document,
                        location=safe_location(location, key),
                        depth=depth + 1,
                    )

        if isinstance(instance, list):
            if "minItems" in schema and len(instance) < schema["minItems"]:
                fail("SCHEMA_VALUE_INVALID", location, "array has too few items")
            if "maxItems" in schema and len(instance) > schema["maxItems"]:
                fail("SCHEMA_VALUE_INVALID", location, "array has too many items")
            if schema.get("uniqueItems"):
                seen: set[Any] = set()
                for index, item in enumerate(instance):
                    token = semantic_json_key(item)
                    if token in seen:
                        fail(
                            "SCHEMA_VALUE_INVALID",
                            safe_location(location, index),
                            "array item is not unique",
                        )
                    seen.add(token)
            if "items" in schema:
                for index, item in enumerate(instance):
                    self.validate(
                        item,
                        schema["items"],
                        document=document,
                        location=safe_location(location, index),
                        depth=depth + 1,
                    )

        if isinstance(instance, str):
            if "minLength" in schema and len(instance) < schema["minLength"]:
                fail("SCHEMA_VALUE_INVALID", location, "string is shorter than minLength")
            if "maxLength" in schema and len(instance) > schema["maxLength"]:
                fail("SCHEMA_VALUE_INVALID", location, "string is longer than maxLength")
            if "pattern" in schema:
                try:
                    matched = re.search(schema["pattern"], instance) is not None
                except re.error as exc:
                    fail("SCHEMA_POLICY_VIOLATION", location, f"invalid schema regex: {exc}")
                if not matched:
                    fail("SCHEMA_VALUE_INVALID", location, "string does not match pattern")
            if "format" in schema:
                validate_format(instance, schema["format"], location)

        if (
            isinstance(instance, (int, float))
            and not isinstance(instance, bool)
            and math.isfinite(float(instance))
        ):
            if "minimum" in schema and instance < schema["minimum"]:
                fail("SCHEMA_VALUE_INVALID", location, "number is below minimum")
            if "maximum" in schema and instance > schema["maximum"]:
                fail("SCHEMA_VALUE_INVALID", location, "number is above maximum")

    def _resolve_ref(
        self,
        ref: Any,
        document: Mapping[str, Any],
        location: str,
    ) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
        if not isinstance(ref, str):
            fail("SCHEMA_POLICY_VIOLATION", location, "$ref must be a string")
        if ref.startswith("#"):
            target_document = document
            fragment = ref[1:]
        else:
            if "#" in ref:
                base, fragment = ref.split("#", 1)
            else:
                base, fragment = ref, ""
            target_document = self._schemas_by_id.get(base)
            if target_document is None:
                fail("SCHEMA_POLICY_VIOLATION", location, f"unresolved local schema id {base!r}")
        target: Any = target_document
        if fragment:
            if not fragment.startswith("/"):
                fail("SCHEMA_POLICY_VIOLATION", location, f"unsupported $ref fragment {fragment!r}")
            for token in fragment[1:].split("/"):
                key = json_pointer_token(token)
                if not isinstance(target, dict) or key not in target:
                    fail("SCHEMA_POLICY_VIOLATION", location, f"unresolved $ref {ref!r}")
                target = target[key]
        if not isinstance(target, dict):
            fail("SCHEMA_POLICY_VIOLATION", location, f"$ref target is not a schema object: {ref!r}")
        return target, target_document


def schema_nodes(schema: Mapping[str, Any]) -> Iterable[tuple[str, Mapping[str, Any]]]:
    stack: list[tuple[str, Mapping[str, Any]]] = [("$", schema)]
    while stack:
        location, node = stack.pop()
        yield location, node
        for container_name in ("properties", "$defs"):
            container = node.get(container_name)
            if isinstance(container, dict):
                for key in sorted(container, reverse=True):
                    child = container[key]
                    if isinstance(child, dict):
                        stack.append((safe_location(safe_location(location, container_name), key), child))
        for key in ("additionalProperties", "propertyNames", "items"):
            child = node.get(key)
            if isinstance(child, dict):
                stack.append((safe_location(location, key), child))
        one_of = node.get("oneOf")
        if isinstance(one_of, list):
            for index in reversed(range(len(one_of))):
                child = one_of[index]
                if isinstance(child, dict):
                    stack.append((safe_location(safe_location(location, "oneOf"), index), child))


def enforce_schema_policy(
    schema: Mapping[str, Any],
    *,
    label: str,
    schemas_by_id: Mapping[str, Mapping[str, Any]],
    require_document_header: bool,
) -> None:
    if require_document_header:
        if schema.get("$schema") != DRAFT_2020_12:
            fail("SCHEMA_POLICY_VIOLATION", label, "schema must declare Draft 2020-12")
        if not isinstance(schema.get("$id"), str):
            fail("SCHEMA_POLICY_VIOLATION", label, "schema must declare a stable $id")

    engine = SchemaEngine(schemas_by_id)
    for location, node in schema_nodes(schema):
        node_location = f"{label}:{location}"
        unknown = sorted(set(node) - SUPPORTED_SCHEMA_KEYWORDS)
        if unknown:
            fail(
                "SCHEMA_POLICY_VIOLATION",
                node_location,
                f"unsupported schema keyword(s): {','.join(unknown)}",
            )

        for string_keyword in ("$schema", "$id", "$ref", "title", "pattern", "format"):
            if string_keyword in node and not isinstance(node[string_keyword], str):
                fail("SCHEMA_POLICY_VIOLATION", node_location, f"{string_keyword} must be a string")

        for container_name in ("properties", "$defs"):
            if container_name in node:
                container = node[container_name]
                if not isinstance(container, dict) or any(not isinstance(value, dict) for value in container.values()):
                    fail("SCHEMA_POLICY_VIOLATION", node_location, f"{container_name} must map names to schema objects")

        additional = node.get("additionalProperties")
        if "additionalProperties" in node and not isinstance(additional, (bool, dict)):
            fail("SCHEMA_POLICY_VIOLATION", node_location, "additionalProperties must be false or a schema object")
        if additional is True:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "additionalProperties: true is forbidden")

        for child_keyword in ("propertyNames", "items"):
            if child_keyword in node and not isinstance(node[child_keyword], dict):
                fail("SCHEMA_POLICY_VIOLATION", node_location, f"{child_keyword} must be a schema object")

        object_like = node.get("type") == "object" or (
            isinstance(node.get("type"), list) and "object" in node["type"]
        ) or "properties" in node
        if object_like and "additionalProperties" not in node:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "object schema must state additionalProperties explicitly")

        if "$ref" in node:
            engine._resolve_ref(node["$ref"], schema, node_location)

        declared_types: list[str] = []
        if "type" in node:
            type_value = node["type"]
            valid_types = {"null", "boolean", "integer", "number", "string", "array", "object"}
            if isinstance(type_value, str):
                declared_types = [type_value]
            elif isinstance(type_value, list) and type_value:
                declared_types = type_value
            else:
                fail("SCHEMA_POLICY_VIOLATION", node_location, "type must be a string or non-empty array")
            if any(not isinstance(item, str) or item not in valid_types for item in declared_types):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "type contains an unsupported value")
            if len(set(declared_types)) != len(declared_types):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "type array contains duplicates")

        if "properties" in node and "object" not in declared_types:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "properties requires object in type")
        if "items" in node and "array" not in declared_types:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "items requires array in type")
        if "array" in declared_types and "items" not in node:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "array schema must state items explicitly")

        if "required" in node:
            required = node["required"]
            if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "required must be a string array")
            if len(set(required)) != len(required):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "required contains duplicates")
            properties = node.get("properties")
            if not isinstance(properties, dict) or any(item not in properties for item in required):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "required names a missing property schema")

        if "oneOf" in node:
            one_of = node["oneOf"]
            if not isinstance(one_of, list) or len(one_of) < 2 or any(not isinstance(item, dict) for item in one_of):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "oneOf must contain at least two schema objects")

        if "enum" in node:
            enum = node["enum"]
            if not isinstance(enum, list) or not enum:
                fail("SCHEMA_POLICY_VIOLATION", node_location, "enum must be a non-empty array")
            keys = [semantic_json_key(item) for item in enum]
            if len(set(keys)) != len(keys):
                fail("SCHEMA_POLICY_VIOLATION", node_location, "enum contains JSON-equal duplicate values")

        if "format" in node and node["format"] not in {"date", "date-time", "uuid"}:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "unsupported format")
        if "pattern" in node:
            try:
                re.compile(node["pattern"])
            except re.error as exc:
                fail("SCHEMA_POLICY_VIOLATION", node_location, f"invalid regex pattern: {exc}")

        for keyword in ("minLength", "maxLength", "minItems", "maxItems"):
            if keyword in node and (
                not isinstance(node[keyword], int)
                or isinstance(node[keyword], bool)
                or node[keyword] < 0
            ):
                fail("SCHEMA_POLICY_VIOLATION", node_location, f"{keyword} must be a non-negative integer")
        if "minLength" in node and "maxLength" in node and node["minLength"] > node["maxLength"]:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "minLength exceeds maxLength")
        if "minItems" in node and "maxItems" in node and node["minItems"] > node["maxItems"]:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "minItems exceeds maxItems")
        if "uniqueItems" in node and not isinstance(node["uniqueItems"], bool):
            fail("SCHEMA_POLICY_VIOLATION", node_location, "uniqueItems must be boolean")

        for keyword in ("minimum", "maximum"):
            if keyword in node and (
                not isinstance(node[keyword], (int, float))
                or isinstance(node[keyword], bool)
                or not math.isfinite(float(node[keyword]))
            ):
                fail("SCHEMA_POLICY_VIOLATION", node_location, f"{keyword} must be a finite number")
        if "minimum" in node and "maximum" in node and node["minimum"] > node["maximum"]:
            fail("SCHEMA_POLICY_VIOLATION", node_location, "minimum exceeds maximum")


def load_schemas(contract_dir: Path) -> tuple[dict[str, Mapping[str, Any]], dict[str, Mapping[str, Any]]]:
    actual_files = sorted(path.name for path in contract_dir.glob("*.schema.json"))
    expected_files = sorted(EXPECTED_SCHEMAS)
    if actual_files != expected_files:
        fail(
            "SCHEMA_POLICY_VIOLATION",
            "contracts/pocket/v1",
            f"expected exactly {len(expected_files)} schemas; expected={expected_files}, actual={actual_files}",
        )

    by_filename: dict[str, Mapping[str, Any]] = {}
    by_id: dict[str, Mapping[str, Any]] = {}
    for filename in expected_files:
        document = load_json(contract_dir / filename, location=filename)
        if not isinstance(document, dict):
            fail("SCHEMA_POLICY_VIOLATION", filename, "schema document must be an object")
        expected_id = EXPECTED_SCHEMAS[filename]
        if document.get("$id") != expected_id:
            fail("SCHEMA_POLICY_VIOLATION", filename, f"expected $id {expected_id!r}")
        if expected_id in by_id:
            fail("SCHEMA_POLICY_VIOLATION", filename, "duplicate schema $id")
        by_filename[filename] = document
        by_id[expected_id] = document

    for filename, document in by_filename.items():
        enforce_schema_policy(
            document,
            label=filename,
            schemas_by_id=by_id,
            require_document_header=True,
        )
        if document.get("type") != "object" or document.get("additionalProperties") is not False:
            fail("SCHEMA_POLICY_VIOLATION", filename, "root schema must be a strict object")

    return by_filename, by_id


def normalize_relative_path(value: str, location: str) -> str:
    if "\\" in value or value.startswith("/") or re.match(r"^[A-Za-z]:", value):
        fail("APP_PATH_UNSAFE", location, "path must be portable POSIX-relative")
    pure = PurePosixPath(value)
    if not value or any(part in {"", ".", ".."} for part in pure.parts):
        fail("APP_PATH_UNSAFE", location, "path contains an empty, dot, or parent segment")
    normalized = pure.as_posix()
    if normalized != value:
        fail("APP_PATH_UNSAFE", location, "path is not canonically normalized")
    return normalized


def contains_unsafe_text(value: str) -> bool:
    if any(ord(char) < 32 and char not in {"\t"} for char in value):
        return True
    probes = (
        "/Users/",
        "/home/",
        "C:\\",
        "Authorization:",
        "Bearer ",
        "sk-",
        "oauth_token",
        "raw transcript",
        "https://",
        "http://",
    )
    lowered = value.lower()
    return any(probe.lower() in lowered for probe in probes) or re.search(
        r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", value
    ) is not None


def descriptor_properties(descriptor: Mapping[str, Any], field: str) -> Mapping[str, Any]:
    schema = descriptor[field]
    properties = schema.get("properties")
    return properties if isinstance(properties, dict) else {}


def validate_embedded_schema(
    schema: Mapping[str, Any],
    *,
    descriptor_label: str,
    schemas_by_id: Mapping[str, Mapping[str, Any]],
) -> None:
    enforce_schema_policy(
        schema,
        label=descriptor_label,
        schemas_by_id=schemas_by_id,
        require_document_header=False,
    )
    if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
        fail("CAPABILITY_DESCRIPTOR_POLICY", descriptor_label, "capability input/output must be a strict object schema")


def validate_descriptor_semantics(
    descriptor: Mapping[str, Any],
    *,
    location: str,
    schemas_by_id: Mapping[str, Mapping[str, Any]],
    registry: CapabilityRegistry | None = None,
) -> None:
    effect = descriptor["effect"]
    expected_approval = EXPECTED_APPROVAL_POLICY[effect]
    if descriptor["approvalPolicy"] != expected_approval:
        fail(
            "CAPABILITY_DESCRIPTOR_POLICY",
            safe_location(location, "approvalPolicy"),
            f"effect {effect!r} requires approval policy {expected_approval!r}",
        )
    if descriptor["idempotency"] not in EXPECTED_IDEMPOTENCY[effect]:
        fail(
            "CAPABILITY_DESCRIPTOR_POLICY",
            safe_location(location, "idempotency"),
            f"idempotency policy is unsafe for effect {effect!r}",
        )
    if effect != "pure" and not descriptor["permissions"]:
        fail("CAPABILITY_DESCRIPTOR_POLICY", safe_location(location, "permissions"), "non-pure capability requires a permission")
    expected_title = "capability." + descriptor["id"]
    if descriptor["titleKey"] != expected_title:
        fail("CAPABILITY_DESCRIPTOR_POLICY", safe_location(location, "titleKey"), f"expected {expected_title!r}")

    validate_embedded_schema(
        descriptor["inputSchema"],
        descriptor_label=f"{location}.inputSchema",
        schemas_by_id=schemas_by_id,
    )
    validate_embedded_schema(
        descriptor["outputSchema"],
        descriptor_label=f"{location}.outputSchema",
        schemas_by_id=schemas_by_id,
    )

    readback = descriptor["readback"]
    strategy = readback["strategy"]
    if effect in WRITE_EFFECTS and strategy == "none":
        fail("CAPABILITY_DESCRIPTOR_POLICY", f"{location}.readback", "side-effect capability cannot omit readback")
    if strategy == "capability_query":
        if "capabilityId" not in readback or "capabilityVersion" not in readback:
            fail("CAPABILITY_DESCRIPTOR_POLICY", f"{location}.readback", "capability_query requires id and version")
    elif "capabilityId" in readback or "capabilityVersion" in readback:
        fail("CAPABILITY_DESCRIPTOR_POLICY", f"{location}.readback", "readback capability is only valid for capability_query")
    if strategy != "none" and not readback["match"]:
        fail("CAPABILITY_DESCRIPTOR_POLICY", f"{location}.readback.match", "readback must name compared fields")

    output_properties = descriptor_properties(descriptor, "outputSchema")
    missing_match = [field for field in readback["match"] if field not in output_properties]
    if missing_match:
        fail(
            "CAPABILITY_DESCRIPTOR_POLICY",
            f"{location}.readback.match",
            "readback fields are absent from outputSchema: " + ",".join(missing_match),
        )
    if registry is not None and strategy == "capability_query":
        target = registry.resolve(readback["capabilityId"], readback["capabilityVersion"], f"{location}.readback")
        if target["effect"] not in {"pure", "private_read"}:
            fail("CAPABILITY_DESCRIPTOR_POLICY", f"{location}.readback", "readback target must be read-only")
        target_output = descriptor_properties(target, "outputSchema")
        if any(field not in target_output for field in readback["match"]):
            fail("CAPABILITY_DESCRIPTOR_POLICY", f"{location}.readback.match", "readback target lacks a matched field")


def load_registry(
    fixture_dir: Path,
    registry_relative_path: str,
    schemas_by_filename: Mapping[str, Mapping[str, Any]],
    schemas_by_id: Mapping[str, Mapping[str, Any]],
) -> CapabilityRegistry:
    registry_path = fixture_dir / registry_relative_path
    registry_data = load_json(registry_path, location=registry_relative_path)
    if not isinstance(registry_data, dict) or set(registry_data) != {"registryVersion", "capabilities"}:
        fail("FIXTURE_MANIFEST_MISMATCH", registry_relative_path, "registry has an unexpected shape")
    if registry_data["registryVersion"] != 1 or not isinstance(registry_data["capabilities"], list):
        fail("FIXTURE_MANIFEST_MISMATCH", registry_relative_path, "registry version or capabilities is invalid")

    descriptor_schema = schemas_by_filename["capability-descriptor.schema.json"]
    engine = SchemaEngine(schemas_by_id)
    by_key: dict[tuple[str, int], Mapping[str, Any]] = {}
    versions: dict[str, list[int]] = {}
    previous_key: tuple[str, int] | None = None
    descriptor_paths: set[str] = set()

    for index, item in enumerate(registry_data["capabilities"]):
        location = f"{registry_relative_path}.capabilities[{index}]"
        if not isinstance(item, dict) or set(item) != {"id", "version", "descriptor"}:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "registry entry must contain id, version, descriptor")
        if not isinstance(item["id"], str) or not isinstance(item["version"], int) or isinstance(item["version"], bool):
            fail("FIXTURE_MANIFEST_MISMATCH", location, "registry id/version types are invalid")
        descriptor_relative = normalize_relative_path(item["descriptor"], f"{location}.descriptor")
        if not descriptor_relative.startswith("valid/capability-descriptor.") or not descriptor_relative.endswith(".json"):
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.descriptor", "registry descriptor must be a valid descriptor fixture")
        descriptor_paths.add(descriptor_relative)
        descriptor = load_json(fixture_dir / descriptor_relative, location=descriptor_relative)
        if not isinstance(descriptor, dict):
            fail("CAPABILITY_DESCRIPTOR_POLICY", descriptor_relative, "descriptor must be an object")
        engine.validate(descriptor, descriptor_schema, document=descriptor_schema)
        validate_descriptor_semantics(
            descriptor,
            location=descriptor_relative,
            schemas_by_id=schemas_by_id,
        )
        key = (item["id"], item["version"])
        if previous_key is not None and key <= previous_key:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "registry entries must be strictly sorted")
        previous_key = key
        if key in by_key:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "duplicate capability id/version")
        if descriptor["id"] != item["id"] or descriptor["version"] != item["version"]:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "registry entry does not match descriptor")
        by_key[key] = descriptor
        versions.setdefault(item["id"], []).append(item["version"])

    all_descriptor_paths = {
        path.relative_to(fixture_dir).as_posix()
        for path in (fixture_dir / "valid").glob("capability-descriptor.*.json")
    }
    if descriptor_paths != all_descriptor_paths:
        fail("FIXTURE_MANIFEST_MISMATCH", registry_relative_path, "registry must cover every descriptor fixture exactly once")

    registry = CapabilityRegistry(
        by_key=by_key,
        versions_by_id={key: tuple(sorted(value)) for key, value in versions.items()},
    )
    for key, descriptor in sorted(by_key.items()):
        validate_descriptor_semantics(
            descriptor,
            location=f"registry:{key[0]}@{key[1]}",
            schemas_by_id=schemas_by_id,
            registry=registry,
        )
    return registry


def validate_capability_payload(
    payload: Any,
    descriptor: Mapping[str, Any],
    field: str,
    location: str,
    schemas_by_id: Mapping[str, Mapping[str, Any]],
    error_code: str,
) -> None:
    engine = SchemaEngine(schemas_by_id)
    try:
        engine.validate(payload, descriptor[field], document=descriptor[field], location=location)
    except VerifyError as exc:
        fail(error_code, exc.location, f"{field} rejected: {exc.code}")


def ensure_capability_executable(descriptor: Mapping[str, Any], location: str) -> None:
    if descriptor["approvalPolicy"] == "runtime_prohibited" or descriptor["effect"] == "native_authority":
        fail(
            "CAPABILITY_RUNTIME_PROHIBITED",
            location,
            "native-authority capability cannot execute through the AN0 runtime",
        )


def validate_payload_size(payload: Any, descriptor: Mapping[str, Any], location: str) -> None:
    if len(canonical_bytes(payload)) > descriptor["limits"]["maxPayloadBytes"]:
        fail("CAPABILITY_ARGUMENT_INVALID", location, "canonical payload exceeds descriptor maxPayloadBytes")


def expected_app_context(context: FixtureContext) -> dict[str, Any]:
    app = context.reference_app
    if app is None:
        fail("APP_CONTEXT_MISMATCH", "$.appContext", "reference Pocket App context is unavailable")
    return {
        "id": app["id"],
        "version": app["version"],
        "manifestDigest": digest(app),
    }


def validate_app_context(
    value: Mapping[str, Any] | None,
    principal: Mapping[str, Any],
    context: FixtureContext,
    location: str,
) -> None:
    pocket_app_id = principal.get("pocketAppId")
    if pocket_app_id is None:
        if value is not None:
            fail("APP_CONTEXT_MISMATCH", location, "Host-native principal cannot claim a Pocket App context")
        return
    if value != expected_app_context(context) or value["id"] != pocket_app_id:
        fail("APP_CONTEXT_MISMATCH", location, "Pocket App id, version, or manifest digest changed")


def validate_capability_scope(
    arguments: Mapping[str, Any],
    scope: Mapping[str, Any],
    location: str,
) -> None:
    if "range" in scope and arguments.get("range") != scope["range"]:
        fail("APP_REFERENCE_INVALID", safe_location(location, "range"), "argument escapes the granted range scope")
    if "namespace" in scope:
        stable_key = arguments.get("stableKey")
        context_matches_namespace = (
            stable_key == "$context.todayFocusStableKey"
            and scope["namespace"] == "today-focus"
        )
        literal_matches_namespace = (
            valid_stable_key(stable_key)
            and stable_key.split(":", 1)[0] == scope["namespace"]
        )
        if not context_matches_namespace and not literal_matches_namespace:
            fail(
                "APP_REFERENCE_INVALID",
                safe_location(location, "stableKey"),
                "stable key escapes the granted namespace scope",
            )


def requested_scope(context: FixtureContext, capability_id: str, version: int, location: str) -> Mapping[str, Any]:
    request = context.app_requested_capabilities.get((capability_id, version))
    if request is None:
        fail("APP_REFERENCE_INVALID", location, "capability was not requested by its Pocket App")
    scope = request.get("scope", {})
    return scope if isinstance(scope, dict) else {}


def validate_invocation(document: Mapping[str, Any], context: FixtureContext) -> None:
    descriptor = context.registry.resolve(
        document["capabilityId"],
        document["capabilityVersion"],
        "$.capability",
    )
    ensure_capability_executable(descriptor, "$.capability")
    validate_app_context(document.get("appContext"), document["principal"], context, "$.appContext")
    plan = context.plans_by_id.get(document["planId"])
    if plan is None or document["planDigest"] != plan["canonicalDigest"]:
        fail("APP_CONTEXT_MISMATCH", "$.planDigest", "invocation is not bound to a known canonical plan")
    if document["principal"] != plan["principal"] or document.get("appContext") != plan.get("appContext"):
        fail("APP_CONTEXT_MISMATCH", "$", "invocation principal or app context differs from the plan")
    matching_steps = [
        step
        for step in plan["steps"]
        if step["capabilityId"] == document["capabilityId"]
        and step["capabilityVersion"] == document["capabilityVersion"]
        and step["arguments"] == document["arguments"]
        and step["idempotencyKey"] == document["idempotencyKey"]
    ]
    if len(matching_steps) != 1:
        fail("APP_CONTEXT_MISMATCH", "$.arguments", "invocation does not match exactly one approved plan step")
    validate_capability_payload(
        document["arguments"],
        descriptor,
        "inputSchema",
        "$.arguments",
        context.schemas_by_id,
        "CAPABILITY_ARGUMENT_INVALID",
    )
    validate_payload_size(document["arguments"], descriptor, "$.arguments")
    validate_capability_scope(
        document["arguments"],
        requested_scope(context, document["capabilityId"], document["capabilityVersion"], "$.capability"),
        "$.arguments",
    )


def plan_projection(plan: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "appContext": plan.get("appContext"),
        "planVersion": plan["planVersion"],
        "steps": [
            {
                "stepId": step["stepId"],
                "capabilityId": step["capabilityId"],
                "capabilityVersion": step["capabilityVersion"],
                "arguments": step["arguments"],
                "dependsOn": step["dependsOn"],
            }
            for step in plan["steps"]
        ],
        "approval": plan["approval"],
        "requiredPermissions": plan["requiredPermissions"],
    }


def validate_dependency_order(
    steps: Sequence[Mapping[str, Any]],
    *,
    id_field: str,
    depends_field: str,
    error_code: str,
    location: str,
) -> int:
    seen: set[str] = set()
    depth_by_id: dict[str, int] = {}
    for index, step in enumerate(steps):
        step_id = step[id_field]
        if step_id in seen:
            fail(error_code, f"{location}[{index}].{id_field}", "duplicate step id")
        dependencies = step[depends_field]
        for dependency in dependencies:
            if dependency not in seen:
                fail(error_code, f"{location}[{index}].{depends_field}", "dependency must reference an earlier step")
        depth_by_id[step_id] = 1 + max((depth_by_id[item] for item in dependencies), default=0)
        seen.add(step_id)
    return max(depth_by_id.values(), default=0)


def validate_execution_plan(document: Mapping[str, Any], context: FixtureContext) -> None:
    validate_app_context(document.get("appContext"), document["principal"], context, "$.appContext")
    validate_dependency_order(
        document["steps"],
        id_field="stepId",
        depends_field="dependsOn",
        error_code="PLAN_DEPENDENCY_INVALID",
        location="$.steps",
    )
    required_permissions: set[str] = set()
    has_writes = False
    idempotency_keys: set[str] = set()
    for index, step in enumerate(document["steps"]):
        descriptor = context.registry.resolve(
            step["capabilityId"],
            step["capabilityVersion"],
            f"$.steps[{index}].capability",
        )
        ensure_capability_executable(descriptor, f"$.steps[{index}].capability")
        if descriptor["approvalPolicy"] == "strong_per_call" and len(document["steps"]) != 1:
            fail(
                "PLAN_APPROVAL_REQUIRED",
                f"$.steps[{index}].capability",
                "strong_per_call capability must be the only plan step",
            )
        validate_capability_payload(
            step["arguments"],
            descriptor,
            "inputSchema",
            f"$.steps[{index}].arguments",
            context.schemas_by_id,
            "CAPABILITY_ARGUMENT_INVALID",
        )
        validate_payload_size(step["arguments"], descriptor, f"$.steps[{index}].arguments")
        validate_capability_scope(
            step["arguments"],
            requested_scope(context, step["capabilityId"], step["capabilityVersion"], f"$.steps[{index}].capability"),
            f"$.steps[{index}].arguments",
        )
        required_permissions.update(descriptor["permissions"])
        has_writes = has_writes or descriptor["effect"] in WRITE_EFFECTS
        if step["idempotencyKey"] in idempotency_keys:
            fail("PLAN_DEPENDENCY_INVALID", f"$.steps[{index}].idempotencyKey", "idempotency key is reused")
        idempotency_keys.add(step["idempotencyKey"])

    if document["requiredPermissions"] != sorted(required_permissions):
        fail("PLAN_PERMISSION_MISMATCH", "$.requiredPermissions", "permissions must equal the sorted descriptor union")
    approval = document["approval"]
    if has_writes:
        if approval["mode"] not in {"before_writes", "per_step"} or approval["group"] == "none":
            fail("PLAN_APPROVAL_REQUIRED", "$.approval", "write plan must require broker-owned approval")
    elif approval["mode"] != "none" or approval["group"] != "none":
        fail("PLAN_APPROVAL_REQUIRED", "$.approval", "read-only plan must not fabricate a write approval")
    if document["canonicalDigest"] != digest(plan_projection(document)):
        fail("PLAN_DIGEST_MISMATCH", "$.canonicalDigest", "digest does not match the route-independent canonical plan")


def validate_approval_request(document: Mapping[str, Any], context: FixtureContext) -> None:
    plan = context.plans_by_id.get(document["planId"])
    if plan is None:
        fail("APPROVAL_PLAN_MISMATCH", "$.planId", "approval references an unknown fixture plan")
    if (
        document["planDigest"] != plan["canonicalDigest"]
        or document["principal"] != plan["principal"]
        or document.get("appContext") != plan.get("appContext")
    ):
        fail("APPROVAL_PLAN_MISMATCH", "$", "approval is not bound to the plan digest, principal, and app version")
    validate_app_context(document.get("appContext"), document["principal"], context, "$.appContext")
    created = parse_rfc3339(document["createdAt"], "$.createdAt")
    expires = parse_rfc3339(document["expiresAt"], "$.expiresAt")
    lifetime = (expires - created).total_seconds()
    if lifetime <= 0 or lifetime > MAX_APPROVAL_LIFETIME_SECONDS:
        fail("APPROVAL_EXPIRED", "$.expiresAt", "approval lifetime must be positive and at most 10 minutes")

    expected_effects: list[dict[str, Any]] = []
    write_permissions: set[str] = set()
    for step in plan["steps"]:
        descriptor = context.registry.resolve(step["capabilityId"], step["capabilityVersion"], "$.effects")
        if descriptor["effect"] not in WRITE_EFFECTS:
            continue
        write_permissions.update(descriptor["permissions"])
        expected_effects.append(
            {
                "stepId": step["stepId"],
                "capabilityId": step["capabilityId"],
                "capabilityVersion": step["capabilityVersion"],
                "effect": descriptor["effect"],
                "argumentDigest": digest(step["arguments"]),
                "summaryKey": "approval." + step["capabilityId"],
                "rollbackAvailable": descriptor["effect"] == "reversible_local_write",
            }
        )
    if document["effects"] != expected_effects:
        fail("APPROVAL_PLAN_MISMATCH", "$.effects", "effects do not exactly match the write steps")
    if document["requiredPermissions"] != sorted(write_permissions):
        fail("APPROVAL_PLAN_MISMATCH", "$.requiredPermissions", "approval permissions do not match write effects")


def validate_receipt(document: Mapping[str, Any], context: FixtureContext) -> None:
    descriptor = context.registry.resolve(
        document["capability"]["id"],
        document["capability"]["version"],
        "$.capability",
    )
    invocation = context.invocations_by_id.get(document["invocationId"])
    if invocation is None:
        fail("RECEIPT_BINDING_MISMATCH", "$.invocationId", "receipt references an unknown invocation")
    if (
        document["planId"] != invocation["planId"]
        or document["planDigest"] != invocation["planDigest"]
        or document.get("appContext") != invocation.get("appContext")
        or document["capability"]
        != {"id": invocation["capabilityId"], "version": invocation["capabilityVersion"]}
    ):
        fail(
            "RECEIPT_BINDING_MISMATCH",
            "$",
            "receipt plan, app version, or capability differs from the invocation",
        )
    validate_app_context(document.get("appContext"), invocation["principal"], context, "$.appContext")
    status = document["status"]
    if status == "succeeded" and "output" not in document:
        fail("RECEIPT_OUTPUT_INVALID", "$.output", "successful receipt must include output")
    if "output" in document:
        validate_capability_payload(
            document["output"],
            descriptor,
            "outputSchema",
            "$.output",
            context.schemas_by_id,
            "RECEIPT_OUTPUT_INVALID",
        )
    readback = document["readback"]
    if readback["strategy"] != descriptor["readback"]["strategy"]:
        fail("RECEIPT_READBACK_REQUIRED", "$.readback.strategy", "receipt strategy differs from descriptor")
    if status == "succeeded":
        pure_without_readback = descriptor["effect"] == "pure" and readback["strategy"] == "none"
        if not pure_without_readback and readback["status"] != "verified":
            fail("RECEIPT_READBACK_REQUIRED", "$.readback.status", "success requires verified readback")
        if readback["status"] == "verified" and (
            "observedAt" not in readback
            or "evidenceDigest" not in readback
            or "observed" not in readback
        ):
            fail(
                "RECEIPT_READBACK_REQUIRED",
                "$.readback",
                "verified readback requires timestamp, typed observation, and evidence digest",
            )
        if "safeError" in document:
            fail("RECEIPT_OUTPUT_INVALID", "$.safeError", "successful receipt cannot carry a safe error")
    else:
        if "safeError" not in document:
            fail("RECEIPT_OUTPUT_INVALID", "$.safeError", "non-success receipt must carry a stable safe error")
        if document["safeError"]["code"] not in SAFE_RECEIPT_ERROR_CODES:
            fail("RECEIPT_OUTPUT_INVALID", "$.safeError.code", "safe error code is not in the v1 allowlist")
    if readback["status"] == "mismatch" and status == "succeeded":
        fail("RECEIPT_READBACK_REQUIRED", "$.status", "readback mismatch cannot be success")
    if readback["status"] == "unavailable" and descriptor["effect"] in WRITE_EFFECTS and status == "succeeded":
        fail("RECEIPT_READBACK_REQUIRED", "$.status", "unknown side effect cannot be success")
    if readback["status"] == "verified":
        observed = readback["observed"]
        host_observed = context.host_observations.get(document["invocationId"])
        if host_observed is None or observed != host_observed:
            fail(
                "RECEIPT_READBACK_REQUIRED",
                "$.readback.observed",
                "receipt observation differs from the Host-owned readback source",
            )
        if readback["evidenceDigest"] != digest(observed):
            fail("RECEIPT_READBACK_REQUIRED", "$.readback.evidenceDigest", "evidence digest was not computed from observed state")
        readback_descriptor = descriptor
        if readback["strategy"] == "capability_query":
            readback_descriptor = context.registry.resolve(
                descriptor["readback"]["capabilityId"],
                descriptor["readback"]["capabilityVersion"],
                "$.readback.observed",
            )
        validate_capability_payload(
            observed,
            readback_descriptor,
            "outputSchema",
            "$.readback.observed",
            context.schemas_by_id,
            "RECEIPT_READBACK_REQUIRED",
        )
        if "output" in document:
            for field in descriptor["readback"]["match"]:
                if field not in observed or not json_equal(observed[field], document["output"].get(field)):
                    fail(
                        "RECEIPT_READBACK_REQUIRED",
                        safe_location("$.readback.observed", field),
                        "observed field differs from execution output",
                    )


def validate_runtime_error(document: Mapping[str, Any]) -> None:
    if document["code"] not in STABLE_ERROR_CODES:
        fail("SCHEMA_VALUE_INVALID", "$.code", "error code is not in the stable v1 set")
    if set(document["details"]) - SAFE_RUNTIME_ERROR_FIELDS:
        fail("SCHEMA_ADDITIONAL_PROPERTY", "$.details", "unsafe error detail field")
    for key, value in document["details"].items():
        if isinstance(value, str) and contains_unsafe_text(value):
            fail("SESSION_SUMMARY_UNSAFE", safe_location("$.details", key), "safe error contains a forbidden raw value")


def validate_session_summary(document: Mapping[str, Any]) -> None:
    if "progress" in document and document["progress"]["completed"] > document["progress"]["total"]:
        fail("SCHEMA_VALUE_INVALID", "$.progress", "completed cannot exceed total")
    if document["sessionId"] == document["rootSessionId"] and "parentSessionId" in document:
        fail("VOICE_ROOT_SCOPE_VIOLATION", "$.parentSessionId", "root session cannot have a parent")
    if document["sessionId"] != document["rootSessionId"] and "parentSessionId" not in document:
        fail("VOICE_ROOT_SCOPE_VIOLATION", "$.parentSessionId", "descendant session must name its parent")
    for key in ("title", "safeSummary"):
        value = document.get(key)
        if isinstance(value, str) and contains_unsafe_text(value):
            fail("SESSION_SUMMARY_UNSAFE", safe_location("$", key), "session summary contains unsafe raw content")


def validate_voice_lane_state(document: Mapping[str, Any]) -> None:
    sessions = document["sessions"]
    if document["visibleSessionCount"] != len(sessions):
        fail("VOICE_VISIBLE_COUNT_MISMATCH", "$.visibleSessionCount", "count must equal rendered session cards")
    if document["ui"]["fullscreen"] is not False:
        fail("VOICE_FULLSCREEN_FORBIDDEN", "$.ui.fullscreen", "fullscreen Voice Lane is forbidden")
    if document["mode"] == "disabled":
        if (
            document["connection"] != "disconnected"
            or document["activity"] != "idle"
            or document["muted"] is not True
            or document["visibleSessionCount"] != 0
            or sessions
            or "rootSessionId" in document
            or "transcriptPreview" in document
        ):
            fail("VOICE_DISABLED_STATE_INVALID", "$", "disabled mode must be inert and empty")
        return

    root_id = document.get("rootSessionId")
    if sessions and not root_id:
        fail("VOICE_ROOT_SCOPE_VIOLATION", "$.rootSessionId", "visible sessions require a current root")

    by_id: dict[str, Mapping[str, Any]] = {}
    index_by_id: dict[str, int] = {}
    for index, session in enumerate(sessions):
        validate_session_summary(session)
        session_id = session["sessionId"]
        if session_id in by_id:
            fail("VOICE_ROOT_SCOPE_VIOLATION", f"$.sessions[{index}].sessionId", "duplicate session card")
        if session["rootSessionId"] != root_id:
            fail("VOICE_ROOT_SCOPE_VIOLATION", f"$.sessions[{index}].rootSessionId", "cross-root session leak")
        by_id[session_id] = session
        index_by_id[session_id] = index

    if sessions and root_id not in by_id:
        fail("VOICE_ROOT_SCOPE_VIOLATION", "$.sessions", "current root session card is missing")

    for session_id, session in by_id.items():
        if session_id == root_id:
            continue
        visited = {session_id}
        current = session
        while current["sessionId"] != root_id:
            parent_id = current.get("parentSessionId")
            if parent_id is None or parent_id not in by_id:
                index = index_by_id[current["sessionId"]]
                fail(
                    "VOICE_ROOT_SCOPE_VIOLATION",
                    f"$.sessions[{index}].parentSessionId",
                    "parent chain is not present in the current root-scoped card set",
                )
            if parent_id in visited:
                index = index_by_id[current["sessionId"]]
                fail(
                    "VOICE_ROOT_SCOPE_VIOLATION",
                    f"$.sessions[{index}].parentSessionId",
                    "session parent chain contains a cycle",
                )
            visited.add(parent_id)
            current = by_id[parent_id]


def validate_transcript_event(document: Mapping[str, Any]) -> None:
    if document["retention"] != "memory_only" or document["persisted"] is not False:
        fail("SESSION_SUMMARY_UNSAFE", "$", "transcript event must remain memory-only")
    if contains_unsafe_text(document["text"]):
        fail("SESSION_SUMMARY_UNSAFE", "$.text", "transcript fixture contains a raw secret, command, or path")


def validate_pocket_app(document: Mapping[str, Any], context: FixtureContext) -> None:
    paths: list[tuple[str, str]] = [
        ("$.intent", document["intent"]),
        ("$.state.schema", document["state"]["schema"]),
    ]
    paths.extend((f"$.surfaces[{index}].source", item["source"]) for index, item in enumerate(document["surfaces"]))
    paths.extend((f"$.workflows.{key}", value) for key, value in document["workflows"].items())
    paths.extend((f"$.tests[{index}]", value) for index, value in enumerate(document["tests"]))
    normalized: set[str] = set()
    for location, value in paths:
        canonical = normalize_relative_path(value, location)
        if canonical in normalized:
            fail("APP_REFERENCE_INVALID", location, "duplicate workspace path")
        normalized.add(canonical)
    if context.reference_app is not None and document["id"] == context.reference_app["id"]:
        if normalized != set(context.app_package_files):
            fail("APP_REFERENCE_INVALID", "$", "manifest paths do not equal the verified package file set")
    if document["state"]["store"] != "user-data://" + document["id"]:
        fail("APP_WORKSPACE_POLICY", "$.state.store", "user-data URI must be scoped to the Pocket App id")
    workspace = document["workspace"]
    expected_workspace = {
        "ownership": "user",
        "definitionRoot": "app_definition",
        "dataRoot": "separate_user_data",
        "secrets": "credential_store_only",
        "exportable": True,
        "deletable": True,
        "rollback": "versioned_snapshot",
    }
    if workspace != expected_workspace:
        fail("APP_WORKSPACE_POLICY", "$.workspace", "workspace ownership or secret boundary changed")
    requested: set[tuple[str, int]] = set()
    for index, item in enumerate(document["requestedCapabilities"]):
        key = (item["id"], item["version"])
        if key in requested:
            fail("APP_REFERENCE_INVALID", f"$.requestedCapabilities[{index}]", "duplicate capability request")
        context.registry.resolve(item["id"], item["version"], f"$.requestedCapabilities[{index}]")
        scope = item.get("scope", {})
        allowed_scope = V1_CAPABILITY_SCOPES.get(item["id"])
        if allowed_scope is None or set(scope) != set(allowed_scope):
            fail(
                "APP_REFERENCE_INVALID",
                f"$.requestedCapabilities[{index}].scope",
                "scope must exactly match the Host-supported v1 keys",
            )
        if "range" in scope and scope["range"] != "today":
            fail("APP_REFERENCE_INVALID", f"$.requestedCapabilities[{index}].scope.range", "v1 range scope must be today")
        if "namespace" in scope and (
            not isinstance(scope["namespace"], str)
            or re.fullmatch(r"[a-z][a-z0-9-]{0,63}", scope["namespace"]) is None
        ):
            fail("APP_REFERENCE_INVALID", f"$.requestedCapabilities[{index}].scope.namespace", "namespace scope is invalid")
        requested.add(key)
    surface_ids = [item["id"] for item in document["surfaces"]]
    if len(surface_ids) != len(set(surface_ids)):
        fail("APP_REFERENCE_INVALID", "$.surfaces", "surface ids must be unique")


def parse_capability_reference(value: str, location: str, error_code: str) -> tuple[str, int]:
    match = re.fullmatch(r"(.+)@([1-9][0-9]*)", value)
    if match is None:
        fail(error_code, location, "capability reference must be id@majorVersion")
    return match.group(1), int(match.group(2))


def validate_pocket_surface(document: Mapping[str, Any], context: FixtureContext) -> None:
    node_count = 0
    workflow_ids = context.app_workflow_ids

    def walk(node: Mapping[str, Any], location: str, depth: int) -> None:
        nonlocal node_count
        node_count += 1
        if node_count > MAX_SURFACE_NODES:
            fail("APP_REFERENCE_INVALID", location, "surface exceeds the v1 node limit")
        if depth > MAX_SURFACE_DEPTH:
            fail("APP_REFERENCE_INVALID", location, "surface exceeds the v1 depth limit")
        component_type = node["type"]
        if component_type in {"stack", "grid"}:
            for index, child in enumerate(node["children"]):
                walk(child, f"{location}.children[{index}]", depth + 1)
        elif component_type == "calendarEventPicker":
            capability_id, version = parse_capability_reference(
                node["items"]["query"],
                f"{location}.items.query",
                "APP_REFERENCE_INVALID",
            )
            if (capability_id, version) != ("calendar.events.list", 1):
                fail(
                    "APP_REFERENCE_INVALID",
                    f"{location}.items.query",
                    "calendarEventPicker requires calendar.events.list@1 output",
                )
            descriptor = context.registry.resolve(capability_id, version, f"{location}.items.query")
            scope = requested_scope(context, capability_id, version, f"{location}.items.query")
            if descriptor["effect"] not in {"pure", "private_read"}:
                fail("APP_REFERENCE_INVALID", f"{location}.items.query", "surface query must be read-only")
            resolved_arguments = dict(node["items"]["arguments"])
            for argument_name, argument_value in list(resolved_arguments.items()):
                context_match = (
                    re.fullmatch(r"\$context\.([A-Za-z][A-Za-z0-9_.]*)", argument_value)
                    if isinstance(argument_value, str)
                    else None
                )
                if context_match is None:
                    continue
                context_name = context_match.group(1)
                context_type = V1_CONTEXT_BINDINGS.get(context_name)
                argument_schema = descriptor_properties(descriptor, "inputSchema").get(argument_name)
                if (
                    context_type is None
                    or argument_schema is None
                    or not input_schema_accepts_type(argument_schema, context_type)
                ):
                    fail(
                        "APP_REFERENCE_INVALID",
                        f"{location}.items.arguments.{argument_name}",
                        "surface context binding is not allowlisted or type-compatible",
                    )
                resolved_arguments[argument_name] = V1_CONTEXT_SAMPLES[context_name]
            validate_capability_payload(
                resolved_arguments,
                descriptor,
                "inputSchema",
                f"{location}.items.arguments",
                context.schemas_by_id,
                "CAPABILITY_ARGUMENT_INVALID",
            )
            validate_capability_scope(resolved_arguments, scope, f"{location}.items.arguments")
        elif component_type == "button" and node["workflow"] not in workflow_ids:
            fail("APP_REFERENCE_INVALID", f"{location}.workflow", "button references an unknown manifest workflow")
        elif component_type == "image":
            asset_path = normalize_relative_path(node["assetRef"][len("asset://"):], f"{location}.assetRef")
            if asset_path not in context.app_package_files:
                fail("APP_REFERENCE_INVALID", f"{location}.assetRef", "asset is not present in the bound Pocket App package")
        elif component_type == "receipt" and document["hostBoundary"]["mayRenderReceipt"] is not True:
            fail("APP_REFERENCE_INVALID", location, "PocketSurface cannot render a Host-owned execution receipt")

    walk(document["root"], "$.root", 1)


def validate_surface_workflow_input_bindings(
    surfaces: Mapping[str, Mapping[str, Any]],
    workflows: Mapping[str, Mapping[str, Any]],
) -> None:
    input_types: dict[str, str] = {}
    for workflow in workflows.values():
        for name, declared_type in workflow["inputs"].items():
            existing = input_types.get(name)
            if existing is not None and existing != declared_type:
                fail(
                    "WORKFLOW_INPUT_TYPE_MISMATCH",
                    f"$.workflows.{workflow['id']}.inputs.{name}",
                    "the same surface input name has conflicting workflow types",
                )
            input_types[name] = declared_type

    accepted: dict[tuple[str, str], frozenset[str]] = {
        ("textField", "value"): frozenset({"string"}),
        ("toggle", "value"): frozenset({"boolean"}),
        ("picker", "value"): frozenset({"string"}),
        ("calendarEventPicker", "selection"): frozenset({"entity-ref"}),
        ("calendarEventPicker", "titleTarget"): frozenset({"string"}),
        ("durationPicker", "value"): frozenset({"integer", "number"}),
    }

    def walk(node: Mapping[str, Any], location: str) -> None:
        node_type = node["type"]
        for property_name, binding in node.items():
            if not isinstance(binding, str) or not binding.startswith("$input."):
                continue
            accepted_types = accepted.get((node_type, property_name))
            input_name = binding[len("$input."):]
            declared_type = input_types.get(input_name)
            if accepted_types is None or declared_type not in accepted_types:
                fail(
                    "WORKFLOW_INPUT_TYPE_MISMATCH",
                    f"{location}.{property_name}",
                    "surface control and declared workflow input types are incompatible",
                )
        for index, child in enumerate(node.get("children", [])):
            walk(child, f"{location}.children[{index}]")

    for surface_id, surface in surfaces.items():
        walk(surface["root"], f"$.surfaces.{surface_id}.root")


def input_schema_accepts_type(schema: Mapping[str, Any], workflow_type: str) -> bool:
    expected_json_type = {
        "string": "string",
        "entity-ref": "string",
        "integer": "integer",
        "number": "number",
        "boolean": "boolean",
    }[workflow_type]
    declared = schema.get("type")
    types = {declared} if isinstance(declared, str) else set(declared or [])
    if expected_json_type == "integer" and "number" in types:
        return True
    return expected_json_type in types


def contains_binding_token(value: Any) -> bool:
    if isinstance(value, str):
        return value.startswith("$")
    if isinstance(value, list):
        return any(contains_binding_token(item) for item in value)
    if isinstance(value, dict):
        return any(contains_binding_token(item) for item in value.values())
    return False


def validate_pocket_workflow(document: Mapping[str, Any], context: FixtureContext) -> None:
    depth = validate_dependency_order(
        document["steps"],
        id_field="id",
        depends_field="dependsOn",
        error_code="WORKFLOW_DEPENDENCY_INVALID",
        location="$.steps",
    )
    if len(document["steps"]) > document["limits"]["maxSteps"] or depth > document["limits"]["maxDepth"]:
        fail("WORKFLOW_LIMIT_INVALID", "$.limits", "declared limits are lower than the actual workflow")
    total_timeout_seconds = 0.0
    has_writes = False
    for index, step in enumerate(document["steps"]):
        capability_id, version = parse_capability_reference(
            step["use"],
            f"$.steps[{index}].use",
            "WORKFLOW_REFERENCE_INVALID",
        )
        try:
            descriptor = context.registry.resolve(capability_id, version, f"$.steps[{index}].use")
        except VerifyError as exc:
            if exc.code in {"CAPABILITY_UNKNOWN", "CAPABILITY_VERSION_MISMATCH"}:
                fail("WORKFLOW_REFERENCE_INVALID", exc.location, exc.detail)
            raise
        ensure_capability_executable(descriptor, f"$.steps[{index}].use")
        scope = requested_scope(context, capability_id, version, f"$.steps[{index}].use")
        has_writes = has_writes or descriptor["effect"] in WRITE_EFFECTS
        total_timeout_seconds += descriptor["limits"]["timeoutMs"] / 1000.0
        input_properties = descriptor_properties(descriptor, "inputSchema")
        required = set(descriptor["inputSchema"].get("required", []))
        provided = set(step["with"])
        if not required.issubset(provided):
            fail(
                "WORKFLOW_INPUT_TYPE_MISMATCH",
                f"$.steps[{index}].with",
                "workflow does not bind every required capability argument",
            )
        undeclared = provided - set(input_properties)
        if undeclared:
            fail(
                "WORKFLOW_INPUT_TYPE_MISMATCH",
                f"$.steps[{index}].with",
                "workflow binds undeclared capability argument(s): " + ",".join(sorted(undeclared)),
            )
        for argument_name, value in step["with"].items():
            argument_location = f"$.steps[{index}].with.{argument_name}"
            argument_schema = input_properties[argument_name]
            input_match = (
                re.fullmatch(r"\$input\.([A-Za-z][A-Za-z0-9_]*)", value)
                if isinstance(value, str)
                else None
            )
            context_match = (
                re.fullmatch(r"\$context\.([A-Za-z][A-Za-z0-9_.]*)", value)
                if isinstance(value, str)
                else None
            )
            if input_match is not None:
                input_name = input_match.group(1)
                workflow_type = document["inputs"].get(input_name)
                if workflow_type is None or not input_schema_accepts_type(argument_schema, workflow_type):
                    fail(
                        "WORKFLOW_INPUT_TYPE_MISMATCH",
                        argument_location,
                        "workflow input type is incompatible with capability input schema",
                    )
            elif context_match is not None:
                context_name = context_match.group(1)
                context_type = V1_CONTEXT_BINDINGS.get(context_name)
                if context_type is None or not input_schema_accepts_type(argument_schema, context_type):
                    fail(
                        "WORKFLOW_INPUT_TYPE_MISMATCH",
                        argument_location,
                        "context binding is not an allowlisted v1 value with a compatible type",
                    )
            else:
                if contains_binding_token(value):
                    fail(
                        "WORKFLOW_INPUT_TYPE_MISMATCH",
                        argument_location,
                        "v1 bindings must be a top-level $input or allowlisted $context expression",
                    )
                validate_capability_payload(
                    {argument_name: value},
                    {
                        **descriptor,
                        "inputSchema": {
                            "type": "object",
                            "required": [argument_name],
                            "properties": {argument_name: argument_schema},
                            "additionalProperties": False,
                        },
                    },
                    "inputSchema",
                    f"$.steps[{index}].with",
                    context.schemas_by_id,
                    "WORKFLOW_INPUT_TYPE_MISMATCH",
                )
        validate_payload_size(step["with"], descriptor, f"$.steps[{index}].with")
        validate_capability_scope(step["with"], scope, f"$.steps[{index}].with")
    approval = document["approval"]
    if has_writes and (approval["mode"] != "before_writes" or approval["group"] == "none"):
        fail("WORKFLOW_APPROVAL_REQUIRED", "$.approval", "write workflow requires grouped pre-write approval")
    if not has_writes and (approval["mode"] != "none" or approval["group"] != "none"):
        fail("WORKFLOW_APPROVAL_REQUIRED", "$.approval", "read-only workflow must not request write approval")
    if document["limits"]["timeoutSeconds"] < math.ceil(total_timeout_seconds):
        fail("WORKFLOW_LIMIT_INVALID", "$.limits.timeoutSeconds", "workflow timeout is lower than descriptor timeout budget")


def rect_equal(left: Mapping[str, Any], right: Mapping[str, Any]) -> bool:
    return all(left[key] == right[key] for key in ("x", "y", "width", "height"))


def rectangles_overlap(left: Mapping[str, Any], right: Mapping[str, Any]) -> bool:
    return not (
        left["x"] + left["width"] <= right["x"]
        or right["x"] + right["width"] <= left["x"]
        or left["y"] + left["height"] <= right["y"]
        or right["y"] + right["height"] <= left["y"]
    )


def validate_geometry(document: Mapping[str, Any]) -> None:
    expected_top_keys = {
        "geometryVersion",
        "coordinateSpace",
        "shellAnchor",
        "expansionDirection",
        "headerHeight",
        "tokens",
        "platforms",
    }
    if not isinstance(document, dict) or set(document) != expected_top_keys:
        fail("GEOMETRY_TOKEN_MISMATCH", "$", "geometry golden has an unexpected top-level shape")
    if document["geometryVersion"] != 1 or document["coordinateSpace"] != "logical_points":
        fail("GEOMETRY_TOKEN_MISMATCH", "$", "geometry version or coordinate space changed")
    if document["shellAnchor"] != "top" or document["expansionDirection"] != "down":
        fail("GEOMETRY_EXPANSION_DIRECTION", "$", "Voice Lane must expand only downward from a top anchor")
    if document["headerHeight"] != HEADER_HEIGHT:
        fail("GEOMETRY_TOKEN_MISMATCH", "$.headerHeight", "header token changed")
    expected_tokens = {
        "compactHeight": COMPACT_HEIGHT,
        "expandedHeightBySize": EXPANDED_HEIGHTS,
    }
    if document["tokens"] != expected_tokens:
        fail("GEOMETRY_TOKEN_MISMATCH", "$.tokens", "Voice Lane design tokens changed")

    expected_platform_sizes = {
        "windows": ("small", "medium", "large"),
        "macos": ("small", "medium", "large", "extraLarge"),
    }
    if not isinstance(document["platforms"], list):
        fail("GEOMETRY_TOKEN_MISMATCH", "$.platforms", "platforms must be an array")
    actual_platforms = [item.get("platform") for item in document["platforms"] if isinstance(item, dict)]
    if actual_platforms != ["windows", "macos"]:
        fail("GEOMETRY_TOKEN_MISMATCH", "$.platforms", "platform order/set changed")

    for platform_index, platform in enumerate(document["platforms"]):
        platform_name = platform["platform"]
        expected_sizes = expected_platform_sizes[platform_name]
        actual_sizes = tuple(item.get("size") for item in platform["sizes"])
        if actual_sizes != expected_sizes:
            fail("GEOMETRY_TOKEN_MISMATCH", f"$.platforms[{platform_index}].sizes", "size matrix changed")
        for size_index, size_case in enumerate(platform["sizes"]):
            location = f"$.platforms[{platform_index}].sizes[{size_index}]"
            size = size_case["size"]
            width, baseline_height = BASELINE_DIMENSIONS[size]
            if size_case["baselinePanel"] != {"width": width, "height": baseline_height}:
                fail("GEOMETRY_TOKEN_MISMATCH", f"{location}.baselinePanel", "baseline panel dimensions changed")
            modes = size_case["modes"]
            if [item["mode"] for item in modes] != ["disabled", "compact", "expanded"]:
                fail("GEOMETRY_TOKEN_MISMATCH", f"{location}.modes", "mode matrix changed")
            baseline_header = modes[0]["headerRect"]
            baseline_provider = modes[0]["providerHostRect"]
            baseline_top = modes[0]["shellTop"]
            baseline_width = modes[0]["shellWidth"]
            expected_header = {"x": 0, "y": 0, "width": width, "height": HEADER_HEIGHT}
            expected_provider = {
                "x": 0,
                "y": HEADER_HEIGHT,
                "width": width,
                "height": baseline_height - HEADER_HEIGHT,
            }
            if not rect_equal(baseline_header, expected_header):
                fail("GEOMETRY_TOKEN_MISMATCH", f"{location}.modes[0].headerRect", "header rect changed")
            if not rect_equal(baseline_provider, expected_provider):
                fail("GEOMETRY_PROVIDER_RECT_INVARIANT", f"{location}.modes[0].providerHostRect", "provider baseline rect changed")

            for mode_index, mode_case in enumerate(modes):
                mode_location = f"{location}.modes[{mode_index}]"
                if mode_case["shellTop"] != baseline_top:
                    fail("GEOMETRY_SHELL_TOP_INVARIANT", f"{mode_location}.shellTop", "shell top changed across Voice modes")
                if mode_case["shellWidth"] != baseline_width or baseline_width != width:
                    fail("GEOMETRY_TOKEN_MISMATCH", f"{mode_location}.shellWidth", "shell width changed across Voice modes")
                if not rect_equal(mode_case["headerRect"], baseline_header):
                    fail("GEOMETRY_SHELL_TOP_INVARIANT", f"{mode_location}.headerRect", "header rect changed across Voice modes")
                if not rect_equal(mode_case["providerHostRect"], baseline_provider):
                    fail("GEOMETRY_PROVIDER_RECT_INVARIANT", f"{mode_location}.providerHostRect", "ProviderHost rect changed across Voice modes")
                if mode_case["fullscreen"] is not False:
                    fail("GEOMETRY_FULLSCREEN_FORBIDDEN", f"{mode_location}.fullscreen", "fullscreen geometry is forbidden")
                if mode_case["providerOverlay"] is not False:
                    fail("GEOMETRY_OVERLAP", f"{mode_location}.providerOverlay", "Voice Lane cannot overlay ProviderHost")
                expected_voice_height = {
                    "disabled": 0,
                    "compact": COMPACT_HEIGHT,
                    "expanded": EXPANDED_HEIGHTS[size],
                }[mode_case["mode"]]
                expected_voice = {
                    "x": 0,
                    "y": baseline_height,
                    "width": width,
                    "height": expected_voice_height,
                }
                if not rect_equal(mode_case["voiceLaneRect"], expected_voice):
                    fail("GEOMETRY_TOKEN_MISMATCH", f"{mode_location}.voiceLaneRect", "Voice Lane rect does not match the design token")
                if mode_case["shellTotalHeight"] != baseline_height + expected_voice_height:
                    fail("GEOMETRY_TOKEN_MISMATCH", f"{mode_location}.shellTotalHeight", "total height is not baseline plus Voice Lane")
                if expected_voice_height > 0 and rectangles_overlap(mode_case["providerHostRect"], mode_case["voiceLaneRect"]):
                    fail("GEOMETRY_OVERLAP", mode_location, "Voice Lane overlaps ProviderHost")
                if mode_case["voiceLaneRect"]["y"] < baseline_height:
                    fail("GEOMETRY_EXPANSION_DIRECTION", f"{mode_location}.voiceLaneRect.y", "Voice Lane expanded upward")

            expanded_total = baseline_height + EXPANDED_HEIGHTS[size]
            expected_fallback = {
                "requestedMode": "expanded",
                "availableHeight": expanded_total - 1,
                "resolvedMode": "compact",
                "reasonCode": "VOICE_LANE_INSUFFICIENT_HEIGHT",
            }
            if size_case["shortDisplayFallback"] != expected_fallback:
                fail("GEOMETRY_TOKEN_MISMATCH", f"{location}.shortDisplayFallback", "short-display fallback changed")


def apply_geometry_mutation(document: Mapping[str, Any], fixture_dir: Path) -> Mapping[str, Any]:
    if set(document) != {"base", "mutation"}:
        fail("FIXTURE_MANIFEST_MISMATCH", "$", "geometry mutation fixture shape is invalid")
    base_relative = normalize_relative_path(document["base"], "$.base")
    base = load_json(fixture_dir / base_relative, location=base_relative)
    mutated = copy.deepcopy(base)
    mutation = document["mutation"]
    target = None
    for platform in mutated["platforms"]:
        if platform["platform"] != mutation["platform"]:
            continue
        for size_case in platform["sizes"]:
            if size_case["size"] != mutation["size"]:
                continue
            for mode_case in size_case["modes"]:
                if mode_case["mode"] == mutation["mode"]:
                    target = mode_case
                    break
    if target is None:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.mutation", "geometry mutation target does not exist")
    allowed = {"providerHostRect", "voiceLaneRect", "shellTotalHeight"}
    if set(mutation) - {"platform", "size", "mode"} != allowed:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.mutation", "geometry mutation fields changed")
    for key in allowed:
        target[key] = mutation[key]
    return mutated


def recursively_find_forbidden_keys(value: Any, forbidden: frozenset[str], location: str = "$") -> tuple[str, str] | None:
    if isinstance(value, dict):
        for key in sorted(value):
            if key.casefold() in forbidden:
                return safe_location(location, key), key
            found = recursively_find_forbidden_keys(value[key], forbidden, safe_location(location, key))
            if found is not None:
                return found
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found = recursively_find_forbidden_keys(item, forbidden, safe_location(location, index))
            if found is not None:
                return found
    return None


def validate_audit(document: Mapping[str, Any], context: FixtureContext) -> None:
    if set(document) != {"policyVersion", "allowedTopLevelKeys", "forbiddenKeys", "entry"}:
        fail("AUDIT_KEYSET_MISMATCH", "$", "audit policy has unexpected fields")
    if document["policyVersion"] != 1:
        fail("AUDIT_KEYSET_MISMATCH", "$.policyVersion", "audit policy version changed")
    if document["allowedTopLevelKeys"] != list(AUDIT_ALLOWED_KEYS):
        fail("AUDIT_KEYSET_MISMATCH", "$.allowedTopLevelKeys", "allowed metadata keyset changed")
    if document["forbiddenKeys"] != list(AUDIT_FORBIDDEN_KEYS):
        fail("AUDIT_KEYSET_MISMATCH", "$.forbiddenKeys", "forbidden redaction keyset changed")
    entry = document["entry"]
    if not isinstance(entry, dict):
        fail("AUDIT_KEYSET_MISMATCH", "$.entry", "audit entry must be an object")
    forbidden = frozenset(item.casefold() for item in AUDIT_FORBIDDEN_KEYS)
    found = recursively_find_forbidden_keys(entry, forbidden, "$.entry")
    if found is not None:
        fail("AUDIT_FORBIDDEN_FIELD", found[0], f"forbidden audit field {found[1]!r}")
    if set(entry) != set(AUDIT_ALLOWED_KEYS):
        fail("AUDIT_KEYSET_MISMATCH", "$.entry", "audit entry must contain the exact metadata-only keyset")
    if re.fullmatch(r"principal:sha256:[a-f0-9]{64}", entry["principalPseudonym"]) is None:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.principalPseudonym", "principal must be an irreversible pseudonym")
    for key in ("auditEntryId", "invocationId", "traceId"):
        if not isinstance(entry[key], str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", entry[key]) is None:
            fail("AUDIT_VALUE_UNSAFE", safe_location("$.entry", key), "audit identifier is not a safe opaque id")
    if contains_unsafe_audit_value(entry):
        fail("AUDIT_VALUE_UNSAFE", "$.entry", "audit value contains a path, URL, email, credential, or raw content")
    if not isinstance(entry["capability"], dict) or set(entry["capability"]) != {"id", "version", "effect"}:
        fail("AUDIT_KEYSET_MISMATCH", "$.entry.capability", "capability audit shape changed")
    if not isinstance(entry["pocketApp"], dict) or set(entry["pocketApp"]) != {"id", "version", "manifestDigest"}:
        fail("AUDIT_KEYSET_MISMATCH", "$.entry.pocketApp", "Pocket App audit shape changed")
    if entry["pocketApp"] != expected_app_context(context):
        fail("APP_CONTEXT_MISMATCH", "$.entry.pocketApp", "audit Pocket App context differs from the verified manifest")
    if entry["approvalDecision"] not in {"approved", "rejected", "not_required"}:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.approvalDecision", "approval decision is not an allowed enum")
    if entry["approvalPolicy"] not in set(EXPECTED_APPROVAL_POLICY.values()):
        fail("AUDIT_VALUE_UNSAFE", "$.entry.approvalPolicy", "approval policy is not an allowed enum")
    if entry["origin"] not in {"native_ui", "voice", "text", "pocket_surface", "mcp", "connector"}:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.origin", "origin is not an allowed enum")
    if entry["permissionDecision"] not in {"granted", "denied", "not_required"}:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.permissionDecision", "permission decision is not an allowed enum")
    if entry["status"] not in {"succeeded", "rejected", "failed", "partial", "unknown"}:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.status", "status is not an allowed enum")
    if entry["safeErrorCode"] is not None and entry["safeErrorCode"] not in SAFE_RECEIPT_ERROR_CODES:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.safeErrorCode", "safe error code is not allowlisted")
    if not isinstance(entry["durationMs"], int) or isinstance(entry["durationMs"], bool) or entry["durationMs"] < 0:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.durationMs", "duration must be a non-negative integer")
    if not isinstance(entry["retryCount"], int) or isinstance(entry["retryCount"], bool) or not 0 <= entry["retryCount"] <= 16:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.retryCount", "retry count is outside the bounded v1 range")
    if not isinstance(entry["idempotencyReplay"], bool):
        fail("AUDIT_VALUE_UNSAFE", "$.entry.idempotencyReplay", "idempotency replay must be boolean")
    parse_rfc3339(entry["timestamp"], "$.entry.timestamp")
    capability = entry["capability"]
    descriptor = context.registry.resolve(capability["id"], capability["version"], "$.entry.capability")
    if capability["effect"] not in EXPECTED_APPROVAL_POLICY:
        fail("AUDIT_VALUE_UNSAFE", "$.entry.capability.effect", "effect is not an allowed enum")
    for digest_key in ("inputDigest",):
        if not isinstance(entry[digest_key], str) or re.fullmatch(r"sha256:[a-f0-9]{64}", entry[digest_key]) is None:
            fail("AUDIT_KEYSET_MISMATCH", safe_location("$.entry", digest_key), "audit payload must use a digest")
    readback = entry["readback"]
    if not isinstance(readback, dict) or set(readback) != {"status", "evidenceDigest"}:
        fail("AUDIT_KEYSET_MISMATCH", "$.entry.readback", "readback audit shape changed")
    if re.fullmatch(r"sha256:[a-f0-9]{64}", readback["evidenceDigest"]) is None:
        fail("AUDIT_KEYSET_MISMATCH", "$.entry.readback.evidenceDigest", "readback evidence must be a digest")
    invocation = context.invocations_by_id.get(entry["invocationId"])
    if invocation is None:
        fail("AUDIT_BINDING_MISMATCH", "$.entry.invocationId", "audit references an unknown invocation")
    if capability != {
        "id": invocation["capabilityId"],
        "version": invocation["capabilityVersion"],
        "effect": descriptor["effect"],
    }:
        fail("AUDIT_BINDING_MISMATCH", "$.entry.capability", "audit capability differs from the invocation or descriptor")
    if entry["approvalPolicy"] != descriptor["approvalPolicy"]:
        fail("AUDIT_BINDING_MISMATCH", "$.entry.approvalPolicy", "audit approval policy differs from the descriptor")
    if entry["origin"] != invocation["origin"]:
        fail("AUDIT_BINDING_MISMATCH", "$.entry.origin", "audit origin differs from the invocation")
    if entry["traceId"] != invocation["traceId"]:
        fail("AUDIT_BINDING_MISMATCH", "$.entry.traceId", "audit trace differs from the invocation")
    if entry["pocketApp"] != invocation.get("appContext"):
        fail("AUDIT_BINDING_MISMATCH", "$.entry.pocketApp", "audit Pocket App differs from the invocation")
    if entry["inputDigest"] != digest(invocation["arguments"]):
        fail("AUDIT_BINDING_MISMATCH", "$.entry.inputDigest", "audit input digest was not computed from invocation arguments")
    host_observed = context.host_observations.get(entry["invocationId"])
    if readback["status"] == "verified" and (
        host_observed is None or readback["evidenceDigest"] != digest(host_observed)
    ):
        fail(
            "AUDIT_BINDING_MISMATCH",
            "$.entry.readback.evidenceDigest",
            "audit readback digest differs from the Host-owned observation",
        )


def contains_unsafe_audit_value(value: Any) -> bool:
    if isinstance(value, str):
        return contains_unsafe_text(value)
    if isinstance(value, list):
        return any(contains_unsafe_audit_value(item) for item in value)
    if isinstance(value, dict):
        return any(contains_unsafe_audit_value(item) for item in value.values())
    return False


def apply_audit_mutation(document: Mapping[str, Any], fixture_dir: Path) -> Mapping[str, Any]:
    if set(document) != {"base", "mutation"}:
        fail("FIXTURE_MANIFEST_MISMATCH", "$", "audit mutation fixture shape is invalid")
    base_relative = normalize_relative_path(document["base"], "$.base")
    base = load_json(fixture_dir / base_relative, location=base_relative)
    mutated = copy.deepcopy(base)
    mutation = document["mutation"]
    if set(mutation) == {"addTopLevel"} and isinstance(mutation["addTopLevel"], dict):
        mutated["entry"].update(mutation["addTopLevel"])
    elif set(mutation) == {"setPath", "value"} and isinstance(mutation["setPath"], list):
        set_document_path(mutated, mutation["setPath"], mutation["value"], "$.mutation.setPath")
    else:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.mutation", "audit mutation operation is invalid")
    return mutated


def set_document_path(document: Any, path: Sequence[str | int], value: Any, location: str) -> None:
    if not path:
        fail("FIXTURE_MANIFEST_MISMATCH", location, "mutation path must not be empty")
    target = document
    for token in path[:-1]:
        if isinstance(token, int) and isinstance(target, list) and 0 <= token < len(target):
            target = target[token]
        elif isinstance(token, str) and isinstance(target, dict) and token in target:
            target = target[token]
        else:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "mutation path does not exist")
    final = path[-1]
    if isinstance(final, int) and isinstance(target, list) and 0 <= final < len(target):
        target[final] = value
    elif isinstance(final, str) and isinstance(target, dict):
        target[final] = value
    else:
        fail("FIXTURE_MANIFEST_MISMATCH", location, "mutation destination is invalid")


def apply_schema_mutation(document: Mapping[str, Any], fixture_dir: Path) -> Mapping[str, Any]:
    if set(document) != {"base", "mutation"}:
        fail("FIXTURE_MANIFEST_MISMATCH", "$", "schema mutation fixture shape is invalid")
    base_relative = normalize_relative_path(document["base"], "$.base")
    base = load_json(fixture_dir / base_relative, location=base_relative)
    mutated = copy.deepcopy(base)
    mutation = document["mutation"]
    if isinstance(mutation, dict) and set(mutation) == {"setPath", "value"}:
        set_document_path(mutated, mutation["setPath"], mutation["value"], "$.mutation.setPath")
    elif isinstance(mutation, dict) and set(mutation) == {"setValues"} and isinstance(mutation["setValues"], list):
        for index, operation in enumerate(mutation["setValues"]):
            if not isinstance(operation, dict) or set(operation) != {"path", "value"}:
                fail("FIXTURE_MANIFEST_MISMATCH", f"$.mutation.setValues[{index}]", "mutation operation is invalid")
            set_document_path(mutated, operation["path"], operation["value"], f"$.mutation.setValues[{index}].path")
    else:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.mutation", "schema mutation operation is invalid")
    return mutated


def validate_canonical_json(document: Mapping[str, Any]) -> None:
    if set(document) != {"canonicalization", "value", "expectedDigest"}:
        fail("FIXTURE_MANIFEST_MISMATCH", "$", "canonical JSON golden shape changed")
    if document["canonicalization"] != "json-utf8-sort-keys-no-whitespace-v1":
        fail("FIXTURE_MANIFEST_MISMATCH", "$.canonicalization", "canonicalization algorithm changed")
    if digest(document["value"]) != document["expectedDigest"]:
        fail("FIXTURE_DIGEST_MISMATCH", "$.expectedDigest", "canonical digest mismatch")


def validate_error_codes(document: Mapping[str, Any]) -> None:
    expected = {"errorCodeSetVersion": 1, "codes": list(STABLE_ERROR_CODES)}
    if document != expected:
        fail("FIXTURE_MANIFEST_MISMATCH", "$", "stable verifier error code set changed")


def load_fixture_support(context: FixtureContext, manifest: Mapping[str, Any]) -> FixtureSupport:
    engine = SchemaEngine(context.schemas_by_id)
    support_schemas = {
        "execution-plan.schema.json": context.schemas_by_filename["execution-plan.schema.json"],
        "invocation.schema.json": context.schemas_by_filename["invocation.schema.json"],
        "pocket-app.schema.json": context.schemas_by_filename["pocket-app.schema.json"],
        "pocket-workflow.schema.json": context.schemas_by_filename["pocket-workflow.schema.json"],
        "pocket-surface.schema.json": context.schemas_by_filename["pocket-surface.schema.json"],
    }
    plans: dict[str, Mapping[str, Any]] = {}
    invocations: dict[str, Mapping[str, Any]] = {}
    apps: list[Mapping[str, Any]] = []
    workflows: dict[str, Mapping[str, Any]] = {}
    surfaces: dict[str, Mapping[str, Any]] = {}

    for case in manifest["cases"]:
        if case.get("expected") != "pass" or case.get("kind") != "schema":
            continue
        schema_name = case["schema"]
        if schema_name not in support_schemas:
            continue
        relative = case["path"]
        document = load_json(context.fixture_dir / relative, location=relative)
        schema = support_schemas[schema_name]
        engine.validate(document, schema, document=schema)
        if schema_name == "execution-plan.schema.json":
            plan_id = document["planId"]
            if plan_id in plans:
                fail("FIXTURE_MANIFEST_MISMATCH", relative, "duplicate fixture plan id")
            plans[plan_id] = document
        elif schema_name == "invocation.schema.json":
            invocation_id = document["invocationId"]
            if invocation_id in invocations:
                fail("FIXTURE_MANIFEST_MISMATCH", relative, "duplicate fixture invocation id")
            invocations[invocation_id] = document
        elif schema_name == "pocket-app.schema.json":
            apps.append(document)
        elif schema_name == "pocket-workflow.schema.json":
            workflow_id = document["id"]
            if workflow_id in workflows:
                fail("FIXTURE_MANIFEST_MISMATCH", relative, "duplicate fixture workflow id")
            workflows[workflow_id] = document
        elif schema_name == "pocket-surface.schema.json":
            surface_id = document["id"]
            if surface_id in surfaces:
                fail("FIXTURE_MANIFEST_MISMATCH", relative, "duplicate fixture surface id")
            surfaces[surface_id] = document

    if len(apps) != 1:
        fail(
            "FIXTURE_MANIFEST_MISMATCH",
            "fixtures/valid",
            "AN0 reference corpus must contain exactly one Pocket App package context",
        )
    reference_app = apps[0]
    if set(reference_app["workflows"]) != set(workflows):
        fail(
            "APP_REFERENCE_INVALID",
            "reference-app.workflows",
            "manifest workflow ids and workflow fixture ids differ",
        )
    declared_surface_ids = {item["id"] for item in reference_app["surfaces"]}
    if declared_surface_ids != set(surfaces):
        fail(
            "APP_REFERENCE_INVALID",
            "reference-app.surfaces",
            "manifest surface ids and surface fixture ids differ",
        )
    bindings = {
        item["path"]: item["source"]
        for item in manifest["referencePackage"]["files"]
    }
    for item in reference_app["surfaces"]:
        source = bindings.get(item["source"])
        if source is None or load_json(context.fixture_dir / source, location=source) != surfaces[item["id"]]:
            fail("APP_REFERENCE_INVALID", item["source"], "manifest surface is not bound to its validated fixture")
    for workflow_id, package_path in reference_app["workflows"].items():
        source = bindings.get(package_path)
        if source is None or load_json(context.fixture_dir / source, location=source) != workflows[workflow_id]:
            fail("APP_REFERENCE_INVALID", package_path, "manifest workflow is not bound to its validated fixture")
    return FixtureSupport(
        plans_by_id=plans,
        invocations_by_id=invocations,
        reference_app=reference_app,
        workflows_by_id=workflows,
        surfaces_by_id=surfaces,
    )


def load_reference_package(manifest: Mapping[str, Any], fixture_dir: Path) -> frozenset[str]:
    package = manifest["referencePackage"]
    if not isinstance(package, dict) or set(package) != {"appFixture", "files"}:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.referencePackage", "reference package shape changed")
    app_fixture = normalize_relative_path(package["appFixture"], "$.referencePackage.appFixture")
    if app_fixture != "valid/pocket-app.today-focus.json":
        fail("FIXTURE_MANIFEST_MISMATCH", "$.referencePackage.appFixture", "unexpected reference app fixture")
    app = load_json(fixture_dir / app_fixture, location=app_fixture)
    expected_paths = {
        app["intent"],
        app["state"]["schema"],
        *(item["source"] for item in app["surfaces"]),
        *app["workflows"].values(),
        *app["tests"],
    }
    observed_paths: set[str] = set()
    for index, item in enumerate(package["files"]):
        location = f"$.referencePackage.files[{index}]"
        if not isinstance(item, dict) or set(item) != {"path", "source", "digest"}:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "package file binding shape changed")
        path = normalize_relative_path(item["path"], f"{location}.path")
        source = normalize_relative_path(item["source"], f"{location}.source")
        if path in observed_paths:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.path", "duplicate package path")
        source_path = fixture_dir / source
        if not source_path.is_file():
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.source", "package source fixture is missing")
        actual_digest = "sha256:" + hashlib.sha256(source_path.read_bytes()).hexdigest()
        if item["digest"] != actual_digest:
            fail("FIXTURE_DIGEST_MISMATCH", f"{location}.digest", "package source bytes changed")
        observed_paths.add(path)
    if observed_paths != expected_paths:
        fail("APP_REFERENCE_INVALID", "$.referencePackage.files", "package bindings do not cover every manifest path")
    return frozenset(observed_paths)


def load_host_observations(manifest: Mapping[str, Any], fixture_dir: Path) -> Mapping[str, Mapping[str, Any]]:
    observations: dict[str, Mapping[str, Any]] = {}
    for index, item in enumerate(manifest["hostObservations"]):
        location = f"$.hostObservations[{index}]"
        if not isinstance(item, dict) or set(item) != {"invocationId", "source", "digest"}:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "host observation binding shape changed")
        source = normalize_relative_path(item["source"], f"{location}.source")
        document = load_json(fixture_dir / source, location=source)
        if item["digest"] != digest(document):
            fail("FIXTURE_DIGEST_MISMATCH", f"{location}.digest", "host observation changed")
        if item["invocationId"] in observations:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.invocationId", "duplicate host observation")
        observations[item["invocationId"]] = document
    return observations


def validate_manifest_shape(manifest: Mapping[str, Any], fixture_dir: Path) -> None:
    if set(manifest) != {"manifestVersion", "registryPath", "referencePackage", "hostObservations", "cases"}:
        fail("FIXTURE_MANIFEST_MISMATCH", "expected-results.json", "manifest fields changed")
    if manifest["manifestVersion"] != 1:
        fail("FIXTURE_MANIFEST_MISMATCH", "expected-results.json", "manifest version must be 1")
    normalize_relative_path(manifest["registryPath"], "$.registryPath")
    if not isinstance(manifest["cases"], list) or not manifest["cases"]:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.cases", "manifest cases must be non-empty")

    case_ids: set[str] = set()
    paths: set[str] = set()
    previous_id: str | None = None
    for index, case in enumerate(manifest["cases"]):
        location = f"$.cases[{index}]"
        if not isinstance(case, dict):
            fail("FIXTURE_MANIFEST_MISMATCH", location, "case must be an object")
        required = {"id", "path", "kind", "expected"}
        if not required.issubset(case):
            fail("FIXTURE_MANIFEST_MISMATCH", location, "case is missing required metadata")
        allowed = required | {"schema", "errorCode", "errorLocation", "expectedDigest"}
        if set(case) - allowed:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "case has unexpected metadata")
        if not isinstance(case["id"], str) or not case["id"]:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.id", "case id must be non-empty")
        if previous_id is not None and case["id"] <= previous_id:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.id", "cases must be strictly sorted by id")
        previous_id = case["id"]
        if case["id"] in case_ids:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.id", "duplicate case id")
        case_ids.add(case["id"])
        relative = normalize_relative_path(case["path"], f"{location}.path")
        if relative in paths:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.path", "fixture appears more than once")
        paths.add(relative)
        if not (fixture_dir / relative).is_file():
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.path", "fixture file does not exist")
        if not isinstance(case["kind"], str) or case["kind"] not in {
            "schema",
            "schema-mutation",
            "schema-policy",
            "geometry",
            "geometry-mutation",
            "audit",
            "audit-mutation",
            "canonical-json",
            "error-codes",
            "capability-registry",
        }:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.kind", "fixture kind is unsupported")
        if case["expected"] not in {"pass", "reject"}:
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.expected", "expected must be pass or reject")
        expected_prefix = "invalid/" if case["expected"] == "reject" else (
            "golden/" if case["kind"] != "schema" else "valid/"
        )
        if not relative.startswith(expected_prefix):
            fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.path", f"case must live under {expected_prefix}")
        if case["expected"] == "reject":
            if case.get("errorCode") not in STABLE_ERROR_CODES:
                fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.errorCode", "reject case needs a stable error code")
            if not isinstance(case.get("errorLocation"), str) or not case["errorLocation"]:
                fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.errorLocation", "reject case needs an exact error location")
            expected_digest = case.get("expectedDigest")
            if not isinstance(expected_digest, str) or re.fullmatch(r"sha256:[a-f0-9]{64}", expected_digest) is None:
                fail("FIXTURE_MANIFEST_MISMATCH", location, "reject case must pin its exact fixture digest")
        elif case["kind"] in {"audit", "canonical-json", "capability-registry", "error-codes", "geometry"}:
            expected_digest = case.get("expectedDigest")
            if not isinstance(expected_digest, str) or re.fullmatch(r"sha256:[a-f0-9]{64}", expected_digest) is None:
                fail("FIXTURE_MANIFEST_MISMATCH", location, "golden pass case needs a canonical SHA-256 digest")
        if case["kind"] in {"schema", "schema-mutation"}:
            if case.get("schema") not in EXPECTED_SCHEMAS:
                fail("FIXTURE_MANIFEST_MISMATCH", f"{location}.schema", "schema case names an unknown schema")
        elif "schema" in case:
            fail("FIXTURE_MANIFEST_MISMATCH", location, "non-schema case cannot name a schema")

    actual_paths = {
        path.relative_to(fixture_dir).as_posix()
        for folder in ("valid", "invalid", "golden")
        for path in (fixture_dir / folder).glob("*.json")
    }
    if paths != actual_paths:
        missing = sorted(actual_paths - paths)
        extra = sorted(paths - actual_paths)
        fail(
            "FIXTURE_MANIFEST_MISMATCH",
            "$.cases",
            f"manifest coverage differs; missing={missing}, extra={extra}",
        )
    if manifest["registryPath"] not in paths:
        fail("FIXTURE_MANIFEST_MISMATCH", "$.registryPath", "registry golden is not a manifest case")


def validate_schema_case(
    document: Mapping[str, Any],
    schema_name: str,
    context: FixtureContext,
) -> None:
    schema = context.schemas_by_filename[schema_name]
    SchemaEngine(context.schemas_by_id).validate(document, schema, document=schema)
    if schema_name == "capability-descriptor.schema.json":
        validate_descriptor_semantics(
            document,
            location="$",
            schemas_by_id=context.schemas_by_id,
            registry=context.registry,
        )
    elif schema_name == "invocation.schema.json":
        validate_invocation(document, context)
    elif schema_name == "execution-plan.schema.json":
        validate_execution_plan(document, context)
    elif schema_name == "approval-request.schema.json":
        validate_approval_request(document, context)
    elif schema_name == "receipt.schema.json":
        validate_receipt(document, context)
    elif schema_name == "error.schema.json":
        validate_runtime_error(document)
    elif schema_name == "voice-lane-state.schema.json":
        validate_voice_lane_state(document)
    elif schema_name == "agent-session-summary.schema.json":
        validate_session_summary(document)
    elif schema_name == "voice-transcript-event.schema.json":
        validate_transcript_event(document)
    elif schema_name == "pocket-app.schema.json":
        validate_pocket_app(document, context)
    elif schema_name == "pocket-surface.schema.json":
        validate_pocket_surface(document, context)
    elif schema_name == "pocket-workflow.schema.json":
        validate_pocket_workflow(document, context)


def execute_case(case: Mapping[str, Any], context: FixtureContext) -> None:
    relative = case["path"]
    document = load_json(context.fixture_dir / relative, location=relative)
    if "expectedDigest" in case and digest(document) != case["expectedDigest"]:
        fail("FIXTURE_DIGEST_MISMATCH", relative, "canonical fixture digest changed")
    if case["kind"] == "schema":
        if not isinstance(document, dict):
            fail("SCHEMA_TYPE_MISMATCH", "$", "contract fixture must be an object")
        validate_schema_case(document, case["schema"], context)
    elif case["kind"] == "schema-mutation":
        mutated = apply_schema_mutation(document, context.fixture_dir)
        if not isinstance(mutated, dict):
            fail("SCHEMA_TYPE_MISMATCH", "$", "mutated contract fixture must be an object")
        validate_schema_case(mutated, case["schema"], context)
    elif case["kind"] == "schema-policy":
        enforce_schema_policy(
            document,
            label=relative,
            schemas_by_id=context.schemas_by_id,
            require_document_header=True,
        )
    elif case["kind"] == "geometry":
        validate_geometry(document)
    elif case["kind"] == "geometry-mutation":
        validate_geometry(apply_geometry_mutation(document, context.fixture_dir))
    elif case["kind"] == "audit":
        validate_audit(document, context)
    elif case["kind"] == "audit-mutation":
        validate_audit(apply_audit_mutation(document, context.fixture_dir), context)
    elif case["kind"] == "canonical-json":
        validate_canonical_json(document)
    elif case["kind"] == "error-codes":
        validate_error_codes(document)
    elif case["kind"] == "capability-registry":
        # Registry construction already performed the full validation. Re-check its canonical shape here.
        if relative != "golden/capability-registry.json":
            fail("FIXTURE_MANIFEST_MISMATCH", relative, "unexpected registry golden path")
    else:
        fail("FIXTURE_MANIFEST_MISMATCH", relative, f"unknown fixture kind {case['kind']!r}")

def build_context(repo_root: Path) -> tuple[FixtureContext, Mapping[str, Any]]:
    contract_dir = repo_root / "contracts" / "pocket" / "v1"
    fixture_dir = contract_dir / "fixtures"
    if not contract_dir.is_dir() or not fixture_dir.is_dir():
        fail("FIXTURE_MANIFEST_MISMATCH", "contracts/pocket/v1", "contract directory is missing")
    schemas_by_filename, schemas_by_id = load_schemas(contract_dir)
    manifest = load_json(fixture_dir / "expected-results.json", location="expected-results.json")
    if not isinstance(manifest, dict):
        fail("FIXTURE_MANIFEST_MISMATCH", "expected-results.json", "manifest must be an object")
    validate_manifest_shape(manifest, fixture_dir)
    package_files = load_reference_package(manifest, fixture_dir)
    host_observations = load_host_observations(manifest, fixture_dir)
    registry = load_registry(
        fixture_dir,
        manifest["registryPath"],
        schemas_by_filename,
        schemas_by_id,
    )
    provisional = FixtureContext(
        contract_dir=contract_dir,
        fixture_dir=fixture_dir,
        schemas_by_filename=schemas_by_filename,
        schemas_by_id=schemas_by_id,
        registry=registry,
        plans_by_id={},
        invocations_by_id={},
        app_workflow_ids=frozenset(),
        app_requested_capabilities={},
        reference_app=None,
        app_package_files=package_files,
        host_observations=host_observations,
    )
    support = load_fixture_support(provisional, manifest)
    requested_capabilities = {
        (item["id"], item["version"]): item
        for item in support.reference_app["requestedCapabilities"]
    }
    context = FixtureContext(
        contract_dir=contract_dir,
        fixture_dir=fixture_dir,
        schemas_by_filename=schemas_by_filename,
        schemas_by_id=schemas_by_id,
        registry=registry,
        plans_by_id=support.plans_by_id,
        invocations_by_id=support.invocations_by_id,
        app_workflow_ids=frozenset(support.workflows_by_id),
        app_requested_capabilities=requested_capabilities,
        reference_app=support.reference_app,
        app_package_files=package_files,
        host_observations=host_observations,
    )
    validate_pocket_app(support.reference_app, context)
    for plan in context.plans_by_id.values():
        validate_execution_plan(plan, context)
    for invocation in context.invocations_by_id.values():
        validate_invocation(invocation, context)
    for workflow in support.workflows_by_id.values():
        validate_pocket_workflow(workflow, context)
    for surface in support.surfaces_by_id.values():
        validate_pocket_surface(surface, context)
    validate_surface_workflow_input_bindings(
        support.surfaces_by_id,
        support.workflows_by_id,
    )
    return context, manifest


def run(repo_root: Path) -> dict[str, Any]:
    context, manifest = build_context(repo_root)
    results: list[CaseResult] = []
    for case in manifest["cases"]:
        observed = "pass"
        error_code: str | None = None
        error_location: str | None = None
        try:
            execute_case(case, context)
        except VerifyError as exc:
            observed = "reject"
            error_code = exc.code
            error_location = exc.location
        expected = case["expected"]
        expected_code = case.get("errorCode")
        expected_location = case.get("errorLocation")
        matched = observed == expected and (
            expected != "reject"
            or (error_code == expected_code and error_location == expected_location)
        )
        results.append(
            CaseResult(
                case_id=case["id"],
                expected=expected,
                observed=observed,
                matched=matched,
                error_code=error_code,
                error_location=error_location,
            )
        )
    matched_count = sum(1 for item in results if item.matched)
    report = {
        "contract": CONTRACT_NAME,
        "schemaDraft": DRAFT_2020_12,
        "schemaCount": len(context.schemas_by_filename),
        "fixtureCount": len(results),
        "matchedCount": matched_count,
        "result": "pass" if matched_count == len(results) else "fail",
        "results": [item.to_json() for item in results],
    }
    return report


def fatal_report(exc: Exception) -> dict[str, Any]:
    if isinstance(exc, VerifyError):
        code = exc.code
        location = exc.location
    else:
        code = "SCHEMA_POLICY_VIOLATION"
        location = "verifier"
    return {
        "contract": CONTRACT_NAME,
        "schemaDraft": DRAFT_2020_12,
        "schemaCount": 0,
        "fixtureCount": 0,
        "matchedCount": 0,
        "result": "fail",
        "fatal": {"code": code, "location": location},
        "results": [],
    }


def write_report(path: Path, report: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n"
    path.write_text(payload, encoding="utf-8", newline="\n")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    default_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Verify HoverPocket pocket/v1 contracts and fixtures")
    parser.add_argument("--root", type=Path, default=default_root, help="repository root (default: inferred from script path)")
    parser.add_argument("--report-json", type=Path, help="write a deterministic JSON report")
    parser.add_argument("--quiet", action="store_true", help="suppress the human-readable summary")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    try:
        report = run(args.root.resolve())
    except Exception as exc:  # deterministic fail-closed boundary
        report = fatal_report(exc)
        if args.report_json is not None:
            write_report(args.report_json, report)
        if not args.quiet:
            if isinstance(exc, VerifyError):
                print(f"FAIL {CONTRACT_NAME}: {exc.code} at {exc.location}: {exc.detail}")
            else:
                print(f"FAIL {CONTRACT_NAME}: verifier-internal-error ({exc.__class__.__name__})")
        return 1

    if args.report_json is not None:
        write_report(args.report_json, report)
    if not args.quiet:
        print(
            f"{report['result'].upper()} {CONTRACT_NAME}: "
            f"schemas={report['schemaCount']} fixtures={report['fixtureCount']} matched={report['matchedCount']}"
        )
        for result in report["results"]:
            if not result["matched"]:
                suffix = f" code={result.get('errorCode', 'none')}"
                print(
                    f"- {result['id']}: expected={result['expected']} observed={result['observed']}{suffix}"
                )
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
