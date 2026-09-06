#!/usr/bin/env python3
"""Offline, bounded playback-progress evidence evaluator. No app/network control.

A passed result proves only sustained sampled playhead progress, never visible frames,
hardware decode, server cleanup, or video-copy negotiation. Inputs are allowlisted.
"""
import argparse
import base64
import re
import json
import math
import sys
from pathlib import Path

MAX_BYTES = 256 * 1024
MAX_SAMPLES = 601


class InvalidEvidence(ValueError):
    pass


def exact_keys(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise InvalidEvidence("invalid_fields")


def number(value, low, high):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise InvalidEvidence("invalid_number")


def validate(payload):
    """Strict v1 structural and semantic schema; errors never echo input fields."""
    exact_keys(payload, ("schemaVersion", "evidenceKind", "backend", "generation", "holdSeconds", "stallToleranceSeconds", "samples"))
    if type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 1:
        raise InvalidEvidence("unsupported_schema")
    if payload["evidenceKind"] not in ("synthetic", "liveController", "rawPlayer"):
        raise InvalidEvidence("invalid_evidence_kind")
    if payload["backend"] not in ("fixture", "plex", "jellyfin", "emby", "unknown"):
        raise InvalidEvidence("invalid_backend")
    if (payload["evidenceKind"] == "synthetic") != (payload["backend"] == "fixture"):
        raise InvalidEvidence("invalid_fixture_scope")
    generation = payload["generation"]
    if type(generation) is not int or not 1 <= generation <= 1_000_000:
        raise InvalidEvidence("invalid_generation")
    number(payload["holdSeconds"], 5, 300)
    number(payload["stallToleranceSeconds"], 1, 60)
    samples = payload["samples"]
    if not isinstance(samples, list) or not 2 <= len(samples) <= MAX_SAMPLES:
        raise InvalidEvidence("invalid_sample_count")
    last = -1
    for sample in samples:
        exact_keys(sample, ("elapsedSeconds", "positionSeconds", "phase", "generation"))
        number(sample["elapsedSeconds"], 0, 360)
        number(sample["positionSeconds"], 0, 7 * 24 * 3600)
        if sample["elapsedSeconds"] <= last:
            raise InvalidEvidence("nonmonotonic_clock")
        last = sample["elapsedSeconds"]
        if sample["phase"] not in ("playing", "waiting", "paused", "failed", "cancelled"):
            raise InvalidEvidence("invalid_phase")
        if type(sample["generation"]) is not int or sample["generation"] != generation:
            raise InvalidEvidence("stale_generation")
    if samples[0]["elapsedSeconds"] != 0:
        raise InvalidEvidence("missing_baseline")
    return payload


def evaluate(payload):
    validate(payload)
    samples = payload["samples"]
    hold = payload["holdSeconds"]
    tolerance = payload["stallToleranceSeconds"]
    duration = samples[-1]["elapsedSeconds"]
    result = {
        "schemaVersion": 1,
        "evidenceKind": payload["evidenceKind"],
        "backend": payload["backend"],
        "status": "blocked",
        "reason": "insufficient_observation",
        "observedSeconds": duration,
        "movingSeconds": 0,
        "videoDecision": "unknown",
        "audioDecision": "unknown",
        "visibleAttachment": "unknown",
        "hardwareDecode": "unknown",
        "serverCleanup": "unknown",
    }

    def finish(status, reason):
        result.update(status=status, reason=reason)
        return result

    moving = 0.0
    idle = 0.0
    # Do not allow a large seek to masquerade as playback or bridge an observation gap.
    for previous, current in zip(samples, samples[1:]):
        dt = current["elapsedSeconds"] - previous["elapsedSeconds"]
        dp = current["positionSeconds"] - previous["positionSeconds"]
        if current["phase"] == "cancelled" or previous["phase"] == "cancelled":
            return finish("blocked", "cancelled")
        if current["phase"] == "failed" or previous["phase"] == "failed":
            return finish("failed", "player_failed")
        if dt > 2:
            return finish("blocked", "observation_gap")
        if dp < -0.25 or dp > dt * 1.5 + 0.25:
            return finish("blocked", "timeline_discontinuity")
        progressing = (current["phase"] == previous["phase"] == "playing" and dp >= dt * 0.5)
        if progressing:
            moving += dt
            idle = 0
        else:
            idle += dt
        result["movingSeconds"] = round(moving, 3)
        if idle >= tolerance:
            return finish("failed", "sustained_nonprogress")
    # A brief initial advance followed by a frozen end is never a pass. This oracle is
    # for uninterrupted 1x holds; intentional pauses/seeks need separate phase windows.
    if duration > hold + tolerance:
        return finish("failed", "deadline_exceeded")
    if duration >= hold and moving >= hold * 0.8 and idle == 0:
        return finish("passed", "sustained_sampled_progress")
    if duration >= hold + tolerance:
        return finish("failed", "insufficient_progress")
    return result


def validate_report(payload):
    """Allowlisted live-controller report, separate from sampled progress input."""
    exact_keys(payload, ("schemaVersion", "evidenceKind", "scenario", "status", "reason", "snapshots"))
    if type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 1 or payload["evidenceKind"] != "liveController":
        raise InvalidEvidence("unsupported_schema")
    if payload["scenario"] not in ("original", "seek", "capped", "maximum", "consentDecline", "consentApprove", "audio", "subtitles"):
        raise InvalidEvidence("invalid_scenario")
    if payload["status"] not in ("passed", "failed", "blocked"):
        raise InvalidEvidence("invalid_status")
    reasons = ("completed", "missingAdmission", "invalidOptions", "missingAuth", "unsupportedTrack", "consentNotPending",
               "decisionUnknown", "cancelled", "playbackFailed", "deadline", "backendChanged", "staleGeneration")
    if payload["reason"] not in reasons or (payload["status"] == "passed") != (payload["reason"] == "completed"):
        raise InvalidEvidence("invalid_reason")
    snapshots = payload["snapshots"]
    if not isinstance(snapshots, list) or len(snapshots) > 8:
        raise InvalidEvidence("invalid_snapshots")
    enums = {
        "phase": ("playing", "waiting", "paused", "failed", "consent", "stopped"),
        "backend": ("plex", "jellyfin", "emby", "offline", "unknown"),
        "videoDecision": ("copy", "encode", "unknown"), "audioDecision": ("copy", "encode", "unknown"),
        "videoProvenance": ("serverDecision", "enforcedRequest", "unknown"),
        "consent": ("pending", "notPending"), "visibleAttachment": ("attached", "detached", "unknown"),
        "renderedFormat": ("avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "unknown"),
        "serverCleanup": ("unknown",),
    }
    numeric = {"buildNumber": 1_000_000, "generation": 1_000_000, "qualityKbps": 1_000_000,
               "positionBucketSeconds": 604_800, "bufferBucketSeconds": 3600, "schemaVersion": 1}
    for snapshot in snapshots:
        exact_keys(snapshot, (*enums, *numeric, "cleanupRequested"))
        for key, choices in enums.items():
            if snapshot[key] not in choices:
                raise InvalidEvidence("invalid_snapshot_enum")
        for key, maximum in numeric.items():
            if type(snapshot[key]) is not int or not 0 <= snapshot[key] <= maximum:
                raise InvalidEvidence("invalid_snapshot_number")
        if snapshot["schemaVersion"] != 1 or type(snapshot["cleanupRequested"]) is not bool:
            raise InvalidEvidence("invalid_snapshot")
    if payload["status"] == "passed" and (not snapshots or not snapshots[-1]["cleanupRequested"] or snapshots[-1]["phase"] != "stopped"):
        raise InvalidEvidence("missing_terminal_cleanup_request")
    return payload


def fixture():
    return {
        "schemaVersion": 1, "evidenceKind": "synthetic", "backend": "fixture",
        "generation": 1, "holdSeconds": 60, "stallToleranceSeconds": 10,
        "samples": [{"elapsedSeconds": t, "positionSeconds": t, "phase": "playing", "generation": 1}
                    for t in range(61)],
    }


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidEvidence("duplicate_field")
        result[key] = value
    return result


def report_from_unified_log(data):
    """Reassemble one exact-PID log pull; missing/reordered/truncated parts cannot pass."""
    parts = []
    expected = None
    completed = None
    for line in data.splitlines():
        event = json.loads(line, object_pairs_hook=unique_object)
        message = event.get("eventMessage", "")
        if not message.startswith("evidence.run.part "):
            continue
        match = re.fullmatch(r"evidence.run.part index=(\d+) count=(\d+) payload=([A-Za-z0-9+/=]{1,512})", message)
        if not match:
            raise InvalidEvidence("invalid_fragment")
        index, count = int(match[1]), int(match[2])
        if not 1 <= count <= 86 or index != len(parts) or (expected is not None and count != expected):
            raise InvalidEvidence("invalid_fragment_order")
        expected = count
        parts.append(match[3])
        if len(parts) == count:
            decoded = base64.b64decode("".join(parts), validate=True)
            if len(decoded) > 32 * 1024:
                raise InvalidEvidence("payload_too_large")
            completed = validate_report(json.loads(decoded, object_pairs_hook=unique_object))
            parts, expected = [], None
    if parts or completed is None:
        raise InvalidEvidence("incomplete_report")
    return completed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path)
    parser.add_argument("--unified-log", action="store_true", help="Validate ordered report fragments from an exact-PID NDJSON log pull")
    parser.add_argument("--report", action="store_true", help="Validate a typed live-controller run report")
    parser.add_argument("--fixture", action="store_true", help="Synthetic oracle self-check; does not launch Labstream")
    args = parser.parse_args()
    if bool(args.input) == args.fixture:
        parser.error("choose an input file or --fixture")
    try:
        if args.fixture:
            payload = fixture()
        else:
            with args.input.open("rb") as handle:
                data = handle.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise InvalidEvidence("payload_too_large")
            payload = report_from_unified_log(data) if args.unified_log else json.loads(data, object_pairs_hook=unique_object)
        result = validate_report(payload) if args.report or args.unified_log else evaluate(payload)
    except (ValueError, OSError, RecursionError, TypeError):
        # No raw parser errors, file paths, or attacker-controlled field names escape.
        result = {"schemaVersion": 1, "status": "blocked", "reason": "invalid_evidence"}
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return {"passed": 0, "failed": 1, "blocked": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
