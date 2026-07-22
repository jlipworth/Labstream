#!/usr/bin/env python3
"""Freeze and compare Labstream PerformanceAudit latency evidence.

First freeze the MDE from control-only evidence collected before the candidate:

  scripts/perf-compare.py freeze --control-manifest runs/control-*/*.json \
    --phase home.load --backend Plex --correctness-field hub_count \
    --correctness-field item_count --sample-policy short \
    --out frozen-mde.json

Then compare separately collected, seeded alternating control/candidate pairs:

  scripts/perf-compare.py compare --control-manifest runs/pairs/control-*/*.json \
    --candidate-manifest runs/pairs/candidate-*/*.json --phase home.load \
    --backend Plex --correctness-field hub_count --correctness-field item_count \
    --sample-policy short \
    --frozen-mde frozen-mde.json --frozen-mde-sha256 <printed checksum> \
    --max-free-storage-drift-bytes 1073741824 --max-pair-gap-seconds 120 \
    --json-out result.json --csv-out pairs.csv

Protocol limitation: the current run-manifest schema does not carry a frozen-MDE
checksum. Operators must freeze and record the printed checksum before candidate
capture; results report this as operator-attested rather than cryptographically
manifest-bound temporal ordering.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import math
import pathlib
import random
import re
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Iterable

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
import perf_evidence_schema as evidence_schema

CONTRACT_SCRIPT = SCRIPT_DIR / "performance-audit-contract.py"
_spec = importlib.util.spec_from_file_location("labstream_performance_audit_contract", CONTRACT_SCRIPT)
assert _spec and _spec.loader
contract = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = contract
_spec.loader.exec_module(contract)

TOOL_NAME = "labstream-perf-compare"
TOOL_VERSION = "2"
BOOTSTRAP_RESAMPLES = 10_000
CONFIDENCE_LEVEL = 0.95
SAFE_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
WORKLOAD_ID_RE = re.compile(r"^workload-[a-f0-9]{12}$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
BACKEND_LABELS = evidence_schema.BACKEND_LABELS


class CompareError(ValueError):
    pass


@dataclass(frozen=True)
class Span:
    phase: str
    backend: str
    result: str
    duration_ms: int
    fields: dict[str, str]


@dataclass(frozen=True)
class Sample:
    path: pathlib.Path
    manifest: dict[str, Any]
    workload: dict[str, Any]
    spans: tuple[Span, ...]
    capture_binding: dict[str, str]

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
        return _parse_datetime(self.manifest["run"]["recorded_at"])


@dataclass(frozen=True)
class SampleValue:
    sample: Sample
    duration_ms: float | None
    failure_modes: tuple[str, ...]


def _parse_datetime(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as error:
        raise CompareError("recorded_at must be a parseable UTC datetime") from error
    if parsed.utcoffset() is None or parsed.utcoffset().total_seconds() != 0:
        raise CompareError("recorded_at must use UTC")
    return parsed


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _exact(value: Any, fields: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CompareError(f"{label} must be an object")
    if set(value) != fields:
        raise CompareError(f"{label} has non-closed fields")
    return value


def _expected_binding(manifest: dict[str, Any]) -> dict[str, Any]:
    run, scenario = manifest["run"], manifest["scenario"]
    return {
        "run_id": run["id"], "comparison_id": run["comparison_id"],
        "artifact_role": run["artifact_role"], "sample_kind": run["sample_kind"],
        "sample_index": run["sample_index"], "scenario_id": scenario["id"],
        "backend_kind": scenario["backend_kind"],
    }


def _load_summary(path: pathlib.Path, manifest: dict[str, Any]) -> tuple[dict[str, Any], tuple[Span, ...], dict[str, str]]:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CompareError("redacted summary is not readable versioned JSON") from error
    document = _exact(document, {
        "schema_version", "tool", "binding", "capture_binding", "source_artifact",
        "workload", "spans", "rows", "diagnostics",
    }, "redacted summary")
    if document["schema_version"] != 1 or document["tool"] != {
        "name": "labstream-perf-log-summary", "version": "2",
    }:
        raise CompareError("redacted summary schema/tool is unsupported")
    binding = _exact(document["binding"], {
        "run_id", "comparison_id", "artifact_role", "sample_kind", "sample_index",
        "scenario_id", "backend_kind",
    }, "redacted summary binding")
    if binding != _expected_binding(manifest):
        raise CompareError("redacted summary binding does not match its manifest run/scenario/backend")
    workload = _exact(document["workload"], {
        "id", "phase", "backend", "fields", "correctness_fields",
        "expected_span_count", "aggregation",
    }, "redacted summary workload")
    if not isinstance(workload["id"], str) or WORKLOAD_ID_RE.fullmatch(workload["id"]) is None:
        raise CompareError("workload id must be opaque")
    if workload["aggregation"] != "median":
        raise CompareError("only the explicit median workload aggregation is supported")
    if (not isinstance(workload["expected_span_count"], int)
            or isinstance(workload["expected_span_count"], bool)
            or workload["expected_span_count"] <= 0):
        raise CompareError("workload expected_span_count must be positive")
    try:
        workload["fields"] = evidence_schema.validate_selector_fields(workload["phase"], workload["fields"])
        correctness_fields = evidence_schema.validate_correctness_fields(
            workload["phase"], workload["backend"], workload["correctness_fields"]
        )
    except (KeyError, TypeError, ValueError) as error:
        raise CompareError(f"workload semantic schema is invalid: {error}") from error
    if BACKEND_LABELS.get(binding["backend_kind"]) != workload["backend"]:
        raise CompareError("redacted summary workload backend does not match the manifest scenario backend")
    diagnostics = _exact(document["diagnostics"], {"rejected_span_count", "rejection_reasons"},
                         "redacted summary diagnostics")
    if diagnostics != {"rejected_span_count": 0, "rejection_reasons": {}}:
        raise CompareError("redacted summary contains rejected span records")
    if not isinstance(document["spans"], list):
        raise CompareError("redacted summary spans must be an array")
    if len(document["spans"]) != workload["expected_span_count"]:
        raise CompareError("redacted summary span cardinality does not match its workload")
    spans: list[Span] = []
    for index, raw in enumerate(document["spans"]):
        raw = _exact(raw, {"phase", "backend", "result", "duration_ms", "fields"}, f"span[{index}]")
        if raw["phase"] != workload["phase"] or raw["backend"] != workload["backend"]:
            raise CompareError("redacted summary contains a foreign phase/backend span")
        if raw["result"] not in evidence_schema.KNOWN_RESULTS:
            raise CompareError(f"span[{index}] has an unknown result")
        if (type(raw["duration_ms"]) is not int
                or not 0 <= raw["duration_ms"] <= evidence_schema.MAX_DURATION_MS):
            raise CompareError(f"span[{index}] duration must be a bounded nonnegative integer")
        try:
            raw["fields"] = evidence_schema.canonicalize_fields(raw["phase"], raw["fields"], raw=False)
        except (TypeError, ValueError) as error:
            raise CompareError(f"span[{index}] fields violate the shared semantic schema: {error}") from error
        if not all(raw["fields"].get(key) == value for key, value in workload["fields"].items()):
            raise CompareError("redacted summary contains a span outside its workload selector")
        if raw["result"] == "success" and any(field not in raw["fields"] for field in correctness_fields):
            raise CompareError("successful span is missing a declared correctness field")
        spans.append(Span(raw["phase"], raw["backend"], raw["result"], raw["duration_ms"], raw["fields"]))
    durations = [span.duration_ms for span in spans]
    expected_rows = [{
        "phase": workload["phase"], "backend": workload["backend"], "count": len(spans),
        "failures": sum(span.result != "success" for span in spans),
        "min_ms": min(durations), "p50_ms": _integer_percentile(durations, .50),
        "p95_ms": _integer_percentile(durations, .95), "max_ms": max(durations),
    }]
    if document["rows"] != expected_rows:
        raise CompareError("redacted summary rows do not exactly match the bound spans")

    source = _exact(document["source_artifact"], {"path", "sha256"}, "redacted summary source artifact")
    if source not in manifest["evidence"]["artifacts"]:
        raise CompareError("redacted summary source is not an exact manifest raw-artifact pointer")
    raw_path = path.parent.parent / source["path"]
    capture = _exact(document["capture_binding"], {"run_id", "workload_id", "launch_nonce", "binding_kind"},
                     "redacted summary capture binding")
    if (capture["run_id"] != binding["run_id"] or capture["workload_id"] != workload["id"]
            or not isinstance(capture["launch_nonce"], str)
            or evidence_schema.NONCE_RE.fullmatch(capture["launch_nonce"]) is None
            or capture["binding_kind"] != "declared_capture"):
        raise CompareError("redacted summary capture binding does not match its run/workload")
    raw_spans: list[evidence_schema.SpanRecord] = []
    raw_capture: list[dict[str, str]] = []
    rejected: dict[str, int] = {}
    try:
        raw_lines = raw_path.read_text().splitlines()
    except OSError as error:
        raise CompareError("bound raw artifact is unreadable") from error
    for line in raw_lines:
        parsed_span, span_reason = evidence_schema.parse_span_line_diagnostic(line)
        parsed_capture, capture_reason = evidence_schema.parse_capture_line_diagnostic(line)
        if parsed_span is not None:
            raw_spans.append(parsed_span)
        elif span_reason is not None:
            rejected[span_reason] = rejected.get(span_reason, 0) + 1
        if parsed_capture is not None:
            raw_capture.append(parsed_capture)
        elif capture_reason is not None:
            rejected[capture_reason] = rejected.get(capture_reason, 0) + 1
    raw_capture_expected = {key: capture[key] for key in ("run_id", "workload_id", "launch_nonce")}
    if rejected or raw_capture != [raw_capture_expected]:
        raise CompareError("bound raw artifact has malformed or mismatched capture evidence")
    selected = [record for record in raw_spans
                if record.phase == workload["phase"] and record.backend == workload["backend"]
                and all(record.fields.get(key) == value for key, value in workload["fields"].items())]
    expected_spans = tuple(Span(record.phase, record.backend, record.result,
                                record.duration_ms, record.fields) for record in selected)
    if tuple(spans) != expected_spans:
        raise CompareError("redacted summary spans are not an exact derivation of the bound raw artifact")
    return workload, tuple(spans), capture


def _integer_percentile(values: list[int], probability: float) -> int:
    ordered = sorted(values)
    rank = (len(ordered) - 1) * probability
    low, high = math.floor(rank), math.ceil(rank)
    if low == high:
        return ordered[low]
    return round(ordered[low] + (ordered[high] - ordered[low]) * (rank - low))


def load_sample(path: pathlib.Path, expected_role: str) -> Sample:
    path = path.resolve()
    try:
        manifest = contract.read_manifest(path)
        contract.validate_manifest(manifest, path.parent)
    except contract.ContractError as error:
        raise CompareError(f"manifest contract failed for {path.name}: {error}") from error
    if manifest["run"]["artifact_role"] != expected_role:
        raise CompareError(f"{path.name} has the wrong artifact role")
    if manifest["evidence"]["privacy_review"] == "rejected":
        raise CompareError(f"{path.name} evidence privacy review is rejected")
    summary_path = path.parent / manifest["evidence"]["redacted_summary"]["path"]
    workload, spans, capture_binding = _load_summary(summary_path, manifest)
    return Sample(path, manifest, workload, spans, capture_binding)


def _uniform(samples: list[Sample], getter, label: str) -> Any:
    if not samples:
        raise CompareError(f"{label} has no samples")
    first = getter(samples[0])
    if any(getter(sample) != first for sample in samples[1:]):
        raise CompareError(f"{label} differs within one artifact role")
    return first


def _environment_fingerprint(sample: Sample) -> dict[str, Any]:
    manifest, product, device = sample.manifest, sample.manifest["product"], sample.manifest["device"]
    return {
        "tool": manifest["tool"],
        "product": {key: product[key] for key in (
            "configuration", "target", "platform", "os_build", "xcode_build",
        )},
        "device": {"label": device["label"], "display_mode": device["display_mode"]},
        "state": manifest["state"], "scenario": manifest["scenario"],
        "automation": manifest.get("automation"),
        "launch_contract": manifest["launch_contract"],
    }


def _validate_role(samples: list[Sample], role: str) -> None:
    if not samples:
        raise CompareError(f"{role} manifests are required")
    _uniform(samples, _environment_fingerprint, f"{role} environment metadata")
    _uniform(samples, lambda sample: sample.manifest["product"]["commit"], f"{role} commit")
    _uniform(samples, lambda sample: sample.manifest["product"]["sha256"], f"{role} checksum")
    _uniform(samples, lambda sample: sample.workload, f"{role} workload")
    seen: set[tuple[str, int]] = set()
    run_ids: set[str] = set()
    launch_nonces: set[str] = set()
    for sample in samples:
        key = (sample.kind, sample.index)
        if key in seen:
            raise CompareError(f"duplicate {role} {sample.kind} sample_index {sample.index}")
        seen.add(key)
        run_id = sample.manifest["run"]["id"]
        if run_id in run_ids:
            raise CompareError(f"duplicate {role} run id")
        run_ids.add(run_id)
        nonce = sample.capture_binding["launch_nonce"]
        if nonce in launch_nonces:
            raise CompareError(f"duplicate {role} capture launch nonce")
        launch_nonces.add(nonce)


def _correctness_signature(sample: Sample) -> tuple[tuple[tuple[str, str], ...], ...] | None:
    if any(span.result != "success" for span in sample.spans):
        return None
    fields = sample.workload["correctness_fields"]
    return tuple(sorted(tuple((field, span.fields[field]) for field in fields) for span in sample.spans))


def _expected_first_role(order_seed: str, kind: str, index: int) -> str:
    digest = hashlib.sha256(f"{order_seed}:{kind}:{index}".encode()).digest()
    return "control" if digest[0] & 1 == 0 else "candidate"


def _validate_index_sequence(samples: list[Sample], kind: str, label: str) -> None:
    indexes = sorted(sample.index for sample in samples if sample.kind == kind)
    if indexes != list(range(len(indexes))):
        raise CompareError(f"{label} {kind} sample indexes must be consecutive from zero")


def _validate_control_collection_order(samples: list[Sample]) -> None:
    for kind in ("warmup", "measured"):
        _validate_index_sequence(samples, kind, "control freeze")
    ordered = sorted(samples, key=lambda sample: sample.recorded_at)
    if len({sample.recorded_at for sample in ordered}) != len(ordered):
        raise CompareError("control freeze recorded_at values must be unique")
    seen_measured = False
    for sample in ordered:
        if sample.kind == "measured":
            seen_measured = True
        elif seen_measured:
            raise CompareError("all control warmups must precede measured runs")


def _validate_pairing(control: list[Sample], candidate: list[Sample],
                      max_storage_drift: int, max_pair_gap_seconds: float) -> dict[tuple[str, int], dict[str, Any]]:
    _validate_role(control, "control")
    _validate_role(candidate, "candidate")
    if _environment_fingerprint(control[0]) != _environment_fingerprint(candidate[0]):
        raise CompareError("control/candidate machine, toolchain, configuration, scenario, or cache metadata differ")
    if control[0].workload != candidate[0].workload:
        raise CompareError("control/candidate workloads differ")
    control_run_ids = {sample.manifest["run"]["id"] for sample in control}
    candidate_run_ids = {sample.manifest["run"]["id"] for sample in candidate}
    if control_run_ids & candidate_run_ids:
        raise CompareError("control/candidate run ids must be globally unique")
    if ({sample.capture_binding["launch_nonce"] for sample in control}
            & {sample.capture_binding["launch_nonce"] for sample in candidate}):
        raise CompareError("control/candidate capture launch nonces must be globally unique")
    comparison_id = _uniform(control + candidate,
                             lambda sample: sample.manifest["run"]["comparison_id"], "comparison id")
    order_seed = _uniform(control + candidate,
                         lambda sample: sample.manifest["run"]["order_seed"], "order seed")
    del comparison_id
    if not isinstance(order_seed, str) or re.fullmatch(r"seed-[a-f0-9]{16}", order_seed) is None:
        raise CompareError("order seed is invalid")
    covariates: dict[tuple[str, int], dict[str, Any]] = {}
    for kind in ("warmup", "measured"):
        control_kind = {sample.index: sample for sample in control if sample.kind == kind}
        candidate_kind = {sample.index: sample for sample in candidate if sample.kind == kind}
        if set(control_kind) != set(candidate_kind):
            continue  # comparison emits explicit insufficient data for incomplete pairs
        _validate_index_sequence(list(control_kind.values()), kind, "control")
        _validate_index_sequence(list(candidate_kind.values()), kind, "candidate")
        ordered = sorted([*control_kind.values(), *candidate_kind.values()], key=lambda sample: sample.recorded_at)
        if len({sample.recorded_at for sample in ordered}) != len(ordered):
            raise CompareError(f"{kind} recorded_at values must be unique")
        for offset in range(0, len(ordered), 2):
            block = ordered[offset:offset + 2]
            if len(block) != 2 or block[0].index != block[1].index or {sample.role for sample in block} != {
                "control", "candidate",
            }:
                raise CompareError(f"{kind} runs must form exact same-index chronological blocks")
            expected = _expected_first_role(order_seed, kind, block[0].index)
            if block[0].role != expected:
                raise CompareError(f"{kind} block order does not match order_seed")
            pair_gap = (block[1].recorded_at - block[0].recorded_at).total_seconds()
            if pair_gap > max_pair_gap_seconds:
                raise CompareError(f"{kind} pair {block[0].index} exceeds the pair time-gap limit")
            left, right = control_kind[block[0].index], candidate_kind[block[0].index]
            cdev, ndev = left.manifest["device"], right.manifest["device"]
            for key in ("power_source", "battery_state", "thermal_state"):
                if cdev[key] != ndev[key]:
                    raise CompareError(f"{kind} pair {block[0].index} has mismatched {key}")
            if cdev["thermal_state"] not in {"nominal", "fair"}:
                raise CompareError(f"{kind} pair {block[0].index} has unsupported thermal state")
            storage_drift = abs(cdev["free_storage_bytes"] - ndev["free_storage_bytes"])
            if storage_drift > max_storage_drift:
                raise CompareError(f"{kind} pair {block[0].index} exceeds free-storage drift tolerance")
            covariates[(kind, block[0].index)] = {
                "power_source": cdev["power_source"], "battery_state": cdev["battery_state"],
                "thermal_state": cdev["thermal_state"], "free_storage_drift_bytes": storage_drift,
                "pair_gap_seconds": pair_gap,
            }
            left_signature, right_signature = _correctness_signature(left), _correctness_signature(right)
            if left_signature is not None and right_signature is not None and left_signature != right_signature:
                raise CompareError(f"{kind} pair {block[0].index} has mismatched correctness/work fields")
    all_ordered = sorted(control + candidate, key=lambda sample: sample.recorded_at)
    seen_measured = False
    for sample in all_ordered:
        if sample.kind == "measured":
            seen_measured = True
        elif seen_measured:
            raise CompareError("all warmup blocks must precede measured blocks")
    return covariates


def select_value(sample: Sample, selector: dict[str, Any]) -> SampleValue:
    if sample.workload != selector:
        raise CompareError(f"{sample.path.name} workload does not match the requested selector")
    failures = tuple(sorted({span.result for span in sample.spans if span.result != "success"}))
    successes = [span.duration_ms for span in sample.spans if span.result == "success"]
    return SampleValue(sample, statistics.median(successes) if successes and not failures else None, failures)


def _quantile(values: list[float], probability: float) -> float:
    if not values:
        raise CompareError("cannot compute an interval from no values")
    ordered = sorted(values)
    rank = (len(ordered) - 1) * probability
    low, high = math.floor(rank), math.ceil(rank)
    return ordered[low] if low == high else ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def bootstrap_interval(values: list[float], statistic, seed: int) -> tuple[float, float]:
    if not values:
        raise CompareError("cannot bootstrap no values")
    rng, count = random.Random(seed), len(values)
    estimates = [statistic([values[rng.randrange(count)] for _ in range(count)])
                 for _ in range(BOOTSTRAP_RESAMPLES)]
    alpha = (1.0 - CONFIDENCE_LEVEL) / 2.0
    return _quantile(estimates, alpha), _quantile(estimates, 1.0 - alpha)


def _seed(order_seed: str, selector: dict[str, Any]) -> int:
    digest = hashlib.sha256(f"{order_seed}:{json.dumps(selector, sort_keys=True)}".encode()).digest()
    return int.from_bytes(digest[:8], "big")


def _minimums(policy: str) -> tuple[int, int]:
    return (3, 20) if policy == "short" else (1, 5)


def freeze_control(samples: list[Sample], *, selector: dict[str, Any], sample_policy: str) -> dict[str, Any]:
    _validate_role(samples, "control")
    _validate_control_collection_order(samples)
    comparison_id = _uniform(samples, lambda sample: sample.manifest["run"]["comparison_id"],
                             "control freeze comparison id")
    order_seed = _uniform(samples, lambda sample: sample.manifest["run"]["order_seed"],
                          "control freeze order seed")
    if samples[0].workload != selector:
        raise CompareError("control workload differs from freeze selector")
    minimum_warmups, minimum_measured = _minimums(sample_policy)
    ordered_samples = sorted(samples, key=lambda sample: ({"warmup": 0, "measured": 1}[sample.kind], sample.index))
    warmups = [select_value(sample, selector) for sample in ordered_samples if sample.kind == "warmup"]
    measured = [select_value(sample, selector) for sample in ordered_samples if sample.kind == "measured"]
    if len(warmups) < minimum_warmups or len(measured) < minimum_measured:
        raise CompareError("control freeze has insufficient warmup or measured samples")
    if any(value.failure_modes for value in warmups + measured):
        raise CompareError("control freeze contains failed warmup or measured runs")
    signatures = {_correctness_signature(value.sample) for value in warmups + measured}
    if len(signatures) != 1:
        raise CompareError("control freeze correctness/work fields differ across samples")
    durations = [value.duration_ms for value in measured if value.duration_ms is not None]
    if len(durations) != len(measured) or statistics.median(durations) <= 0:
        raise CompareError("control freeze requires positive successful durations")
    seed = _seed(order_seed, selector)
    interval = bootstrap_interval(durations, statistics.median, seed)
    median = statistics.median(durations)
    width_percent = 100.0 * (interval[1] - interval[0]) / median
    required_mde = max(5.0, 2.0 * width_percent)
    kind_order = {"warmup": 0, "measured": 1}
    manifests = [{
        "artifact_role": "control", "sample_kind": sample.kind,
        "sample_index": sample.index, "run_id": sample.manifest["run"]["id"],
        "launch_nonce": sample.capture_binding["launch_nonce"],
        "sha256": _sha256(sample.path),
    } for sample in sorted(samples, key=lambda item: (kind_order[item.kind], item.index))]
    return {
        "schema_version": 1,
        "tool": {"name": "labstream-perf-mde-freeze", "version": "1"},
        "control": {
            "commit": samples[0].manifest["product"]["commit"],
            "product_sha256": samples[0].manifest["product"]["sha256"],
            "environment_sha256": _canonical_sha256(_environment_fingerprint(samples[0])),
            "comparison_id": comparison_id, "order_seed": order_seed,
            "evidence_manifests": manifests,
        },
        "sample_policy": sample_policy, "workload": selector,
        "statistics": {
            "bootstrap_resamples": BOOTSTRAP_RESAMPLES, "confidence_level": CONFIDENCE_LEVEL,
            "control_measured_count": len(durations), "control_median_ms": median,
            "control_median_ci_ms": list(interval), "control_interval_width_percent": width_percent,
        },
        "frozen_mde_percent": required_mde,
    }


def load_frozen(path: pathlib.Path, expected_sha256: str) -> dict[str, Any]:
    try:
        actual_sha256 = _sha256(path)
        artifact = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CompareError("frozen MDE artifact is unreadable") from error
    if SHA256_RE.fullmatch(expected_sha256) is None or actual_sha256 != expected_sha256:
        raise CompareError("frozen MDE artifact checksum mismatch")
    artifact = _exact(artifact, {
        "schema_version", "tool", "control", "sample_policy", "workload", "statistics",
        "frozen_mde_percent",
    }, "frozen MDE artifact")
    if artifact["schema_version"] != 1 or artifact["tool"] != {
        "name": "labstream-perf-mde-freeze", "version": "1",
    }:
        raise CompareError("frozen MDE artifact schema/tool is unsupported")
    _validate_frozen_shape(artifact)
    return artifact


def _finite_number(value: Any, label: str, *, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CompareError(f"{label} must be a finite number")
    try:
        number = float(value)
    except (OverflowError, ValueError):
        raise CompareError(f"{label} must be a finite number") from None
    if not math.isfinite(number):
        raise CompareError(f"{label} must be a finite number")
    if minimum is not None and number < minimum:
        raise CompareError(f"{label} is below its minimum")
    return number


def _validate_frozen_shape(artifact: dict[str, Any]) -> None:
    control = _exact(artifact["control"], {
        "commit", "product_sha256", "environment_sha256", "comparison_id", "order_seed",
        "evidence_manifests",
    }, "frozen MDE control provenance")
    if (not isinstance(control["commit"], str) or re.fullmatch(r"[a-f0-9]{40}", control["commit"]) is None
            or not isinstance(control["product_sha256"], str) or SHA256_RE.fullmatch(control["product_sha256"]) is None
            or not isinstance(control["environment_sha256"], str) or SHA256_RE.fullmatch(control["environment_sha256"]) is None):
        raise CompareError("frozen MDE control provenance contains an invalid digest or commit")
    if (not isinstance(control["comparison_id"], str)
            or contract.COMPARISON_ID_RE.fullmatch(control["comparison_id"]) is None
            or not isinstance(control["order_seed"], str)
            or contract.ORDER_SEED_RE.fullmatch(control["order_seed"]) is None):
        raise CompareError("frozen MDE control provenance has an invalid comparison id or order seed")
    evidence = control["evidence_manifests"]
    if not isinstance(evidence, list) or not evidence:
        raise CompareError("frozen MDE control provenance requires evidence manifests")
    evidence_keys: set[tuple[str, int]] = set()
    for index, raw in enumerate(evidence):
        raw = _exact(raw, {"artifact_role", "sample_kind", "sample_index", "run_id", "launch_nonce", "sha256"},
                     f"frozen MDE evidence manifest[{index}]")
        if raw["artifact_role"] != "control":
            raise CompareError("frozen MDE evidence provenance must be control-only")
        if raw["sample_kind"] not in {"warmup", "measured"}:
            raise CompareError("frozen MDE evidence manifest has an invalid sample kind")
        if type(raw["sample_index"]) is not int or raw["sample_index"] < 0:
            raise CompareError("frozen MDE evidence manifest has an invalid sample index")
        if not isinstance(raw["sha256"], str) or SHA256_RE.fullmatch(raw["sha256"]) is None:
            raise CompareError("frozen MDE evidence manifest has an invalid checksum")
        key = (raw["sample_kind"], raw["sample_index"])
        if key in evidence_keys:
            raise CompareError("frozen MDE evidence manifests contain a duplicate sample")
        evidence_keys.add(key)
        if not isinstance(raw["launch_nonce"], str) or evidence_schema.NONCE_RE.fullmatch(raw["launch_nonce"]) is None:
            raise CompareError("frozen MDE evidence manifest has an invalid launch nonce")
    run_ids = [raw["run_id"] for raw in evidence]
    if (any(not isinstance(run_id, str) or contract.RUN_ID_RE.fullmatch(run_id) is None for run_id in run_ids)
            or len(set(run_ids)) != len(run_ids)):
        raise CompareError("frozen MDE evidence has invalid or duplicate run ids")
    if len({raw["launch_nonce"] for raw in evidence}) != len(evidence):
        raise CompareError("frozen MDE evidence has duplicate launch nonces")
    if artifact["sample_policy"] not in {"short", "long"}:
        raise CompareError("frozen MDE artifact has an invalid sample policy")
    workload = _exact(artifact["workload"], {
        "id", "phase", "backend", "fields", "correctness_fields",
        "expected_span_count", "aggregation",
    }, "frozen MDE workload")
    if (not isinstance(workload["id"], str) or WORKLOAD_ID_RE.fullmatch(workload["id"]) is None
            or type(workload["expected_span_count"]) is not int
            or workload["expected_span_count"] <= 0 or workload["aggregation"] != "median"):
        raise CompareError("frozen MDE workload is invalid")
    try:
        evidence_schema.validate_selector_fields(workload["phase"], workload["fields"])
        evidence_schema.validate_correctness_fields(
            workload["phase"], workload["backend"], workload["correctness_fields"]
        )
    except (KeyError, TypeError, ValueError) as error:
        raise CompareError(f"frozen MDE workload violates semantic schema: {error}") from error
    stats = _exact(artifact["statistics"], {
        "bootstrap_resamples", "confidence_level", "control_measured_count", "control_median_ms",
        "control_median_ci_ms", "control_interval_width_percent",
    }, "frozen MDE statistics")
    if stats["bootstrap_resamples"] != BOOTSTRAP_RESAMPLES or stats["confidence_level"] != CONFIDENCE_LEVEL:
        raise CompareError("frozen MDE artifact statistical contract mismatch")
    if type(stats["control_measured_count"]) is not int or stats["control_measured_count"] <= 0:
        raise CompareError("frozen MDE statistics have an invalid measured count")
    counts = {kind: sum(key[0] == kind for key in evidence_keys) for kind in ("warmup", "measured")}
    minimum_warmups, minimum_measured = _minimums(artifact["sample_policy"])
    for kind in ("warmup", "measured"):
        indexes = sorted(index for evidence_kind, index in evidence_keys if evidence_kind == kind)
        if indexes != list(range(len(indexes))):
            raise CompareError(f"frozen MDE {kind} evidence indexes must be consecutive from zero")
    if counts["warmup"] < minimum_warmups or counts["measured"] < minimum_measured:
        raise CompareError("frozen MDE evidence does not satisfy its sample policy")
    if stats["control_measured_count"] != counts["measured"]:
        raise CompareError("frozen MDE measured count does not match its evidence provenance")
    median = _finite_number(stats["control_median_ms"], "frozen control median", minimum=0.0)
    if median <= 0 or median > evidence_schema.MAX_DURATION_MS:
        raise CompareError("frozen control median must be positive and within the duration bound")
    interval = stats["control_median_ci_ms"]
    if not isinstance(interval, list) or len(interval) != 2:
        raise CompareError("frozen control interval must have two bounds")
    low = _finite_number(interval[0], "frozen control interval lower bound", minimum=0.0)
    high = _finite_number(interval[1], "frozen control interval upper bound", minimum=0.0)
    if low > high or high > evidence_schema.MAX_DURATION_MS:
        raise CompareError("frozen control interval bounds are reversed or out of range")
    width = _finite_number(stats["control_interval_width_percent"],
                           "frozen control interval width", minimum=0.0)
    recorded_width = 100.0 * (high - low) / median
    if not math.isclose(width, recorded_width, rel_tol=1e-12, abs_tol=1e-12):
        raise CompareError("frozen control interval width does not match its bounds")
    threshold = _finite_number(artifact["frozen_mde_percent"], "frozen MDE threshold", minimum=5.0)
    if width > 1_000_000 or threshold > 1_000_000:
        raise CompareError("frozen MDE percentage exceeds its bound")
    if threshold + 1e-12 < max(5.0, 2.0 * width):
        raise CompareError("frozen MDE artifact threshold is below its recorded control requirement")


def _validate_frozen(artifact: dict[str, Any], control: list[Sample], selector: dict[str, Any],
                     policy: str) -> float:
    _validate_frozen_shape(artifact)
    if artifact["sample_policy"] != policy or artifact["workload"] != selector:
        raise CompareError("frozen MDE artifact workload/sample policy mismatch")
    expected_control = {
        "commit": control[0].manifest["product"]["commit"],
        "product_sha256": control[0].manifest["product"]["sha256"],
        "environment_sha256": _canonical_sha256(_environment_fingerprint(control[0])),
        "order_seed": control[0].manifest["run"]["order_seed"],
    }
    for key, value in expected_control.items():
        if artifact["control"].get(key) != value:
            raise CompareError(f"frozen MDE artifact control {key} mismatch")
    frozen = float(artifact["frozen_mde_percent"])
    return frozen


def compare(control: list[Sample], candidate: list[Sample], *, selector: dict[str, Any],
            sample_policy: str, frozen_artifact: dict[str, Any],
            frozen_artifact_sha256: str, max_free_storage_drift_bytes: int,
            max_pair_gap_seconds: float) -> dict[str, Any]:
    if max_free_storage_drift_bytes < 0:
        raise CompareError("free-storage drift tolerance must be nonnegative")
    if (isinstance(max_pair_gap_seconds, bool) or not isinstance(max_pair_gap_seconds, (int, float))
            or not math.isfinite(max_pair_gap_seconds) or max_pair_gap_seconds <= 0):
        raise CompareError("pair time-gap limit must be a positive finite number")
    if not isinstance(frozen_artifact_sha256, str) or SHA256_RE.fullmatch(frozen_artifact_sha256) is None:
        raise CompareError("frozen MDE artifact checksum is invalid")
    covariates = _validate_pairing(control, candidate, max_free_storage_drift_bytes,
                                   float(max_pair_gap_seconds))
    frozen_mde = _validate_frozen(frozen_artifact, control, selector, sample_policy)
    minimum_warmups, minimum_measured = _minimums(sample_policy)

    def values(samples: list[Sample], kind: str) -> dict[int, SampleValue]:
        return {sample.index: select_value(sample, selector) for sample in samples if sample.kind == kind}

    cw, nw = values(control, "warmup"), values(candidate, "warmup")
    cm, nm = values(control, "measured"), values(candidate, "measured")
    reasons: list[str] = []
    if len(cw) < minimum_warmups or len(nw) < minimum_warmups:
        reasons.append(f"requires at least {minimum_warmups} warmups per artifact")
    if set(cw) != set(nw):
        reasons.append("warmup sample indexes are not fully paired")
    if set(cm) != set(nm):
        reasons.append("measured sample indexes are not fully paired")
    indexes = sorted(set(cm) & set(nm))
    if len(indexes) < minimum_measured:
        reasons.append(f"requires at least {minimum_measured} paired measured samples")
    warmup_control_failures = sum(bool(value.failure_modes) for value in cw.values())
    warmup_candidate_failures = sum(bool(value.failure_modes) for value in nw.values())
    warmup_modes = sorted({mode for value in [*cw.values(), *nw.values()] for mode in value.failure_modes})
    if warmup_control_failures or warmup_candidate_failures:
        reasons.append("failed warmups make the comparison invalid")

    control_modes = sorted({mode for value in cm.values() for mode in value.failure_modes})
    candidate_modes = sorted({mode for value in nm.values() for mode in value.failure_modes})
    control_failed = sum(bool(value.failure_modes) for value in cm.values())
    candidate_failed = sum(bool(value.failure_modes) for value in nm.values())
    new_modes = sorted(set(candidate_modes) - set(control_modes))
    failure_regression = bool(new_modes) or candidate_failed > control_failed
    if (control_failed or candidate_failed) and not failure_regression:
        reasons.append("failure gate is not green")

    rows: list[dict[str, Any]] = []
    deltas: list[float] = []
    control_successes: list[float] = []
    candidate_successes: list[float] = []
    for index in indexes:
        cv, nv = cm[index], nm[index]
        row = {
            "sample_index": index, "control_duration_ms": cv.duration_ms,
            "candidate_duration_ms": nv.duration_ms, "control_failure_modes": list(cv.failure_modes),
            "candidate_failure_modes": list(nv.failure_modes), "delta_ms": None, "delta_percent": None,
            "covariates": covariates.get(("measured", index)),
        }
        if cv.duration_ms is not None and nv.duration_ms is not None:
            if cv.duration_ms <= 0:
                reasons.append(f"control sample {index} has zero duration")
            else:
                row["delta_ms"] = nv.duration_ms - cv.duration_ms
                row["delta_percent"] = 100.0 * row["delta_ms"] / cv.duration_ms
                deltas.append(row["delta_percent"])
                control_successes.append(cv.duration_ms)
                candidate_successes.append(nv.duration_ms)
        rows.append(row)

    outcome, statistics_result = "insufficient_data", None
    if reasons:
        outcome = "insufficient_data"
    elif failure_regression:
        outcome = "regression"
    elif len(deltas) < minimum_measured:
        reasons.append(f"requires at least {minimum_measured} successful paired samples")
    else:
        seed = _seed(control[0].manifest["run"]["order_seed"], selector)
        interval = bootstrap_interval(deltas, statistics.median, seed ^ 0xA5A5A5A5)
        statistics_result = {
            "bootstrap_resamples": BOOTSTRAP_RESAMPLES, "confidence_level": CONFIDENCE_LEVEL,
            "frozen_mde_percent": frozen_mde,
            "control_median_ms": statistics.median(control_successes),
            "candidate_median_ms": statistics.median(candidate_successes),
            "control_p95_ms": _quantile(control_successes, .95) if len(control_successes) >= 20 else None,
            "candidate_p95_ms": _quantile(candidate_successes, .95) if len(candidate_successes) >= 20 else None,
            "paired_median_delta_percent": statistics.median(deltas),
            "paired_median_delta_ci_percent": list(interval),
        }
        if interval[1] <= -frozen_mde:
            outcome = "improvement"
        elif interval[0] >= frozen_mde:
            outcome = "regression"
        else:
            outcome = "noise"

    def role_summary(values_map: dict[int, SampleValue], warmup_map: dict[int, SampleValue]) -> dict[str, Any]:
        failed = sum(bool(value.failure_modes) for value in values_map.values())
        return {
            "warmups": len(warmup_map), "warmup_failed": sum(bool(value.failure_modes) for value in warmup_map.values()),
            "warmup_failure_modes": sorted({m for value in warmup_map.values() for m in value.failure_modes}),
            "measured": len(values_map), "failed": failed,
            "failure_rate": failed / len(values_map) if values_map else None,
            "failure_modes": sorted({m for value in values_map.values() for m in value.failure_modes}),
        }

    control_summary, candidate_summary = role_summary(cm, cw), role_summary(nm, nw)
    control_summary.update(commit=control[0].manifest["product"]["commit"],
                           product_sha256=control[0].manifest["product"]["sha256"],
                           evidence_manifests=[{
                               "run_id": sample.manifest["run"]["id"], "sample_kind": sample.kind,
                               "sample_index": sample.index, "launch_nonce": sample.capture_binding["launch_nonce"],
                               "sha256": _sha256(sample.path),
                           } for sample in sorted(control, key=lambda item: (item.kind, item.index))])
    candidate_summary.update(commit=candidate[0].manifest["product"]["commit"],
                             product_sha256=candidate[0].manifest["product"]["sha256"],
                             new_failure_modes=new_modes,
                             evidence_manifests=[{
                                 "run_id": sample.manifest["run"]["id"], "sample_kind": sample.kind,
                                 "sample_index": sample.index, "launch_nonce": sample.capture_binding["launch_nonce"],
                                 "sha256": _sha256(sample.path),
                             } for sample in sorted(candidate, key=lambda item: (item.kind, item.index))])
    return {
        "schema_version": 1, "tool": {"name": TOOL_NAME, "version": TOOL_VERSION},
        "comparison_id": control[0].manifest["run"]["comparison_id"],
        "sample_policy": sample_policy, "workload": selector,
        "max_free_storage_drift_bytes": max_free_storage_drift_bytes,
        "max_pair_gap_seconds": max_pair_gap_seconds,
        "protocol": {
            "frozen_before_candidate": "operator_attested",
            "limitation": "frozen_sha_not_bound_in_candidate_manifests",
        },
        "frozen_mde_artifact": {
            "sha256": frozen_artifact_sha256, "frozen_mde_percent": frozen_mde,
            "control": frozen_artifact["control"],
        },
        "control": control_summary, "candidate": candidate_summary,
        "warmup_failure_modes": warmup_modes, "outcome": outcome, "reasons": reasons,
        "statistics": statistics_result, "pairs": rows,
    }


def _write_csv(path: pathlib.Path, result: dict[str, Any]) -> None:
    columns = [
        "sample_index", "control_duration_ms", "candidate_duration_ms", "delta_ms", "delta_percent",
        "control_failure_modes", "candidate_failure_modes", "power_source", "battery_state",
        "thermal_state", "free_storage_drift_bytes", "pair_gap_seconds",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for pair in result["pairs"]:
            covariates = pair["covariates"] or {}
            row = {**pair, **covariates}
            row["control_failure_modes"] = ";".join(pair["control_failure_modes"])
            row["candidate_failure_modes"] = ";".join(pair["candidate_failure_modes"])
            writer.writerow({key: row.get(key) for key in columns})


def _field_filters(values: Iterable[str]) -> dict[str, str]:
    filters: dict[str, str] = {}
    for raw in values:
        if raw.count("=") != 1:
            raise CompareError("--field must use key=value")
        key, value = raw.split("=", 1)
        if not SAFE_TOKEN_RE.fullmatch(key) or not SAFE_TOKEN_RE.fullmatch(value) or key in filters:
            raise CompareError("--field must use unique privacy-safe key=value tokens")
        filters[key] = value
    return filters


def _selector(samples: list[Sample], phase: str, backend: str, fields: dict[str, str],
              correctness_fields: list[str]) -> dict[str, Any]:
    if not samples:
        raise CompareError("at least one sample is required")
    workload = samples[0].workload
    try:
        fields = evidence_schema.validate_selector_fields(phase, fields)
        correctness_fields = list(evidence_schema.validate_correctness_fields(
            phase, backend, correctness_fields
        ))
    except ValueError as error:
        raise CompareError(f"CLI selector violates semantic schema: {error}") from error
    if (workload["phase"] != phase or workload["backend"] != backend or workload["fields"] != fields
            or workload["correctness_fields"] != correctness_fields):
        raise CompareError("CLI selector does not match the bound workload")
    return workload


def _add_selector(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--phase", required=True)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--field", action="append", default=[])
    parser.add_argument("--correctness-field", action="append", required=True)
    parser.add_argument("--sample-policy", choices=("short", "long"), default="short")


def _protected_evidence_paths(samples: list[Sample]) -> set[pathlib.Path]:
    protected: set[pathlib.Path] = set()
    for sample in samples:
        root = sample.path.parent
        protected.add(sample.path.resolve())
        protected.add((root / sample.manifest["evidence"]["redacted_summary"]["path"]).resolve())
        protected.update((root / pointer["path"]).resolve()
                         for pointer in sample.manifest["evidence"]["artifacts"])
    return protected


def _reject_output_collisions(outputs: list[pathlib.Path], protected: set[pathlib.Path]) -> None:
    resolved = [path.resolve() for path in outputs]
    if len(set(resolved)) != len(resolved):
        raise CompareError("output paths must be distinct")
    if any(path in protected for path in resolved):
        raise CompareError("output path must not overwrite an input or evidence artifact")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    freeze_parser = commands.add_parser("freeze")
    freeze_parser.add_argument("--control-manifest", action="extend", nargs="+", type=pathlib.Path, required=True)
    _add_selector(freeze_parser)
    freeze_parser.add_argument("--out", type=pathlib.Path, required=True)
    compare_parser = commands.add_parser("compare")
    compare_parser.add_argument("--control-manifest", action="extend", nargs="+", type=pathlib.Path, required=True)
    compare_parser.add_argument("--candidate-manifest", action="extend", nargs="+", type=pathlib.Path, required=True)
    _add_selector(compare_parser)
    compare_parser.add_argument("--frozen-mde", type=pathlib.Path, required=True)
    compare_parser.add_argument("--frozen-mde-sha256", required=True)
    compare_parser.add_argument("--max-free-storage-drift-bytes", type=int, required=True)
    compare_parser.add_argument("--max-pair-gap-seconds", type=float, required=True)
    compare_parser.add_argument("--json-out", type=pathlib.Path)
    compare_parser.add_argument("--csv-out", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        fields = _field_filters(args.field)
        control = [load_sample(path, "control") for path in args.control_manifest]
        selector = _selector(control, args.phase, args.backend, fields, args.correctness_field)
        protected = _protected_evidence_paths(control)
        if args.command == "freeze":
            _reject_output_collisions([args.out], protected)
            artifact = freeze_control(control, selector=selector, sample_policy=args.sample_policy)
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
            print(f"perf-compare: frozen_mde_sha256={_sha256(args.out)}")
            return 0
        candidate = [load_sample(path, "candidate") for path in args.candidate_manifest]
        protected |= _protected_evidence_paths(candidate)
        protected.add(args.frozen_mde.resolve())
        _reject_output_collisions([path for path in (args.json_out, args.csv_out) if path], protected)
        frozen = load_frozen(args.frozen_mde, args.frozen_mde_sha256)
        result = compare(control, candidate, selector=selector, sample_policy=args.sample_policy,
                         frozen_artifact=frozen, frozen_artifact_sha256=args.frozen_mde_sha256,
                         max_free_storage_drift_bytes=args.max_free_storage_drift_bytes,
                         max_pair_gap_seconds=args.max_pair_gap_seconds)
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.json_out:
            args.json_out.parent.mkdir(parents=True, exist_ok=True)
            args.json_out.write_text(encoded)
        else:
            sys.stdout.write(encoded)
        if args.csv_out:
            _write_csv(args.csv_out, result)
    except (CompareError, OSError) as error:
        print(f"perf-compare: FAIL: {error}", file=sys.stderr)
        return 1
    return 2 if result["outcome"] == "regression" else 3 if result["outcome"] == "insufficient_data" else 0


if __name__ == "__main__":
    raise SystemExit(main())
