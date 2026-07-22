#!/usr/bin/env python3
"""Create a typed, privacy-safe idle summary from a closed xctrace XML export.

The input is the single-process aggregate table exported from a System Trace.  This
tool deliberately does not accept a full trace TOC or arbitrary Instruments XML:
the capture runner must select the table and the exact process row first.  Unknown
tables, columns, units, Xcode builds, PIDs, or capture windows fail closed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from typing import Any

MAX_INPUT_BYTES = 5 * 1024 * 1024
MAX_NS = 86_400 * 1_000_000_000
MAX_WAKEUPS = 1_000_000_000
BUILD_RE = re.compile(r"^[0-9]{1,3}[A-Z][A-Za-z0-9]{1,16}$")
ID_PATTERNS = {
    "run_id": re.compile(r"^run-[a-f0-9]{12}$"),
    "comparison_id": re.compile(r"^comparison-[a-f0-9]{12}$"),
    "scenario_id": re.compile(r"^scenario-[a-f0-9]{12}$"),
}
ROLES = {"control", "candidate", "standalone"}
KINDS = {"warmup", "measured"}
ROOT_TAG = "trace-query-result"
TABLE_NAME = "system-trace-process-summary"
TABLE_UNIT = "nanoseconds"
COLUMNS = (
    ("process-id", "count"),
    ("window-start", "nanoseconds"),
    ("window-end", "nanoseconds"),
    ("cpu-running", "nanoseconds"),
    ("wakeups", "count"),
)
ARCHIVE_PATH_RE = re.compile(r"^raw/artifact-[0-9]{4}\.trace\.zip$")
EXPORT_PATH_RE = re.compile(r"^raw/artifact-[0-9]{4}\.xml$")
EXTRACTION_PATH_RE = re.compile(r"^raw/artifact-[0-9]{4}\.json$")
SUMMARY_PATH = "summary/redacted.json"


class IdleSummaryError(ValueError):
    pass


def fail(message: str) -> None:
    raise IdleSummaryError(message)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _closed(element: ET.Element, *, tag: str, attributes: set[str], children: list[str]) -> None:
    if element.tag != tag or set(element.attrib) != attributes or [child.tag for child in element] != children:
        fail(f"xctrace export has unsupported {tag} shape")
    if element.text and element.text.strip():
        fail(f"xctrace export has unexpected {tag} text")
    if any(child.tail and child.tail.strip() for child in element):
        fail(f"xctrace export has unexpected text after {tag} child")


def _integer(value: str, label: str, *, maximum: int) -> int:
    if re.fullmatch(r"0|[1-9][0-9]{0,19}", value) is None:
        fail(f"{label} must be a canonical nonnegative integer")
    number = int(value)
    if number > maximum:
        fail(f"{label} exceeds its bound")
    return number


def parse_export(data: bytes, *, expected_xcode_build: str, expected_pid: int,
                 expected_duration_ns: int, window_tolerance_ns: int) -> dict[str, Any]:
    if not data or len(data) > MAX_INPUT_BYTES:
        fail("xctrace export is empty or exceeds the bounded input size")
    lowered = data.lower()
    if b"<!doctype" in lowered or b"<!entity" in lowered:
        fail("xctrace export must not contain a DTD or entity declarations")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        fail(f"xctrace export is not well-formed XML: {error}")
    _closed(root, tag=ROOT_TAG, attributes={"schema-version", "xcode-build"},
            children=["table"])
    if root.attrib["schema-version"] != "1":
        fail("xctrace export schema version is unsupported")
    if root.attrib["xcode-build"] != expected_xcode_build:
        fail("xctrace export Xcode build does not match the capture contract")

    table = root[0]
    _closed(table, tag="table", attributes={"name", "unit"},
            children=["columns", "rows"])
    if table.attrib != {"name": TABLE_NAME, "unit": TABLE_UNIT}:
        fail("xctrace export table or primary unit is unsupported")
    columns, rows = table
    _closed(columns, tag="columns", attributes=set(), children=["column"] * len(COLUMNS))
    actual_columns: list[tuple[str, str]] = []
    for column in columns:
        _closed(column, tag="column", attributes={"name", "unit"}, children=[])
        actual_columns.append((column.attrib["name"], column.attrib["unit"]))
    if tuple(actual_columns) != COLUMNS:
        fail("xctrace export columns or units are unsupported")
    _closed(rows, tag="rows", attributes=set(), children=["row"])
    row = rows[0]
    _closed(row, tag="row", attributes={name for name, _ in COLUMNS}, children=[])

    pid = _integer(row.attrib["process-id"], "process-id", maximum=2**31 - 1)
    if pid != expected_pid:
        fail("xctrace export process ID does not match the exact captured PID")
    start_ns = _integer(row.attrib["window-start"], "window-start", maximum=MAX_NS)
    end_ns = _integer(row.attrib["window-end"], "window-end", maximum=MAX_NS)
    cpu_ns = _integer(row.attrib["cpu-running"], "cpu-running", maximum=MAX_NS)
    wakeups = _integer(row.attrib["wakeups"], "wakeups", maximum=MAX_WAKEUPS)
    if end_ns <= start_ns:
        fail("xctrace export capture window is empty or reversed")
    duration_ns = end_ns - start_ns
    if abs(duration_ns - expected_duration_ns) > window_tolerance_ns:
        fail("xctrace export capture window differs from the declared duration")
    if cpu_ns > duration_ns:
        fail("single-process CPU running time exceeds the capture window")
    return {
        "pid": pid,
        "window_start_ns": start_ns,
        "window_end_ns": end_ns,
        "window_duration_ns": duration_ns,
        "cpu_running_ns": cpu_ns,
        "wakeups_count": wakeups,
    }


def pointer(path: pathlib.Path, run_dir: pathlib.Path) -> dict[str, str]:
    try:
        relative = path.resolve().relative_to(run_dir.resolve()).as_posix()
    except ValueError:
        fail("artifact path must remain inside the run directory")
    if path.is_symlink() or not path.is_file():
        fail("artifact path must name a regular non-symlink file")
    return {"path": relative, "sha256": sha256_file(path)}


def validate_output_path(path: pathlib.Path, run_dir: pathlib.Path) -> str:
    if path.is_symlink() or path.exists():
        fail("output path must not already exist or be a symlink")
    try:
        parent = path.parent.resolve()
        parent.relative_to(run_dir.resolve())
        relative = (parent / path.name).relative_to(run_dir.resolve()).as_posix()
    except ValueError:
        fail("output path must remain inside the run directory")
    return relative


def json_bytes(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()


def publish_json_pair(outputs: list[tuple[pathlib.Path, bytes]], *, link=os.link) -> None:
    """Publish both JSON files or remove every file created by this attempt."""
    temporaries: list[pathlib.Path] = []
    published: list[pathlib.Path] = []
    try:
        for path, data in outputs:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, raw_temporary = tempfile.mkstemp(prefix=f".{path.name}.idle-tmp-", dir=path.parent)
            temporary = pathlib.Path(raw_temporary)
            temporaries.append(temporary)
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
                os.fsync(fd)
            finally:
                os.close(fd)
        for (path, _), temporary in zip(outputs, temporaries, strict=True):
            link(temporary, path)
            published.append(path)
        for temporary in temporaries:
            temporary.unlink()
        for parent in {path.parent for path, _ in outputs}:
            directory_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except Exception:
        for path in published:
            path.unlink(missing_ok=True)
        for temporary in temporaries:
            temporary.unlink(missing_ok=True)
        raise


def binding(args: argparse.Namespace) -> dict[str, Any]:
    values: dict[str, Any] = {
        "run_id": args.run_id,
        "comparison_id": args.comparison_id,
        "artifact_role": args.artifact_role,
        "sample_kind": args.sample_kind,
        "sample_index": args.sample_index,
        "scenario_id": args.scenario_id,
    }
    for field, pattern in ID_PATTERNS.items():
        if pattern.fullmatch(values[field]) is None:
            fail(f"{field} is not an opaque contract identifier")
    if args.artifact_role not in ROLES or args.sample_kind not in KINDS or args.sample_index < 0:
        fail("sample binding is outside the closed contract")
    return values


def write_outputs(args: argparse.Namespace) -> None:
    if BUILD_RE.fullmatch(args.xcode_build) is None:
        fail("Xcode build is not version-shaped")
    if args.expected_pid <= 0 or args.duration_seconds <= 0:
        fail("PID and duration must be positive")
    if not 0 <= args.window_tolerance_ms <= 5_000:
        fail("window tolerance must be between zero and 5000 milliseconds")
    if args.run_dir.is_symlink() or not args.run_dir.is_dir():
        fail("run directory must be a real directory")
    run_dir = args.run_dir.resolve()
    sample_binding = binding(args)
    extraction_relative = validate_output_path(args.extraction_out, run_dir)
    summary_relative = validate_output_path(args.summary_out, run_dir)
    export = pointer(args.input_xml, run_dir)
    archive = pointer(args.trace_archive, run_dir)
    if (ARCHIVE_PATH_RE.fullmatch(archive["path"]) is None
            or EXPORT_PATH_RE.fullmatch(export["path"]) is None
            or EXTRACTION_PATH_RE.fullmatch(extraction_relative) is None
            or summary_relative != SUMMARY_PATH):
        fail("idle inputs and outputs must use their closed opaque run-directory paths")
    if len({archive["path"], export["path"], extraction_relative, summary_relative}) != 4:
        fail("idle inputs and outputs must use distinct paths")
    metrics = parse_export(
        args.input_xml.read_bytes(), expected_xcode_build=args.xcode_build,
        expected_pid=args.expected_pid, expected_duration_ns=args.duration_seconds * 1_000_000_000,
        window_tolerance_ns=args.window_tolerance_ms * 1_000_000,
    )
    extraction = {
        "schema_version": 1,
        "tool": {"name": "labstream-xctrace-idle-summary", "version": "1"},
        "xcode_build": args.xcode_build,
        "table": {"name": TABLE_NAME, "unit": TABLE_UNIT,
                  "columns": [{"name": name, "unit": unit} for name, unit in COLUMNS]},
        "sources": {"trace_archive": archive, "source_export": export},
        "capture": {key: metrics[key] for key in
                    ("pid", "window_start_ns", "window_end_ns", "window_duration_ns")},
        "metrics": {key: metrics[key] for key in ("cpu_running_ns", "wakeups_count")},
    }
    extraction_data = json_bytes(extraction)
    extraction_pointer = {
        "path": extraction_relative,
        "sha256": hashlib.sha256(extraction_data).hexdigest(),
    }
    summary = {
        "schema_version": 1,
        "tool": {"name": "labstream-xctrace-idle-summary", "version": "1"},
        "binding": sample_binding,
        "sources": {"trace_archive": archive, "extraction": extraction_pointer},
        "capture": {
            "xcode_build": args.xcode_build,
            "pid": metrics["pid"],
            "expected_duration_ns": args.duration_seconds * 1_000_000_000,
            "window_tolerance_ns": args.window_tolerance_ms * 1_000_000,
            "actual_duration_ns": metrics["window_duration_ns"],
        },
        "metrics": {key: metrics[key] for key in ("cpu_running_ns", "wakeups_count")},
    }
    summary_data = json_bytes(summary)
    publish_json_pair([
        (args.extraction_out, extraction_data),
        (args.summary_out, summary_data),
    ])


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-xml", required=True, type=pathlib.Path)
    parser.add_argument("--trace-archive", required=True, type=pathlib.Path)
    parser.add_argument("--run-dir", required=True, type=pathlib.Path)
    parser.add_argument("--extraction-out", required=True, type=pathlib.Path)
    parser.add_argument("--summary-out", required=True, type=pathlib.Path)
    parser.add_argument("--xcode-build", required=True)
    parser.add_argument("--expected-pid", required=True, type=int)
    parser.add_argument("--duration-seconds", required=True, type=int)
    parser.add_argument("--window-tolerance-ms", type=int, default=1_000)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--comparison-id", required=True)
    parser.add_argument("--artifact-role", required=True, choices=sorted(ROLES))
    parser.add_argument("--sample-kind", required=True, choices=sorted(KINDS))
    parser.add_argument("--sample-index", required=True, type=int)
    parser.add_argument("--scenario-id", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    write_outputs(parse_args(argv))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IdleSummaryError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
