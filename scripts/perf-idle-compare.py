#!/usr/bin/env python3
"""Compare paired macOS idle System Trace evidence without weakening latency evidence.

The primary input is the JSON result emitted by perf-macos-launch-idle.py.  That
preserves failed arms, while every successful arm is independently revalidated
through the performance-audit manifest and typed idle evidence contract.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import io
import json
import math
import os
import pathlib
import random
import re
import stat
import statistics
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
CONTRACT_SCRIPT = SCRIPT_DIR / "performance-audit-contract.py"
_spec = importlib.util.spec_from_file_location("labstream_idle_compare_contract", CONTRACT_SCRIPT)
assert _spec and _spec.loader
contract = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = contract
_spec.loader.exec_module(contract)

TOOL = {"name": "labstream-perf-idle-compare", "version": "1"}
THRESHOLD_TOOL = {"name": "labstream-perf-idle-thresholds", "version": "1"}
BOOTSTRAP_RESAMPLES = 10_000
CONFIDENCE_LEVEL = 0.95
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
SAFE_TEXT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 .,:_+/%()-]{0,255}$")
METRICS = ("cpu_running_ns_per_second", "wakeups_per_minute")
CANONICAL_INDEX = {
    "relative_path": "Data/Library/Application Support/Labstream/Downloads/index.json",
    "sha256": "109c196b8a013bc4ca80a3de58b26981571817011021e92eb0dbcd35827906e1",
    "bytes": 30,
}


class IdleCompareError(ValueError):
    pass


@dataclass(frozen=True)
class IdleSample:
    manifest_path: pathlib.Path
    manifest_sha256: str
    manifest: dict[str, Any]
    summary: dict[str, Any]

    @property
    def role(self) -> str:
        return self.manifest["run"]["artifact_role"]

    @property
    def kind(self) -> str:
        return self.manifest["run"]["sample_kind"]

    @property
    def index(self) -> int:
        return self.manifest["run"]["sample_index"]

    @property
    def recorded_at(self) -> datetime:
        return _utc(self.manifest["run"]["recorded_at"])

    @property
    def actual_duration_ns(self) -> int:
        return self.summary["capture"]["actual_duration_ns"]

    @property
    def rates(self) -> dict[str, float]:
        duration = self.actual_duration_ns
        metrics = self.summary["metrics"]
        return {
            "cpu_running_ns_per_second": metrics["cpu_running_ns"] * 1_000_000_000 / duration,
            "wakeups_per_minute": metrics["wakeups_count"] * 60_000_000_000 / duration,
        }


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise IdleCompareError(f"{label} must contain exactly the closed fields")
    return value


def _finite(value: Any, label: str, *, minimum: float = 0.0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise IdleCompareError(f"{label} must be a finite number")
    number = float(value)
    if not math.isfinite(number) or number < minimum:
        raise IdleCompareError(f"{label} must be finite and at least {minimum}")
    return number


def _utc(value: Any) -> datetime:
    if not isinstance(value, str):
        raise IdleCompareError("recorded_at must be a UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise IdleCompareError("recorded_at must be a UTC timestamp") from error
    if parsed.utcoffset() is None or parsed.utcoffset().total_seconds() != 0:
        raise IdleCompareError("recorded_at must use UTC")
    return parsed


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _opaque(prefix: str, *values: object, length: int = 12) -> str:
    digest = hashlib.sha256("\0".join(map(str, values)).encode()).hexdigest()[:length]
    return f"{prefix}-{digest}"


def _read_json_with_sha(path: pathlib.Path, label: str) -> tuple[dict[str, Any], str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise IdleCompareError(f"{label} must be a readable regular non-symlink file") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or info.st_size > 8 * 1024 * 1024:
            raise IdleCompareError(f"{label} must be a bounded regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            data = handle.read()
    finally:
        os.close(descriptor)
    try:
        value = json.loads(data)
    except json.JSONDecodeError as error:
        raise IdleCompareError(f"{label} must be readable JSON") from error
    if not isinstance(value, dict):
        raise IdleCompareError(f"{label} must be a JSON object")
    return value, hashlib.sha256(data).hexdigest()


def _read_bound_json(path: pathlib.Path, expected_sha256: str, label: str) -> dict[str, Any]:
    if not isinstance(expected_sha256, str) or SHA256_RE.fullmatch(expected_sha256) is None:
        raise IdleCompareError(f"{label} has an invalid expected checksum")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise IdleCompareError(f"{label} must be a readable regular non-symlink file") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or info.st_size > 2 * 1024 * 1024:
            raise IdleCompareError(f"{label} must be a bounded regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            data = handle.read()
    finally:
        os.close(descriptor)
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise IdleCompareError(f"{label} checksum mismatch")
    try:
        value = json.loads(data)
    except json.JSONDecodeError as error:
        raise IdleCompareError(f"{label} must be readable JSON") from error
    if not isinstance(value, dict):
        raise IdleCompareError(f"{label} must be a JSON object")
    return value


def _validated_failure(value: Any) -> dict[str, str]:
    failure = _exact(value, {"type", "message"}, "idle capture failure")
    if (not isinstance(failure["type"], str)
            or re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]{0,127}", failure["type"]) is None
            or not isinstance(failure["message"], str)
            or not failure["message"]
            or len(failure["message"].encode("utf-8")) > 4096
            or any(not character.isprintable() for character in failure["message"])):
        raise IdleCompareError("idle capture failure is not bounded printable metadata")
    # The runner result remains the authoritative local diagnostic. Comparison output
    # retains the failure and its schedule identity without republishing free-form text.
    return {"type": failure["type"], "message": failure["message"]}


def _expected_schedule(seed: int, warmups: int = 1, measured: int = 5) -> list[dict[str, Any]]:
    order_seed = "seed-" + hashlib.sha256(str(seed).encode()).hexdigest()[:16]
    result: list[dict[str, Any]] = []
    for kind, count in (("warmup", warmups), ("measured", measured)):
        for index in range(count):
            first = ("control" if hashlib.sha256(
                f"{order_seed}:{kind}:{index}".encode()).digest()[0] & 1 == 0 else "candidate")
            for pair_order, role in enumerate((first, "candidate" if first == "control" else "control"), 1):
                result.append({"scenario": "idle", "sample_kind": kind, "sample_index": index,
                               "pair_order": pair_order, "role": role})
    return result


def _environment(sample: IdleSample) -> dict[str, Any]:
    manifest = sample.manifest
    product, device = manifest["product"], manifest["device"]
    return {
        "tool": manifest["tool"],
        "product": {key: product[key] for key in (
            "configuration", "target", "platform", "os_build", "xcode_build")},
        "device": {"label": device["label"], "display_mode": device["display_mode"]},
        "state": manifest["state"], "scenario": manifest["scenario"],
        "launch_contract": manifest["launch_contract"],
    }


def _load_sample(record: dict[str, Any], runner: dict[str, Any]) -> IdleSample:
    raw_path = pathlib.Path(record["manifest"])
    path = raw_path.resolve()
    if raw_path.is_symlink() or not raw_path.is_file() or raw_path.absolute() != path:
        raise IdleCompareError("successful record manifest must be a canonical regular file")
    if not isinstance(record.get("manifest_sha256"), str) or not SHA256_RE.fullmatch(
            record["manifest_sha256"]):
        raise IdleCompareError("successful record has an invalid manifest checksum")
    manifest = _read_bound_json(path, record["manifest_sha256"], "successful record manifest")
    try:
        contract.validate_manifest(manifest, path.parent)
    except contract.ContractError as error:
        raise IdleCompareError(f"idle manifest contract failed: {error}") from error
    if manifest["scenario"]["category"] != "idle":
        raise IdleCompareError("successful record does not contain idle evidence")
    expected = {
        "artifact_role": record["role"], "sample_kind": record["sample_kind"],
        "sample_index": record["sample_index"],
    }
    if any(manifest["run"][key] != value for key, value in expected.items()):
        raise IdleCompareError("record schedule does not match its manifest")
    identities = runner["identities"]
    if (manifest["run"]["comparison_id"] != identities["comparison_id"]
            or manifest["run"]["order_seed"] != identities["order_seed"]
            or manifest["scenario"]["id"] != identities["scenario_id"]
            or manifest["scenario"]["fixture_id"] != identities["fixture_id"]):
        raise IdleCompareError("manifest identity does not match the paired runner result")
    if manifest["scenario"]["fixture_sha256"] != CANONICAL_INDEX["sha256"]:
        raise IdleCompareError("manifest fixture checksum does not match the canonical idle seed")
    if manifest["product"]["commit"] != runner["commits"][record["role"]]:
        raise IdleCompareError("manifest commit does not match the paired runner result")
    expected_run_id = _opaque("run", identities["comparison_id"], "idle", record["role"],
                              record["sample_kind"], record["sample_index"], record["pair_order"])
    if manifest["run"]["id"] != expected_run_id:
        raise IdleCompareError("manifest run id does not derive from its exact paired schedule")
    output = pathlib.Path(runner["output"])
    expected_root = output.parent / f"{output.stem}-logs"
    expected_path = expected_root / expected_run_id / "manifest.json"
    if path != expected_path.resolve() or expected_path.absolute() != expected_path.resolve():
        raise IdleCompareError("successful manifest is outside its exact runner evidence slot")
    summary_path = path.parent / manifest["evidence"]["redacted_summary"]["path"]
    summary = _read_bound_json(summary_path,
                               manifest["evidence"]["redacted_summary"]["sha256"],
                               "idle redacted summary")
    return IdleSample(path, record["manifest_sha256"], manifest, summary)


def load_runner(path: pathlib.Path) -> tuple[dict[str, Any], list[dict[str, Any]], list[IdleSample], str]:
    runner, runner_sha256 = _read_json_with_sha(path, "paired idle runner result")
    required = {"schema_version", "mode", "scenario", "seed", "warmups", "measured", "output",
                "canonical_index",
                "duration_seconds", "identities", "commits", "records", "capture_status"}
    if not required <= set(runner):
        raise IdleCompareError("paired idle runner result is missing required fields")
    if (runner["schema_version"] != 1 or runner["mode"] != "capture"
            or runner["scenario"] != "idle" or type(runner["seed"]) is not int
            or type(runner["warmups"]) is not int or not 0 <= runner["warmups"] <= 100
            or type(runner["measured"]) is not int or not 0 <= runner["measured"] <= 100
            or runner["warmups"] + runner["measured"] == 0
            or type(runner["duration_seconds"]) is not int or runner["duration_seconds"] <= 0):
        raise IdleCompareError("paired idle runner result has an invalid declared capture policy")
    if not isinstance(runner["output"], str) or not pathlib.Path(runner["output"]).is_absolute():
        raise IdleCompareError("paired idle runner output must be an absolute path")
    identities = _exact(runner["identities"], {
        "comparison_id", "fixture_id", "order_seed", "scenario_id", "workload_id"},
        "runner identities")
    if (not contract.COMPARISON_ID_RE.fullmatch(identities["comparison_id"])
            or not contract.ORDER_SEED_RE.fullmatch(identities["order_seed"])):
        raise IdleCompareError("runner comparison or order identity is invalid")
    expected_order_seed = "seed-" + hashlib.sha256(str(runner["seed"]).encode()).hexdigest()[:16]
    if identities["order_seed"] != expected_order_seed:
        raise IdleCompareError("runner order_seed does not derive from its seed")
    commits = _exact(runner["commits"], {"control", "candidate"}, "runner commits")
    if (any(not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{40}", value) is None
            for value in commits.values()) or commits["control"] == commits["candidate"]):
        raise IdleCompareError("runner commits must be distinct exact commit identities")
    canonical_index = _exact(runner["canonical_index"], {"relative_path", "sha256", "bytes"},
                             "runner canonical index")
    if canonical_index != CANONICAL_INDEX:
        raise IdleCompareError("runner canonical index identity is unsupported")
    expected_identities = {
        "comparison_id": _opaque("comparison", runner["seed"], commits["control"], commits["candidate"]),
        "workload_id": _opaque("workload", runner["seed"], commits["control"], commits["candidate"],
                               "idle.metrics"),
        "scenario_id": _opaque("scenario", runner["seed"], commits["control"], commits["candidate"],
                               "idle"),
        "fixture_id": _opaque("fixture", runner["seed"], commits["control"], commits["candidate"],
                              canonical_index["sha256"]),
        "order_seed": expected_order_seed,
    }
    if identities != expected_identities:
        raise IdleCompareError("runner identities do not derive from seed, commits, and fixture")
    records = runner["records"]
    expected_count = 2 * (runner["warmups"] + runner["measured"])
    if not isinstance(records, list) or len(records) != expected_count:
        raise IdleCompareError("runner result must retain every arm in its declared capture policy")
    schedule = _expected_schedule(runner["seed"], runner["warmups"], runner["measured"])
    loaded: list[IdleSample] = []
    allowed_record_keys = {"scenario", "sample_kind", "sample_index", "pair_order", "role",
                           "status", "failure", "manifest", "manifest_sha256", "trace",
                           "pid", "start_utc", "end_utc"}
    for position, (record, expected) in enumerate(zip(records, schedule, strict=True)):
        if not isinstance(record, dict) or not set(record) <= allowed_record_keys:
            raise IdleCompareError(f"runner record {position} has unsupported fields")
        if any(record.get(key) != value for key, value in expected.items()):
            raise IdleCompareError(f"runner record {position} violates the seeded schedule")
        if record.get("status") not in {"success", "failure"}:
            raise IdleCompareError(f"runner record {position} has an invalid status")
        if record["status"] == "success":
            if record.get("failure") is not None:
                raise IdleCompareError("successful runner record contains a failure")
            loaded.append(_load_sample(record, runner))
        else:
            _validated_failure(record.get("failure"))
    expected_capture = "failure" if any(record["status"] == "failure" for record in records) else "success"
    if runner["capture_status"] != expected_capture:
        raise IdleCompareError("runner capture_status does not match its retained records")
    return runner, records, loaded, runner_sha256


def load_thresholds(path: pathlib.Path, sha256: str, *, duration_seconds: int) -> dict[str, Any]:
    document = _read_bound_json(path, sha256, "idle threshold artifact")
    legacy_fields = {
        "schema_version", "tool", "sample_policy", "duration_seconds", "rationale", "metrics"}
    derived_fields = legacy_fields | {"control_provenance"}
    if not isinstance(document, dict) or set(document) not in (legacy_fields, derived_fields):
        raise IdleCompareError("idle threshold artifact must contain exactly the closed fields")
    artifact = document
    if (artifact["schema_version"] != 1 or artifact["tool"] != THRESHOLD_TOOL
            or artifact["sample_policy"] != "long"
            or artifact["duration_seconds"] != duration_seconds
            or not isinstance(artifact["rationale"], str)
            or SAFE_TEXT_RE.fullmatch(artifact["rationale"]) is None):
        raise IdleCompareError("idle threshold artifact metadata is unsupported")
    metrics = _exact(artifact["metrics"], set(METRICS), "idle threshold metrics")
    for name in METRICS:
        threshold = _exact(metrics[name], {"absolute_mde", "relative_mde_percent"},
                           f"idle threshold {name}")
        absolute = _finite(threshold["absolute_mde"], f"{name} absolute MDE")
        relative = _finite(threshold["relative_mde_percent"], f"{name} relative MDE")
        if absolute > 1e18 or relative > 1_000_000:
            raise IdleCompareError(f"{name} threshold exceeds its bound")
        if absolute == 0 and relative == 0:
            raise IdleCompareError(f"{name} threshold cannot be entirely zero")
    if "control_provenance" in artifact:
        provenance = _exact(artifact["control_provenance"], {
            "kind", "pilot_runner_result_sha256", "comparison_id", "order_seed",
            "commit", "product_sha256", "evidence_manifests", "derivation"},
            "idle threshold control provenance")
        identity_fields = ("pilot_runner_result_sha256", "comparison_id", "order_seed",
                           "commit", "product_sha256")
        if (provenance["kind"] != "control_only_pilot"
                or any(not isinstance(provenance[field], str) for field in identity_fields)
                or SHA256_RE.fullmatch(provenance["pilot_runner_result_sha256"]) is None
                or not contract.COMPARISON_ID_RE.fullmatch(provenance["comparison_id"])
                or not contract.ORDER_SEED_RE.fullmatch(provenance["order_seed"])
                or re.fullmatch(r"[a-f0-9]{40}", provenance["commit"]) is None
                or SHA256_RE.fullmatch(provenance["product_sha256"]) is None):
            raise IdleCompareError("idle threshold control provenance identity is invalid")
        derivation = _exact(provenance["derivation"], {
            "bootstrap_resamples", "confidence_level", "statistic",
            "relative_formula", "absolute_formula", "zero_wakeup_floor"},
            "idle threshold derivation")
        if (derivation != {
                "bootstrap_resamples": BOOTSTRAP_RESAMPLES,
                "confidence_level": CONFIDENCE_LEVEL,
                "statistic": "median_of_control_rates",
                "relative_formula": "max(5_percent,2x_relative_ci_width)",
                "absolute_formula": "2x_absolute_ci_width",
                "zero_wakeup_floor": 60/duration_seconds}):
            raise IdleCompareError("idle threshold derivation contract is unsupported")
        manifests = provenance["evidence_manifests"]
        if not isinstance(manifests, list) or len(manifests) != 5:
            raise IdleCompareError("idle threshold provenance requires five control manifests")
        for index, item in enumerate(manifests):
            entry = _exact(item, {"run_id", "sample_index", "sha256"},
                           "idle threshold evidence manifest")
            if (type(entry["sample_index"]) is not int or entry["sample_index"] != index
                    or not isinstance(entry["run_id"], str)
                    or re.fullmatch(r"run-[a-f0-9]{12}", entry["run_id"]) is None
                    or not isinstance(entry["sha256"], str)
                    or SHA256_RE.fullmatch(entry["sha256"]) is None):
                raise IdleCompareError("idle threshold evidence manifest identity is invalid")
    return artifact


def freeze_thresholds(runner: dict[str, Any], records: list[dict[str, Any]],
                      samples: list[IdleSample], *, runner_sha256: str,
                      rationale: str) -> dict[str, Any]:
    """Derive a guardrail from the five measured control arms of one pilot only."""
    if (runner["warmups"], runner["measured"], runner["duration_seconds"]) != (1, 5, 120):
        raise IdleCompareError(
            "threshold freeze requires exactly one warmup, five measured pairs, and 120 seconds")
    if runner["capture_status"] != "success" or any(
            record["status"] != "success" for record in records):
        raise IdleCompareError("threshold freeze requires a completed successful pilot")
    if not isinstance(rationale, str) or SAFE_TEXT_RE.fullmatch(rationale) is None:
        raise IdleCompareError("threshold rationale must be bounded safe text")
    all_controls = [
        sample for sample in samples if sample.role == "control"]
    controls = sorted(
        (sample for sample in samples if sample.role == "control" and sample.kind == "measured"),
        key=lambda sample: sample.index)
    if (len(all_controls) != 6 or len(controls) != 5
            or [sample.index for sample in controls] != list(range(5))):
        raise IdleCompareError("threshold freeze requires five successful measured control samples")
    scheduled_controls = [
        next((sample for sample in all_controls
              if sample.kind == raw["sample_kind"] and sample.index == raw["sample_index"]), None)
        for raw in _expected_schedule(runner["seed"], 1, 5) if raw["role"] == "control"
    ]
    if (any(sample is None for sample in scheduled_controls)
            or any(left.recorded_at >= right.recorded_at
                   for left, right in zip(scheduled_controls, scheduled_controls[1:]))):
        raise IdleCompareError("threshold control samples violate strict schedule chronology")
    if len({_canonical_sha256(_environment(sample)) for sample in all_controls}) != 1:
        raise IdleCompareError("threshold control environment differs across samples")
    if len({sample.manifest["product"]["commit"] for sample in all_controls}) != 1:
        raise IdleCompareError("threshold control commit differs across samples")
    if len({sample.manifest["product"]["sha256"] for sample in all_controls}) != 1:
        raise IdleCompareError("threshold control product checksum differs across samples")
    mutable = {(sample.manifest["device"]["power_source"],
                sample.manifest["device"]["battery_state"],
                sample.manifest["device"]["thermal_state"]) for sample in all_controls}
    if len(mutable) != 1:
        raise IdleCompareError(
            "threshold control power, battery, and thermal state must remain stable")
    power, battery, thermal = next(iter(mutable))
    if (power != "external" or battery not in {"charging", "full", "not_applicable"}
            or thermal not in {"nominal", "fair"}):
        raise IdleCompareError(
            "threshold freeze requires external power and nominal or fair thermal state")

    thresholds: dict[str, dict[str, float]] = {}
    for metric in METRICS:
        values = [sample.rates[metric] for sample in controls]
        median = statistics.median(values)
        low, high = _bootstrap(values, _metric_seed(
            runner["identities"]["order_seed"], f"control-threshold:{metric}"))
        width = high - low
        if metric == "cpu_running_ns_per_second" and median == 0 and width == 0:
            raise IdleCompareError("zero CPU baseline is non-informative for threshold derivation")
        relative_width = 0.0 if median == 0 else 100.0 * width / median
        absolute = 2.0 * width
        if metric == "wakeups_per_minute" and median == 0:
            absolute = max(absolute, 60.0 / runner["duration_seconds"])
        thresholds[metric] = {
            "absolute_mde": absolute,
            "relative_mde_percent": max(5.0, 2.0 * relative_width),
        }

    product_hashes = {sample.manifest["product"]["sha256"] for sample in controls}
    return {
        "schema_version": 1,
        "tool": THRESHOLD_TOOL,
        "sample_policy": "long",
        "duration_seconds": runner["duration_seconds"],
        "rationale": rationale,
        "metrics": thresholds,
        "control_provenance": {
            "kind": "control_only_pilot",
            "pilot_runner_result_sha256": runner_sha256,
            "comparison_id": runner["identities"]["comparison_id"],
            "order_seed": runner["identities"]["order_seed"],
            "commit": runner["commits"]["control"],
            "product_sha256": next(iter(product_hashes)),
            "evidence_manifests": [
                {"run_id": sample.manifest["run"]["id"], "sample_index": sample.index,
                 "sha256": sample.manifest_sha256}
                for sample in controls
            ],
            "derivation": {
                "bootstrap_resamples": BOOTSTRAP_RESAMPLES,
                "confidence_level": CONFIDENCE_LEVEL,
                "statistic": "median_of_control_rates",
                "relative_formula": "max(5_percent,2x_relative_ci_width)",
                "absolute_formula": "2x_absolute_ci_width",
                "zero_wakeup_floor": 60 / runner["duration_seconds"],
            },
        },
    }


def _bootstrap(values: list[float], seed: int) -> tuple[float, float]:
    rng = random.Random(seed)
    estimates = sorted(statistics.median(rng.choices(values, k=len(values)))
                       for _ in range(BOOTSTRAP_RESAMPLES))
    def quantile(probability: float) -> float:
        rank = (len(estimates) - 1) * probability
        low, high = math.floor(rank), math.ceil(rank)
        if low == high:
            return estimates[low]
        return estimates[low] + (estimates[high] - estimates[low]) * (rank - low)
    alpha = (1.0 - CONFIDENCE_LEVEL) / 2.0
    return quantile(alpha), quantile(1.0 - alpha)


def _metric_seed(order_seed: str, metric: str) -> int:
    return int.from_bytes(hashlib.sha256(f"{order_seed}:{metric}".encode()).digest()[:8], "big")


def compare(runner_path: pathlib.Path, runner: dict[str, Any], records: list[dict[str, Any]],
            samples: list[IdleSample], *, runner_sha256: str, thresholds: dict[str, Any] | None,
            threshold_path: pathlib.Path | None, threshold_sha256: str | None,
            max_storage_drift: int, max_pair_start_gap: float,
            max_window_drift_ns: int) -> dict[str, Any]:
    if max_storage_drift < 0 or max_window_drift_ns < 0:
        raise IdleCompareError("storage and window drift tolerances must be nonnegative")
    if (not math.isfinite(max_pair_start_gap) or max_pair_start_gap <= runner["duration_seconds"]):
        raise IdleCompareError("pair start-gap tolerance must exceed the capture duration")
    if thresholds is not None and "control_provenance" in thresholds:
        provenance = thresholds["control_provenance"]
        if provenance["pilot_runner_result_sha256"] == runner_sha256:
            raise IdleCompareError(
                "threshold pilot and verdict must be separate paired runner results")
        if (provenance["comparison_id"] == runner["identities"]["comparison_id"]
                or provenance["order_seed"] == runner["identities"]["order_seed"]):
            raise IdleCompareError(
                "threshold pilot and verdict require distinct comparison and order identities")
        pilot_run_ids = {
            item["run_id"] for item in provenance["evidence_manifests"]}
        pilot_manifest_hashes = {
            item["sha256"] for item in provenance["evidence_manifests"]}
        verdict_controls = [sample for sample in samples if sample.role == "control"]
        if (pilot_run_ids & {sample.manifest["run"]["id"] for sample in verdict_controls}
                or pilot_manifest_hashes & {
                    sample.manifest_sha256 for sample in verdict_controls}):
            raise IdleCompareError(
                "threshold pilot evidence overlaps verdict control evidence")
        if provenance["commit"] != runner["commits"]["control"]:
            raise IdleCompareError("threshold control commit does not match the verdict control")

    by_key = {(sample.kind, sample.index, sample.role): sample for sample in samples}
    if len(by_key) != len(samples):
        raise IdleCompareError("successful manifests contain a duplicate role/kind/index")
    run_ids = [sample.manifest["run"]["id"] for sample in samples]
    manifest_hashes = [sample.manifest_sha256 for sample in samples]
    if len(set(run_ids)) != len(run_ids) or len(set(manifest_hashes)) != len(manifest_hashes):
        raise IdleCompareError("successful evidence identities must be globally unique")
    for role in ("control", "candidate"):
        role_samples = [sample for sample in samples if sample.role == role]
        if role_samples:
            if len({_canonical_sha256(_environment(sample)) for sample in role_samples}) != 1:
                raise IdleCompareError(f"{role} environment differs across samples")
            if len({sample.manifest["product"]["commit"] for sample in role_samples}) != 1:
                raise IdleCompareError(f"{role} commit differs across samples")
            if len({sample.manifest["product"]["sha256"] for sample in role_samples}) != 1:
                raise IdleCompareError(f"{role} product checksum differs across samples")
    if samples and len({_canonical_sha256(_environment(sample)) for sample in samples}) != 1:
        raise IdleCompareError("control and candidate environments differ")
    if thresholds is not None and "control_provenance" in thresholds:
        verdict_control_hashes = {
            sample.manifest["product"]["sha256"]
            for sample in samples if sample.role == "control"}
        if verdict_control_hashes != {thresholds["control_provenance"]["product_sha256"]}:
            raise IdleCompareError(
                "threshold control product checksum does not match the verdict control")
    mutable = {(sample.manifest["device"]["power_source"],
                sample.manifest["device"]["battery_state"],
                sample.manifest["device"]["thermal_state"]) for sample in samples}
    if len(mutable) > 1:
        raise IdleCompareError("power, battery, and thermal state must remain stable for the idle run")
    if mutable:
        power, battery, thermal = next(iter(mutable))
        if (power != "external" or battery not in {"charging", "full", "not_applicable"}
                or thermal not in {"nominal", "fair"}):
            raise IdleCompareError(
                "idle comparison requires external power, stable battery, and nominal/fair thermal state")

    declared_schedule = _expected_schedule(runner["seed"], runner["warmups"], runner["measured"])
    successful_in_schedule = [by_key.get((raw["sample_kind"], raw["sample_index"], raw["role"]))
                              for raw in declared_schedule]
    dated = [sample for sample in successful_in_schedule if sample is not None]
    if any(left.recorded_at >= right.recorded_at for left, right in zip(dated, dated[1:])):
        raise IdleCompareError("successful idle samples do not follow strict schedule chronology")

    rows: list[dict[str, Any]] = []
    pair_covariates: dict[tuple[str, int], dict[str, Any]] = {}
    schedule_offsets = {"warmup": 0, "measured": runner["warmups"] * 2}
    for kind, count in (("warmup", runner["warmups"]), ("measured", runner["measured"])):
        for index in range(count):
            control = by_key.get((kind, index, "control"))
            candidate = by_key.get((kind, index, "candidate"))
            if control is None or candidate is None:
                continue
            ordered = sorted((control, candidate), key=lambda sample: sample.recorded_at)
            expected_first = declared_schedule[schedule_offsets[kind] + index * 2]["role"]
            if ordered[0].role != expected_first:
                raise IdleCompareError(f"{kind} pair {index} does not match seeded arm order")
            gap = (ordered[1].recorded_at - ordered[0].recorded_at).total_seconds()
            if gap > max_pair_start_gap:
                raise IdleCompareError(f"{kind} pair {index} exceeds pair start-gap tolerance")
            cdev, ndev = control.manifest["device"], candidate.manifest["device"]
            storage = abs(cdev["free_storage_bytes"] - ndev["free_storage_bytes"])
            if storage > max_storage_drift:
                raise IdleCompareError(f"{kind} pair {index} exceeds free-storage drift tolerance")
            expected_ns = runner["duration_seconds"] * 1_000_000_000
            if (control.summary["capture"]["expected_duration_ns"] != expected_ns
                    or candidate.summary["capture"]["expected_duration_ns"] != expected_ns):
                raise IdleCompareError(f"{kind} pair {index} expected duration differs from the runner")
            window_drift = abs(control.actual_duration_ns - candidate.actual_duration_ns)
            if window_drift > max_window_drift_ns:
                raise IdleCompareError(f"{kind} pair {index} exceeds actual-window drift tolerance")
            pair_covariates[(kind, index)] = {
                "first_role": ordered[0].role, "pair_start_gap_seconds": gap,
                "free_storage_drift_bytes": storage, "actual_window_drift_ns": window_drift,
                "power_source": cdev["power_source"], "battery_state": cdev["battery_state"],
                "thermal_state": cdev["thermal_state"],
            }
            if kind == "measured":
                raw_control, raw_candidate = control.summary["metrics"], candidate.summary["metrics"]
                metric_rows: dict[str, Any] = {}
                for metric in METRICS:
                    left, right = control.rates[metric], candidate.rates[metric]
                    metric_rows[metric] = {
                        "control": left, "candidate": right, "delta": right - left,
                        "delta_percent": None if left == 0 else 100.0 * (right - left) / left,
                    }
                rows.append({
                    "sample_index": index, "control_run_id": control.manifest["run"]["id"],
                    "candidate_run_id": candidate.manifest["run"]["id"],
                    "control_recorded_at": control.manifest["run"]["recorded_at"],
                    "candidate_recorded_at": candidate.manifest["run"]["recorded_at"],
                    "covariates": pair_covariates[(kind, index)],
                    "control_actual_duration_ns": control.actual_duration_ns,
                    "candidate_actual_duration_ns": candidate.actual_duration_ns,
                    "raw": {"control": raw_control, "candidate": raw_candidate},
                    "rates": metric_rows,
                })

    failure_records = [record for record in records if record["status"] == "failure"]
    failures = [{"sample_kind": record["sample_kind"], "sample_index": record["sample_index"],
                 "pair_order": record["pair_order"], "role": record["role"],
                 "type": _validated_failure(record["failure"])["type"]}
                for record in failure_records]
    warmup_failures = [record for record in failure_records if record["sample_kind"] == "warmup"]
    measured_failures = {role: sum(record["sample_kind"] == "measured" and record["role"] == role
                                   for record in failure_records) for role in ("control", "candidate")}
    measured_failure_modes = {
        role: sorted({_validated_failure(record["failure"])["type"] for record in failure_records
                      if record["sample_kind"] == "measured" and record["role"] == role})
        for role in ("control", "candidate")
    }
    new_candidate_failure_modes = sorted(set(measured_failure_modes["candidate"])
                                         - set(measured_failure_modes["control"]))
    reasons: list[str] = []
    exact_long_policy = runner["warmups"] == 1 and runner["measured"] == 5
    if not exact_long_policy:
        reasons.append("requires the exact long policy of one warmup and five measured pairs")
    if thresholds is None:
        reasons.append("no admissible preregistered idle threshold artifact was supplied")
    if warmup_failures:
        reasons.append("a warmup arm failed")
    if failure_records:
        reasons.append("one or more capture arms failed")
    if len(rows) != 5:
        reasons.append("requires five complete measured pairs")

    metric_results: dict[str, Any] = {}
    for metric in METRICS:
        deltas = [row["rates"][metric]["delta"] for row in rows]
        controls = [row["rates"][metric]["control"] for row in rows]
        candidates = [row["rates"][metric]["candidate"] for row in rows]
        result: dict[str, Any] = {
            "unit": "ns/s" if metric.startswith("cpu_") else "wakeups/min",
            "control_median": statistics.median(controls) if controls else None,
            "candidate_median": statistics.median(candidates) if candidates else None,
            "paired_median_delta": statistics.median(deltas) if deltas else None,
            "paired_median_delta_ci": (list(_bootstrap(deltas, _metric_seed(
                runner["identities"]["order_seed"], metric))) if len(deltas) == 5 else None),
            "absolute_mde": None, "relative_mde_percent": None,
            "effective_mde": None, "outcome": "insufficient_data",
        }
        if (exact_long_policy and thresholds is not None and len(deltas) == 5
                and not warmup_failures and not failure_records):
            threshold = thresholds["metrics"][metric]
            baseline = statistics.median(controls)
            effective = max(float(threshold["absolute_mde"]),
                            baseline * float(threshold["relative_mde_percent"]) / 100.0)
            low, high = result["paired_median_delta_ci"]
            result.update(absolute_mde=float(threshold["absolute_mde"]),
                          relative_mde_percent=float(threshold["relative_mde_percent"]),
                          effective_mde=effective)
            if low >= effective:
                result["outcome"] = "regression"
            elif high <= -effective:
                result["outcome"] = "improvement"
            else:
                result["outcome"] = "noise"
        metric_results[metric] = result

    failure_regression = (measured_failures["candidate"] > measured_failures["control"]
                          or bool(new_candidate_failure_modes))
    if not exact_long_policy or thresholds is None or warmup_failures:
        outcome = "insufficient_data"
    elif failure_regression:
        outcome = "regression"
    elif failure_records or len(rows) != 5:
        outcome = "insufficient_data"
    elif any(result["outcome"] == "regression" for result in metric_results.values()):
        outcome = "regression"
    elif any(result["outcome"] == "improvement" for result in metric_results.values()):
        outcome = "improvement"
    else:
        outcome = "noise"

    def role_summary(role: str) -> dict[str, Any]:
        role_samples = [sample for sample in samples if sample.role == role]
        return {
            "commit": runner["commits"][role],
            "product_sha256": (role_samples[0].manifest["product"]["sha256"] if role_samples else None),
            "warmups": sum(sample.kind == "warmup" for sample in role_samples),
            "measured": sum(sample.kind == "measured" for sample in role_samples),
            "failures": sum(record["status"] == "failure" and record["role"] == role
                            for record in records),
            "measured_failure_modes": measured_failure_modes[role],
            **({"new_measured_failure_modes": new_candidate_failure_modes}
               if role == "candidate" else {}),
            "evidence_manifests": [{"run_id": sample.manifest["run"]["id"],
                                    "sample_kind": sample.kind, "sample_index": sample.index,
                                    "sha256": sample.manifest_sha256}
                                   for sample in sorted(role_samples, key=lambda item: (item.kind, item.index))],
        }

    return {
        "schema_version": 1, "tool": TOOL,
        "input": {"kind": "paired_idle_runner_result", "sha256": runner_sha256},
        "comparison_id": runner["identities"]["comparison_id"], "sample_policy": "long",
        "declared_capture": {"warmups": runner["warmups"], "measured": runner["measured"]},
        "duration_seconds": runner["duration_seconds"],
        "environment_sha256": (_canonical_sha256(_environment(samples[0])) if samples else None),
        "protocol": {"thresholds_preregistered_before_candidate": "operator_attested",
                     "limitation": (
                         "threshold timing remains operator attested because the threshold "
                         "checksum is not bound in verdict manifests; a derived pilot may "
                         "contain ignored candidate observations")},
        "threshold_artifact": (None if thresholds is None else {
            "kind": "preregistered_idle_thresholds", "sha256": threshold_sha256,
            "rationale": thresholds["rationale"],
            "control_provenance": thresholds.get("control_provenance")}),
        "tolerances": {"max_free_storage_drift_bytes": max_storage_drift,
                       "max_pair_start_gap_seconds": max_pair_start_gap,
                       "max_actual_window_drift_ns": max_window_drift_ns},
        "control": role_summary("control"), "candidate": role_summary("candidate"),
        "capture_failures": failures, "metrics": metric_results, "pairs": rows,
        "outcome": outcome, "reasons": reasons,
        "statistics_contract": {"bootstrap_resamples": BOOTSTRAP_RESAMPLES,
                                "confidence_level": CONFIDENCE_LEVEL,
                                "statistic": "median_of_paired_rate_deltas"},
    }


def _csv_bytes(result: dict[str, Any]) -> bytes:
    columns = ["sample_index", "control_run_id", "candidate_run_id", "first_role",
               "pair_start_gap_seconds", "free_storage_drift_bytes", "actual_window_drift_ns",
               "power_source", "battery_state", "thermal_state", "control_actual_duration_ns",
               "candidate_actual_duration_ns", "control_cpu_running_ns", "candidate_cpu_running_ns",
               "control_wakeups_count", "candidate_wakeups_count", "control_cpu_ns_per_second",
               "candidate_cpu_ns_per_second", "cpu_delta", "cpu_delta_percent",
               "control_wakeups_per_minute", "candidate_wakeups_per_minute", "wakeups_delta",
               "wakeups_delta_percent"]
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=columns)
    writer.writeheader()
    for pair in result["pairs"]:
        cpu = pair["rates"]["cpu_running_ns_per_second"]
        wakeups = pair["rates"]["wakeups_per_minute"]
        row = {"sample_index": pair["sample_index"], "control_run_id": pair["control_run_id"],
               "candidate_run_id": pair["candidate_run_id"], **pair["covariates"],
               "control_actual_duration_ns": pair["control_actual_duration_ns"],
               "candidate_actual_duration_ns": pair["candidate_actual_duration_ns"],
               "control_cpu_running_ns": pair["raw"]["control"]["cpu_running_ns"],
               "candidate_cpu_running_ns": pair["raw"]["candidate"]["cpu_running_ns"],
               "control_wakeups_count": pair["raw"]["control"]["wakeups_count"],
               "candidate_wakeups_count": pair["raw"]["candidate"]["wakeups_count"],
               "control_cpu_ns_per_second": cpu["control"], "candidate_cpu_ns_per_second": cpu["candidate"],
               "cpu_delta": cpu["delta"], "cpu_delta_percent": cpu["delta_percent"],
               "control_wakeups_per_minute": wakeups["control"],
               "candidate_wakeups_per_minute": wakeups["candidate"],
               "wakeups_delta": wakeups["delta"], "wakeups_delta_percent": wakeups["delta_percent"]}
        writer.writerow({key: row.get(key) for key in columns})
    return output.getvalue().encode()


def _protected_paths(runner_path: pathlib.Path, threshold_path: pathlib.Path | None,
                     samples: list[IdleSample]) -> set[pathlib.Path]:
    paths = {runner_path.resolve()}
    if threshold_path is not None:
        paths.add(threshold_path.resolve())
    for sample in samples:
        paths.add(sample.manifest_path.resolve())
        run_dir = sample.manifest_path.parent
        paths.add(run_dir.resolve())
        paths.add((run_dir / sample.manifest["evidence"]["redacted_summary"]["path"]).resolve())
        paths.update((run_dir / pointer["path"]).resolve()
                     for pointer in sample.manifest["evidence"]["artifacts"])
    return paths


def _publish(outputs: list[tuple[pathlib.Path, bytes]], protected: set[pathlib.Path],
             *, exclusive: bool = False) -> None:
    resolved: list[pathlib.Path] = []
    for path, _ in outputs:
        absolute = path.resolve()
        if (absolute in protected or absolute in resolved
                or any(item.is_dir() and item in absolute.parents for item in protected)):
            raise IdleCompareError("output path collides with input evidence")
        if path.exists() or path.is_symlink():
            raise IdleCompareError("output path must not already exist")
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.parent.is_symlink() or path.parent.resolve() != path.parent.absolute():
            raise IdleCompareError("output parent must be a canonical non-symlink directory")
        resolved.append(absolute)
    staged: list[tuple[pathlib.Path, pathlib.Path]] = []
    published: list[pathlib.Path] = []
    try:
        for path, data in outputs:
            descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
            temporary = pathlib.Path(name)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            staged.append((temporary, path))
        for temporary, path in staged:
            if exclusive:
                # A same-directory hard link publishes fully durable staged bytes
                # atomically and fails rather than replacing a concurrently created path.
                os.link(temporary, path)
                temporary.unlink()
            else:
                os.replace(temporary, path)
            published.append(path)
        for parent in {path.parent for _, path in staged}:
            descriptor = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    except OSError:
        for path in reversed(published):
            path.unlink(missing_ok=True)
        raise
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    raw = list(sys.argv[1:] if argv is None else argv)
    if raw and raw[0] == "freeze":
        parser = argparse.ArgumentParser(
            description="Freeze idle thresholds from a completed control-only pilot")
        parser.set_defaults(command="freeze")
        parser.add_argument("freeze", nargs="?")
        parser.add_argument("--runner-result", required=True, type=pathlib.Path)
        parser.add_argument("--thresholds-out", required=True, type=pathlib.Path)
        parser.add_argument(
            "--rationale", default="Control only pilot derived engineering guardrail")
        return parser.parse_args(raw)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.set_defaults(command="compare")
    parser.add_argument("--runner-result", required=True, type=pathlib.Path)
    parser.add_argument("--thresholds", type=pathlib.Path)
    parser.add_argument("--thresholds-sha256")
    parser.add_argument("--max-free-storage-drift-bytes", required=True, type=int)
    parser.add_argument("--max-pair-start-gap-seconds", required=True, type=float)
    parser.add_argument("--max-actual-window-drift-ms", required=True, type=float)
    parser.add_argument("--json-out", type=pathlib.Path)
    parser.add_argument("--csv-out", type=pathlib.Path)
    return parser.parse_args(raw)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "freeze":
            runner, records, samples, runner_sha256 = load_runner(args.runner_result)
            artifact = freeze_thresholds(
                runner, records, samples, runner_sha256=runner_sha256,
                rationale=args.rationale)
            payload = (json.dumps(artifact, indent=2, sort_keys=True) + "\n").encode()
            _publish([(args.thresholds_out, payload)],
                     _protected_paths(args.runner_result, None, samples), exclusive=True)
            digest = hashlib.sha256(payload).hexdigest()
            if load_thresholds(
                    args.thresholds_out, digest,
                    duration_seconds=runner["duration_seconds"]) != artifact:
                raise IdleCompareError("published idle thresholds failed exact reload validation")
            print(f"idle thresholds frozen: {args.thresholds_out} sha256={digest}")
            return 0
        if (args.thresholds is None) != (args.thresholds_sha256 is None):
            raise IdleCompareError("--thresholds and --thresholds-sha256 must be supplied together")
        if args.json_out is None and args.csv_out is None:
            raise IdleCompareError("at least one output path is required")
        window_ms = _finite(args.max_actual_window_drift_ms, "actual-window drift tolerance")
        window_ns = round(window_ms * 1_000_000)
        runner, records, samples, runner_sha256 = load_runner(args.runner_result)
        thresholds = (load_thresholds(args.thresholds, args.thresholds_sha256,
                                      duration_seconds=runner["duration_seconds"])
                      if args.thresholds is not None else None)
        result = compare(args.runner_result, runner, records, samples,
                         runner_sha256=runner_sha256, thresholds=thresholds,
                         threshold_path=args.thresholds, threshold_sha256=args.thresholds_sha256,
                         max_storage_drift=args.max_free_storage_drift_bytes,
                         max_pair_start_gap=args.max_pair_start_gap_seconds,
                         max_window_drift_ns=window_ns)
        outputs: list[tuple[pathlib.Path, bytes]] = []
        if args.json_out is not None:
            outputs.append((args.json_out, (json.dumps(result, indent=2, sort_keys=True) + "\n").encode()))
        if args.csv_out is not None:
            outputs.append((args.csv_out, _csv_bytes(result)))
        _publish(outputs, _protected_paths(args.runner_result, args.thresholds, samples))
    except (IdleCompareError, OSError) as error:
        print(f"idle comparison failed: {error}", file=sys.stderr)
        return 1
    return 2 if result["outcome"] == "regression" else 3 if result["outcome"] == "insufficient_data" else 0


if __name__ == "__main__":
    raise SystemExit(main())
