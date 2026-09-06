#!/usr/bin/env python3
"""Offline, bounded playback-progress evidence evaluator. No app/network control.

A passed result proves only sustained sampled playhead progress, never visible frames,
hardware decode, server cleanup, or video-copy negotiation. Inputs are allowlisted.
"""
import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path)
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
            payload = json.loads(data, object_pairs_hook=unique_object)
        result = evaluate(payload)
    except (ValueError, OSError, RecursionError, TypeError):
        # No raw parser errors, file paths, or attacker-controlled field names escape.
        result = {"schemaVersion": 1, "status": "blocked", "reason": "invalid_evidence"}
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return {"passed": 0, "failed": 1, "blocked": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
