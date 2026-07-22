#!/usr/bin/env python3
"""Parse and summarize Labstream privacy-safe performance span logs.

For comparison evidence, use the closed form:

  scripts/perf-log-summary.py --emit-capture-marker --manifest run/manifest.json \
    --workload-id workload-0123456789ab >> run/raw/artifact-0001.log

Append the bounded `log show` capture from the launched run to that same raw file,
then update its manifest SHA-256 pointer before deriving the summary:

  scripts/perf-log-summary.py --json --strict --manifest run/manifest.json \
    --raw-artifact run/raw/artifact-0001.log \
    --workload-id workload-0123456789ab --phase home.load --backend Plex \
    --correctness-field hub_count --correctness-field item_count --expected-span-count 1

The manifest may still have a placeholder summary checksum while this command is
running. Update that pointer after writing the generated summary.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import math
import pathlib
import re
import secrets
import sys
from typing import Any, Iterable

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
import perf_evidence_schema as evidence_schema

KEY_RE = evidence_schema.KEY_RE
OPAQUE_ID_RE = re.compile(r"^workload-[a-f0-9]{12}$")
SUMMARY_TOOL = {"name": "labstream-perf-log-summary", "version": "2"}
PerfSpan = evidence_schema.SpanRecord


def event_message(line: str) -> str:
    return evidence_schema.event_message(line)


def parse_span_line_diagnostic(line: str) -> tuple[PerfSpan | None, str | None]:
    return evidence_schema.parse_span_line_diagnostic(line)


def parse_span_line(line: str) -> PerfSpan | None:
    return parse_span_line_diagnostic(line)[0]


def parse_spans(lines: Iterable[str]) -> list[PerfSpan]:
    return [span for line in lines if (span := parse_span_line(line)) is not None]


def parse_spans_with_diagnostics(lines: Iterable[str]) -> tuple[list[PerfSpan], dict[str, int]]:
    """Parse spans and count malformed records without counting unrelated log noise."""
    spans: list[PerfSpan] = []
    rejected: dict[str, int] = {}
    for line in lines:
        span, reason = parse_span_line_diagnostic(line)
        if span is not None:
            spans.append(span)
        elif reason is not None:
            rejected[reason] = rejected.get(reason, 0) + 1
    return spans, rejected


def percentile(values: list[int], pct: float) -> int:
    if not values:
        return 0
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return ordered[int(rank)]
    return round(ordered[lo] + (ordered[hi] - ordered[lo]) * (rank - lo))


def group_label(span: PerfSpan, group_fields: list[str]) -> str:
    if not group_fields:
        return "all"
    return ",".join(f"{field}={span.fields.get(field, '-')}" for field in group_fields)


def summarize(spans: Iterable[PerfSpan], group_fields: list[str] | None = None) -> list[dict[str, int | str]]:
    group_fields = group_fields or []
    grouped: dict[tuple[str, str, str], list[PerfSpan]] = {}
    for span in spans:
        grouped.setdefault((span.phase, span.backend, group_label(span, group_fields)), []).append(span)
    rows: list[dict[str, int | str]] = []
    for (phase, backend, label), spans_in_group in sorted(grouped.items()):
        durations = [span.duration_ms for span in spans_in_group]
        row: dict[str, int | str] = {
            "phase": phase, "backend": backend, "count": len(spans_in_group),
            "failures": sum(span.result != "success" for span in spans_in_group),
            "min_ms": min(durations), "p50_ms": percentile(durations, 0.50),
            "p95_ms": percentile(durations, 0.95), "max_ms": max(durations),
        }
        if group_fields:
            row["group"] = label
        rows.append(row)
    return rows


def manifest_binding(manifest: dict[str, Any]) -> dict[str, Any]:
    run = manifest["run"]
    scenario = manifest["scenario"]
    return {
        "run_id": run["id"],
        "comparison_id": run["comparison_id"],
        "artifact_role": run["artifact_role"],
        "sample_kind": run["sample_kind"],
        "sample_index": run["sample_index"],
        "scenario_id": scenario["id"],
        "backend_kind": scenario["backend_kind"],
    }


def json_document(spans: list[PerfSpan], rejected: dict[str, int], *,
                  binding: dict[str, Any], workload: dict[str, Any],
                  source_artifact: dict[str, str], capture_binding: dict[str, str]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "tool": SUMMARY_TOOL,
        "binding": binding,
        "capture_binding": capture_binding,
        "source_artifact": source_artifact,
        "workload": workload,
        "spans": [dataclasses.asdict(span) for span in spans],
        "rows": summarize(spans),
        "diagnostics": {"rejected_span_count": sum(rejected.values()), "rejection_reasons": rejected},
    }


def render(rows: list[dict[str, int | str]], markdown: bool) -> str:
    headers = ["phase", "backend"]
    if rows and "group" in rows[0]:
        headers.append("group")
    headers += ["count", "failures", "min_ms", "p50_ms", "p95_ms", "max_ms"]
    if markdown:
        output = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
        output.extend("| " + " | ".join(str(row[key]) for key in headers) + " |" for row in rows)
        return "\n".join(output)
    widths = {key: max(len(key), *(len(str(row[key])) for row in rows)) for key in headers}
    output = ["  ".join(key.ljust(widths[key]) for key in headers)]
    output.append("  ".join("-" * widths[key] for key in headers))
    output.extend("  ".join(str(row[key]).ljust(widths[key]) for key in headers) for row in rows)
    return "\n".join(output)


def _field_filters(values: Iterable[str]) -> dict[str, str]:
    filters: dict[str, str] = {}
    for raw in values:
        if raw.count("=") != 1:
            raise ValueError("--field must use key=value")
        key, value = raw.split("=", 1)
        if KEY_RE.fullmatch(key) is None or evidence_schema.SAFE_VALUE_RE.fullmatch(value) is None or key in filters:
            raise ValueError("--field must be a unique typed key=value")
        filters[key] = value
    return filters


def _source_artifact(manifest: dict[str, Any], manifest_path: pathlib.Path,
                     raw_path: pathlib.Path) -> dict[str, str]:
    root = manifest_path.resolve().parent
    resolved = raw_path.resolve()
    try:
        relative = resolved.relative_to(root).as_posix()
    except ValueError as error:
        raise ValueError("--raw-artifact must remain inside the manifest run directory") from error
    if raw_path.is_symlink() or not raw_path.is_file():
        raise ValueError("--raw-artifact must be a regular non-symlink file")
    matches = [pointer for pointer in manifest["evidence"]["artifacts"]
               if isinstance(pointer, dict) and pointer.get("path") == relative]
    if len(matches) != 1 or set(matches[0]) != {"path", "sha256"}:
        raise ValueError("--raw-artifact must exactly match one manifest raw artifact pointer")
    digest = hashlib.sha256(raw_path.read_bytes()).hexdigest()
    if matches[0]["sha256"] != digest:
        raise ValueError("--raw-artifact checksum does not match its manifest pointer")
    return {"path": relative, "sha256": digest}


def _capture_binding(lines: list[str], run_id: str, workload_id: str) -> dict[str, str]:
    bindings: list[dict[str, str]] = []
    for line in lines:
        binding, reason = evidence_schema.parse_capture_line_diagnostic(line)
        if reason is not None:
            raise ValueError(f"malformed perf.capture record: {reason}")
        if binding is not None:
            bindings.append(binding)
    if len(bindings) != 1:
        raise ValueError("raw artifact must contain exactly one perf.capture binding")
    binding = bindings[0]
    if binding["run_id"] != run_id or binding["workload_id"] != workload_id:
        raise ValueError("perf.capture binding does not match manifest run/workload")
    return {**binding, "binding_kind": "declared_capture"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", action="append", default=[])
    parser.add_argument("--backend", action="append", default=[])
    parser.add_argument("--field", action="append", default=[])
    parser.add_argument("--group-field", action="append", default=[])
    parser.add_argument("--markdown", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--manifest", type=pathlib.Path)
    parser.add_argument("--raw-artifact", type=pathlib.Path)
    parser.add_argument("--workload-id")
    parser.add_argument("--emit-capture-marker", action="store_true")
    parser.add_argument("--launch-nonce")
    parser.add_argument("--correctness-field", action="append", default=[])
    parser.add_argument("--expected-span-count", type=int)
    args = parser.parse_args(argv)
    if args.emit_capture_marker:
        if args.manifest is None or args.workload_id is None:
            parser.error("--emit-capture-marker requires --manifest and --workload-id")
        nonce = args.launch_nonce or f"nonce-{secrets.token_hex(8)}"
        if evidence_schema.WORKLOAD_ID_RE.fullmatch(args.workload_id) is None or evidence_schema.NONCE_RE.fullmatch(nonce) is None:
            parser.error("capture workload/nonce must use opaque workload-<12 hex> and nonce-<16 hex> values")
        try:
            manifest = json.loads(args.manifest.read_text())
            run_id = manifest["run"]["id"]
        except (OSError, json.JSONDecodeError, KeyError, TypeError):
            print("Capture manifest run id is unavailable.", file=sys.stderr)
            return 2
        if not isinstance(run_id, str) or evidence_schema.RUN_ID_RE.fullmatch(run_id) is None:
            print("Capture manifest run id is invalid.", file=sys.stderr)
            return 2
        print(f"perf.capture run_id={run_id} workload_id={args.workload_id} launch_nonce={nonce}")
        return 0
    try:
        field_filters = _field_filters(args.field)
    except ValueError as error:
        parser.error(str(error))

    manifest = binding = source_artifact = capture_binding = None
    if args.json:
        if not args.strict or args.manifest is None or args.raw_artifact is None or args.workload_id is None:
            parser.error("--json requires --strict, --manifest, --raw-artifact, and --workload-id")
        try:
            manifest = json.loads(args.manifest.read_text())
            binding = manifest_binding(manifest)
            source_artifact = _source_artifact(manifest, args.manifest, args.raw_artifact)
            lines = args.raw_artifact.read_text().splitlines()
            capture_binding = _capture_binding(lines, binding["run_id"], args.workload_id)
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            print(f"Comparison input provenance is invalid: {error}", file=sys.stderr)
            return 2
    else:
        lines = list(sys.stdin)
    spans, rejected = parse_spans_with_diagnostics(lines)
    if args.strict and rejected:
        print(f"Rejected {sum(rejected.values())} malformed perf.span record(s): {json.dumps(rejected, sort_keys=True)}", file=sys.stderr)
        return 2
    correctness_fields: list[str] = []
    if args.json:
        if len(args.phase) != 1 or len(args.backend) != 1:
            parser.error("--json requires exactly one --phase and one --backend")
        try:
            field_filters = evidence_schema.validate_selector_fields(args.phase[0], field_filters)
            correctness_fields = list(evidence_schema.validate_correctness_fields(
                args.phase[0], args.backend[0], args.correctness_field
            ))
        except ValueError as error:
            parser.error(str(error))
    if args.phase:
        spans = [span for span in spans if span.phase in set(args.phase)]
    if args.backend:
        spans = [span for span in spans if span.backend in set(args.backend)]
    if field_filters:
        spans = [span for span in spans if all(span.fields.get(key) == value for key, value in field_filters.items())]
    rows = summarize(spans, args.group_field)
    if not rows:
        print("No perf.span lines found.", file=sys.stderr)
        return 1
    if args.json:
        if args.workload_id is None or OPAQUE_ID_RE.fullmatch(args.workload_id) is None:
            parser.error("--workload-id must use workload-<12 hex>")
        if args.expected_span_count is None or args.expected_span_count <= 0:
            parser.error("--expected-span-count must be positive")
        if len(spans) != args.expected_span_count:
            print(f"Expected {args.expected_span_count} selected spans, found {len(spans)}.", file=sys.stderr)
            return 2
        for span in spans:
            if span.result == "success" and any(field not in span.fields for field in correctness_fields):
                print("Successful span is missing a declared correctness field.", file=sys.stderr)
                return 2
        workload = {
            "id": args.workload_id,
            "phase": args.phase[0],
            "backend": args.backend[0],
            "fields": field_filters,
            "correctness_fields": correctness_fields,
            "expected_span_count": args.expected_span_count,
            "aggregation": "median",
        }
        assert binding is not None and source_artifact is not None and capture_binding is not None
        print(json.dumps(json_document(spans, rejected, binding=binding, workload=workload,
                                       source_artifact=source_artifact,
                                       capture_binding=capture_binding), indent=2, sort_keys=True))
        return 0
    print(render(rows, args.markdown))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
