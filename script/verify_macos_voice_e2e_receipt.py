#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


ALLOWED_KEYS = {
    "schemaVersion",
    "providerId",
    "featureEnabled",
    "connection",
    "rootSessionPresent",
    "microphoneAcquired",
    "microphoneCurrent",
    "remoteAudioTrackEver",
    "remoteAudioTrackCurrent",
    "remoteAudioPlaybackEver",
    "remoteAudioPlaybackCurrent",
    "userTranscriptCount",
    "assistantTranscriptCount",
    "timerCapabilityReadbackVerified",
    "physicalMediaUserConfirmed",
    "credentialCurrent",
    "lastSafeEvent",
}

SAFE_EVENTS = {
    "initialized",
    "voice_snapshot",
    "media_session_started",
    "microphoneAcquired",
    "microphoneStopped",
    "remoteAudioTrackReceived",
    "remoteAudioTrackStopped",
    "remoteAudioPlaybackSucceeded",
    "remoteAudioPlaybackFailed",
    "remoteAudioPlaybackStopped",
    "safe_close",
    "timer_readback_verified",
    "physical_confirmation_requested",
    "physical_media_user_confirmed",
    "physical_media_user_not_confirmed",
    "credential_available",
    "credential_cleared",
}

BOOL_KEYS = {
    "featureEnabled",
    "rootSessionPresent",
    "microphoneAcquired",
    "microphoneCurrent",
    "remoteAudioTrackEver",
    "remoteAudioTrackCurrent",
    "remoteAudioPlaybackEver",
    "remoteAudioPlaybackCurrent",
    "timerCapabilityReadbackVerified",
    "physicalMediaUserConfirmed",
    "credentialCurrent",
}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL macOS Voice E2E receipt: {message}")


def load_receipt(runtime_root: Path) -> dict[str, object]:
    resolved_root = runtime_root.resolve(strict=True)
    temp_root = Path(os.path.realpath(os.environ.get("TMPDIR", "/tmp")))
    if resolved_root.parent != temp_root:
        fail("runtime root is not a direct child of the system temp directory")
    if not resolved_root.name.startswith("HoverPocketVoiceE2E-"):
        fail("runtime root prefix is invalid")
    receipt_path = runtime_root / "voice-e2e-receipt.json"
    if receipt_path.is_symlink() or not receipt_path.is_file():
        fail("receipt is missing or is a symlink")
    if receipt_path.stat().st_size > 16_384:
        fail("receipt exceeds the size limit")
    try:
        payload = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"receipt could not be decoded ({type(error).__name__})")
    if not isinstance(payload, dict) or set(payload) != ALLOWED_KEYS:
        fail("receipt keys differ from the exact allowlist")
    if payload["schemaVersion"] != 1:
        fail("receipt schema is unsupported")
    if payload["providerId"] not in {"off", "openai_realtime_byok"}:
        fail("provider identifier is invalid")
    if payload["connection"] not in {
        "disconnected",
        "connecting",
        "connected",
        "recovering",
    }:
        fail("connection state is invalid")
    if payload["lastSafeEvent"] not in SAFE_EVENTS:
        fail("safe event is invalid")
    for key in BOOL_KEYS:
        if type(payload[key]) is not bool:
            fail(f"{key} is not boolean")
    for key in ("userTranscriptCount", "assistantTranscriptCount"):
        if type(payload[key]) is not int or not 0 <= payload[key] <= 64:
            fail(f"{key} is outside the safe count range")
    return payload


def validate_stage(payload: dict[str, object], stage: str) -> None:
    if stage == "isolation" or stage == "summary":
        return
    if stage == "physical":
        required = {
            "featureEnabled": True,
            "connection": "connected",
            "rootSessionPresent": True,
            "microphoneAcquired": True,
            "remoteAudioTrackEver": True,
            "remoteAudioPlaybackEver": True,
            "timerCapabilityReadbackVerified": True,
            "physicalMediaUserConfirmed": True,
            "credentialCurrent": True,
        }
        for key, expected in required.items():
            if payload[key] != expected:
                fail(f"physical gate failed at {key}")
        if payload["userTranscriptCount"] < 1 or payload["assistantTranscriptCount"] < 1:
            fail("physical gate requires one complete user and assistant transcript")
        return
    if stage == "stopped":
        for key in (
            "microphoneCurrent",
            "remoteAudioTrackCurrent",
            "remoteAudioPlaybackCurrent",
            "credentialCurrent",
        ):
            if payload[key] is not False:
                fail(f"stopped gate failed at {key}")
        if payload["lastSafeEvent"] != "safe_close":
            fail("stopped gate lacks safe_close readback")
        return
    fail("unknown validation stage")


def run_self_test() -> None:
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "providerId": "openai_realtime_byok",
        "featureEnabled": True,
        "connection": "connected",
        "rootSessionPresent": True,
        "microphoneAcquired": True,
        "microphoneCurrent": True,
        "remoteAudioTrackEver": True,
        "remoteAudioTrackCurrent": True,
        "remoteAudioPlaybackEver": True,
        "remoteAudioPlaybackCurrent": True,
        "userTranscriptCount": 1,
        "assistantTranscriptCount": 1,
        "timerCapabilityReadbackVerified": True,
        "physicalMediaUserConfirmed": True,
        "credentialCurrent": True,
        "lastSafeEvent": "physical_media_user_confirmed",
    }
    if set(payload) != ALLOWED_KEYS:
        fail("self-test fixture keys differ from the exact allowlist")
    validate_stage(payload, "physical")

    rejected = dict(payload)
    rejected["physicalMediaUserConfirmed"] = False
    try:
        validate_stage(rejected, "physical")
    except SystemExit:
        pass
    else:
        fail("self-test accepted a renderer-only physical receipt")

    stopped = dict(payload)
    stopped.update({
        "microphoneCurrent": False,
        "remoteAudioTrackCurrent": False,
        "remoteAudioPlaybackCurrent": False,
        "credentialCurrent": False,
        "lastSafeEvent": "safe_close",
    })
    validate_stage(stopped, "stopped")
    print("PASS macOS Voice E2E receipt self-test: physical, native confirmation, and stopped gates")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--stage",
        choices=("summary", "isolation", "physical", "stopped"),
        default="summary",
    )
    args = parser.parse_args()
    if args.self_test:
        if args.runtime_root is not None:
            parser.error("--self-test cannot be combined with --runtime-root")
        run_self_test()
        return
    if args.runtime_root is None:
        parser.error("--runtime-root is required unless --self-test is used")
    payload = load_receipt(args.runtime_root)
    validate_stage(payload, args.stage)
    print("voice_e2e_receipt=ok")
    print(f"voice_e2e_feature_enabled={str(payload['featureEnabled']).lower()}")
    print(f"voice_e2e_connection={payload['connection']}")
    print(f"voice_e2e_microphone_acquired={str(payload['microphoneAcquired']).lower()}")
    print(f"voice_e2e_remote_audio={str(payload['remoteAudioPlaybackEver']).lower()}")
    print(f"voice_e2e_timer_readback={str(payload['timerCapabilityReadbackVerified']).lower()}")
    print(f"voice_e2e_physical_confirmed={str(payload['physicalMediaUserConfirmed']).lower()}")
    print(f"voice_e2e_credential_current={str(payload['credentialCurrent']).lower()}")
    print(f"voice_e2e_last_safe_event={payload['lastSafeEvent']}")


if __name__ == "__main__":
    main()
