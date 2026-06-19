#!/usr/bin/env python3
"""Summarize VisionPlex issue #42 performance span logs.

Usage examples:

  xcrun simctl spawn booted log show --style json --last 15m \
    --predicate 'subsystem == "com.jlipworth.VisionPlex" && category == "Performance"' \
    | scripts/perf-log-summary.py --markdown

  log show --style compact --last 10m \
    --predicate 'subsystem == "com.jlipworth.VisionPlex" && category == "Performance"' \
    | scripts/perf-log-summary.py --phase playback.startup

The parser only consumes `perf.span key=value ...` lines emitted by
PerformanceInstrumentation. Values are expected to be sanitized one-token strings.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from typing import Iterable

SPAN_RE = re.compile(r"\bperf\.span\s+(?P<body>.*)$")
TOKEN_RE = re.compile(r"(?P<key>[A-Za-z0-9_.:-]+)=(?P<value>[^\s]+)")


@dataclass(frozen=True)
class PerfSpan:
    phase: str
    backend: str
    result: str
    duration_ms: int
    fields: dict[str, str]


def event_message(line: str) -> str:
    """Return the log message from plain text or one JSON log line."""
    stripped = line.strip()
    if not stripped:
        return ""
    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError:
            return stripped
        for key in ("eventMessage", "message", "composedMessage"):
            value = obj.get(key)
            if isinstance(value, str):
                return value
    return stripped


def parse_span_line(line: str) -> PerfSpan | None:
    message = event_message(line)
    match = SPAN_RE.search(message)
    if not match:
        return None
    fields = {m.group("key"): m.group("value") for m in TOKEN_RE.finditer(match.group("body"))}
    try:
        return PerfSpan(
            phase=fields.pop("phase"),
            backend=fields.pop("backend"),
            result=fields.pop("result", "success"),
            duration_ms=int(fields.pop("duration_ms")),
            fields=fields,
        )
    except (KeyError, ValueError):
        return None


def parse_spans(lines: Iterable[str]) -> list[PerfSpan]:
    return [span for line in lines if (span := parse_span_line(line)) is not None]


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
    for (phase, backend, group), spans_in_group in sorted(grouped.items()):
        durations = [s.duration_ms for s in spans_in_group]
        row: dict[str, int | str] = {
            "phase": phase,
            "backend": backend,
            "count": len(spans_in_group),
            "failures": sum(1 for s in spans_in_group if s.result != "success"),
            "min_ms": min(durations),
            "p50_ms": percentile(durations, 0.50),
            "p95_ms": percentile(durations, 0.95),
            "max_ms": max(durations),
        }
        if group_fields:
            row["group"] = group
        rows.append(row)
    return rows


def render(rows: list[dict[str, int | str]], markdown: bool) -> str:
    headers = ["phase", "backend"]
    if rows and "group" in rows[0]:
        headers.append("group")
    headers += ["count", "failures", "min_ms", "p50_ms", "p95_ms", "max_ms"]
    if markdown:
        out = ["| " + " | ".join(headers) + " |",
               "| " + " | ".join("---" for _ in headers) + " |"]
        out.extend("| " + " | ".join(str(row[h]) for h in headers) + " |" for row in rows)
        return "\n".join(out)

    widths = {h: max(len(h), *(len(str(row[h])) for row in rows)) for h in headers}
    out = ["  ".join(h.ljust(widths[h]) for h in headers)]
    out.append("  ".join("-" * widths[h] for h in headers))
    out.extend("  ".join(str(row[h]).ljust(widths[h]) for h in headers) for row in rows)
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", action="append", default=[], help="phase to include; repeatable")
    parser.add_argument("--backend", action="append", default=[], help="backend to include; repeatable")
    parser.add_argument("--group-field", action="append", default=[],
                        help="span field to include in grouping, e.g. width, height, path_mode; repeatable")
    parser.add_argument("--markdown", action="store_true", help="render a Markdown table")
    args = parser.parse_args(argv)

    spans = parse_spans(sys.stdin)
    if args.phase:
        allowed = set(args.phase)
        spans = [s for s in spans if s.phase in allowed]
    if args.backend:
        allowed = set(args.backend)
        spans = [s for s in spans if s.backend in allowed]

    rows = summarize(spans, group_fields=args.group_field)
    if not rows:
        print("No perf.span lines found.", file=sys.stderr)
        return 1
    print(render(rows, markdown=args.markdown))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
