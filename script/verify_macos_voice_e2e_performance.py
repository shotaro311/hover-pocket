#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import time


ALLOWED_KEYS = {
    "schemaVersion",
    "mediaAttemptCount",
    "currentAttemptAttached",
    "microphoneToAttachedSamplesMilliseconds",
    "microphoneToAttachedP95Milliseconds",
    "snapshotPublishCount",
    "expandedRPCCount",
    "realtimeStopRPCCount",
    "maximumRealtimeStopRPCCount",
    "measurementDurationMilliseconds",
    "lastSafeEvent",
}

SAFE_EVENTS = {
    "initialized",
    "media_attempt_started",
    "transport_attached",
    "expanded_rpc",
    "realtime_stop_rpc",
    "safe_close",
    "deterministic_readback",
    "transcript_final",
    "timer_readback_verified",
    "physical_media_user_confirmed",
    "physical_media_user_not_confirmed",
}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL macOS Voice E2E performance: {message}")


def nearest_rank_p95(values: list[float]) -> float:
    if not values:
        fail("cannot calculate p95 without samples")
    ordered = sorted(values)
    rank = max(1, math.ceil(len(ordered) * 0.95))
    return ordered[rank - 1]


def resolve_runtime_root(value: Path) -> Path:
    resolved = value.resolve(strict=True)
    temporary = Path(os.path.realpath(os.environ.get("TMPDIR", "/tmp")))
    if resolved.parent != temporary:
        fail("runtime root is not a direct child of the system temp directory")
    if not resolved.name.startswith("HoverPocketVoiceE2E-"):
        fail("runtime root prefix is invalid")
    return resolved


def validate_process(pid: int, runtime_root: Path) -> None:
    if pid <= 1:
        fail("process identifier is invalid")
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "command="],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        fail("isolated process is not running")
    try:
        arguments = shlex.split(result.stdout.strip())
    except ValueError:
        fail("isolated process command could not be parsed")
    expected_tail = ["--voice-e2e", "--voice-e2e-root", str(runtime_root)]
    if len(arguments) < 4 or arguments[-3:] != expected_tail:
        fail("process does not own the requested isolated runtime root")
    executable = Path(arguments[0])
    if executable.is_symlink() or not executable.is_file():
        fail("isolated process executable is missing or is a symlink")


def sample_process(pid: int, duration: float, interval: float) -> dict[str, float | int]:
    deadline = time.monotonic() + duration
    cpu_samples: list[float] = []
    rss_samples_kib: list[int] = []
    while True:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "%cpu=,rss="],
            check=False,
            capture_output=True,
            text=True,
        )
        fields = result.stdout.split()
        if result.returncode != 0 or len(fields) != 2:
            fail("isolated process ended during sampling")
        try:
            cpu_samples.append(float(fields[0]))
            rss_samples_kib.append(int(fields[1]))
        except ValueError:
            fail("process metrics could not be decoded")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(interval, remaining))
    return {
        "sampleCount": len(cpu_samples),
        "cpuAveragePercent": round(statistics.fmean(cpu_samples), 3),
        "cpuP95Percent": round(nearest_rank_p95(cpu_samples), 3),
        "cpuMaximumPercent": round(max(cpu_samples), 3),
        "rssAverageMiB": round(statistics.fmean(rss_samples_kib) / 1024, 3),
        "rssMaximumMiB": round(max(rss_samples_kib) / 1024, 3),
    }


def load_performance(runtime_root: Path, required: bool) -> dict[str, object] | None:
    receipt_path = runtime_root / "voice-e2e-performance.json"
    if not receipt_path.exists() and not required:
        return None
    if receipt_path.is_symlink() or not receipt_path.is_file():
        fail("performance receipt is missing or is a symlink")
    if receipt_path.stat().st_size > 4_096:
        fail("performance receipt exceeds the size limit")
    try:
        payload = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"performance receipt could not be decoded ({type(error).__name__})")
    if not isinstance(payload, dict) or set(payload) != ALLOWED_KEYS:
        fail("performance receipt keys differ from the exact allowlist")
    if payload["schemaVersion"] != 1:
        fail("performance receipt schema is unsupported")
    if type(payload["currentAttemptAttached"]) is not bool:
        fail("currentAttemptAttached must be a boolean")
    integer_ranges = {
        "mediaAttemptCount": (0, 10_000),
        "snapshotPublishCount": (0, 100_000),
        "expandedRPCCount": (0, 100_000),
        "realtimeStopRPCCount": (0, 100),
        "maximumRealtimeStopRPCCount": (0, 100),
        "measurementDurationMilliseconds": (0, 3_600_000),
    }
    for key, (minimum, maximum) in integer_ranges.items():
        value = payload[key]
        if type(value) is not int or not minimum <= value <= maximum:
            fail(f"{key} is outside the safe range")
    samples = payload["microphoneToAttachedSamplesMilliseconds"]
    if not isinstance(samples, list) or len(samples) > 10:
        fail("microphone latency sample count is invalid")
    if any(type(value) is not int or not 0 <= value <= 30_000 for value in samples):
        fail("microphone latency sample is outside the safe range")
    expected_p95 = int(nearest_rank_p95([float(value) for value in samples])) if samples else None
    if payload["microphoneToAttachedP95Milliseconds"] != expected_p95:
        fail("microphone latency p95 does not match the samples")
    if payload["lastSafeEvent"] not in SAFE_EVENTS:
        fail("performance safe event is invalid")
    return payload


def validate_stage(payload: dict[str, object] | None, stage: str) -> None:
    if stage == "idle":
        return
    if payload is None:
        fail("performance receipt is required for this stage")
    if stage == "active":
        if not payload["currentAttemptAttached"]:
            fail("active stage lacks an attached current media attempt")
        return
    if stage == "stopped":
        stop_count = payload["realtimeStopRPCCount"]
        maximum_stop_count = payload["maximumRealtimeStopRPCCount"]
        if stop_count > 1 or maximum_stop_count > 1:
            fail("a media attempt issued duplicate realtime stop RPCs")
        if payload["currentAttemptAttached"] and stop_count != 1:
            fail("an attached media attempt requires exactly one realtime stop RPC")
        if payload["lastSafeEvent"] != "safe_close":
            fail("stopped stage lacks safe_close performance readback")
        return
    fail("unknown validation stage")


def run_self_test() -> None:
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "mediaAttemptCount": 10,
        "currentAttemptAttached": True,
        "microphoneToAttachedSamplesMilliseconds": [800, 900, 1000],
        "microphoneToAttachedP95Milliseconds": 1000,
        "snapshotPublishCount": 120,
        "expandedRPCCount": 8,
        "realtimeStopRPCCount": 1,
        "maximumRealtimeStopRPCCount": 1,
        "measurementDurationMilliseconds": 10_000,
        "lastSafeEvent": "safe_close",
    }
    if set(payload) != ALLOWED_KEYS:
        fail("self-test fixture keys differ from the exact allowlist")
    validate_stage(payload, "active")
    validate_stage(payload, "stopped")
    if nearest_rank_p95([800, 900, 1000]) != 1000:
        fail("self-test p95 calculation drifted")
    rejected = dict(payload)
    rejected["realtimeStopRPCCount"] = 2
    try:
        validate_stage(rejected, "stopped")
    except SystemExit:
        pass
    else:
        fail("self-test accepted duplicate stop RPCs")
    failed_current = dict(payload)
    failed_current["currentAttemptAttached"] = False
    failed_current["realtimeStopRPCCount"] = 0
    failed_current["maximumRealtimeStopRPCCount"] = 1
    validate_stage(failed_current, "stopped")
    try:
        validate_stage(failed_current, "active")
    except SystemExit:
        pass
    else:
        fail("self-test accepted historical latency as a current attached attempt")
    print(
        "PASS macOS Voice E2E performance self-test: "
        "current attempt, latency p95, and single stop gate"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--stage", choices=("idle", "active", "stopped"), default="idle")
    parser.add_argument("--receipt-only", action="store_true")
    parser.add_argument("--require-receipt", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        if args.runtime_root is not None or args.pid is not None:
            parser.error("--self-test cannot be combined with runtime arguments")
        run_self_test()
        return
    if args.runtime_root is None:
        parser.error("--runtime-root is required")
    if not args.receipt_only and args.pid is None:
        parser.error("--pid is required unless --receipt-only is used")
    if not 1.0 <= args.duration <= 300.0:
        parser.error("--duration must be between 1 and 300 seconds")
    if not 0.1 <= args.interval <= 5.0:
        parser.error("--interval must be between 0.1 and 5 seconds")
    runtime_root = resolve_runtime_root(args.runtime_root)
    process_metrics: dict[str, float | int] | None = None
    if not args.receipt_only:
        validate_process(args.pid, runtime_root)
        process_metrics = sample_process(args.pid, args.duration, args.interval)
    performance = load_performance(
        runtime_root,
        required=args.require_receipt or args.stage != "idle",
    )
    validate_stage(performance, args.stage)
    result: dict[str, object] = {
        "stage": args.stage,
        "process": process_metrics,
        "performanceReceiptPresent": performance is not None,
    }
    if performance is not None:
        duration_seconds = max(
            float(performance["measurementDurationMilliseconds"]) / 1000,
            0.001,
        )
        result["voice"] = {
            "mediaAttemptCount": performance["mediaAttemptCount"],
            "currentAttemptAttached": performance["currentAttemptAttached"],
            "microphoneToAttachedSampleCount": len(
                performance["microphoneToAttachedSamplesMilliseconds"]
            ),
            "microphoneToAttachedP95Milliseconds": performance[
                "microphoneToAttachedP95Milliseconds"
            ],
            "snapshotPublishesPerSecond": round(
                float(performance["snapshotPublishCount"]) / duration_seconds,
                3,
            ),
            "expandedRPCsPerSecond": round(
                float(performance["expandedRPCCount"]) / duration_seconds,
                3,
            ),
            "realtimeStopRPCCount": performance["realtimeStopRPCCount"],
            "maximumRealtimeStopRPCCount": performance[
                "maximumRealtimeStopRPCCount"
            ],
        }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
