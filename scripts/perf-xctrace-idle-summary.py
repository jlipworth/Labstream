#!/usr/bin/env python3
"""Normalize native System Trace XML into a typed, privacy-safe idle summary."""
from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from typing import Any

MAX_INPUT_BYTES = 25 * 1024 * 1024
MAX_NS = 86_400 * 1_000_000_000
MAX_CPU_NS = MAX_NS * 1024
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
NATIVE_COLUMNS = (
    ("start", "Start Time", "start-time"),
    ("thread", "Thread", "thread"),
    ("state", "State", "thread-state"),
    ("duration", "Duration", "duration"),
    ("process", "Process", "process"),
    ("core", "Core", "core"),
    ("cputime", "Running Time", "duration-on-core"),
    ("waittime", "Wait Time", "duration-waiting"),
    ("priority", "Priority", "sched-priority"),
    ("note", "Note", "narrative"),
    ("summary", "Summary", "narrative"),
    ("made-runnable-by-thread", "Made Runnable By", "thread"),
    ("preempted-by-thread", "Preempted By", "thread"),
    ("yielded-to-thread", "Yielded To", "thread"),
    ("rebalanced-from-cpu", "Rebalanced From CPU", "core"),
    ("thermal-throttled", "Thermal Throttled", "boolean"),
)
NATIVE_CELL_TAGS = (
    "start-time", "thread", "thread-state", "duration", "process", "core",
    "duration", "duration", "sched-priority", "narrative", "narrative",
    "thread", "thread", "thread", "core", "boolean",
)
KNOWN_STATES = {"Running", "Runnable", "Idle", "Blocked", "Interrupted", "Preempted"}
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


def _xml(path: pathlib.Path, label: str) -> ET.Element:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} must be a regular non-symlink file")
    data = path.read_bytes()
    if not data or len(data) > MAX_INPUT_BYTES:
        fail(f"{label} is empty or exceeds the bounded input size")
    lowered = data.lower()
    if b"<!doctype" in lowered or b"<!entity" in lowered:
        fail(f"{label} must not contain a DTD or entity declarations")
    try:
        return ET.fromstring(data)
    except ET.ParseError as error:
        fail(f"{label} is not well-formed XML: {error}")


def _closed(element: ET.Element, *, tag: str, attributes: set[str], children: list[str]) -> None:
    if element.tag != tag or set(element.attrib) != attributes or [child.tag for child in element] != children:
        fail(f"normalized xctrace export has unsupported {tag} shape")
    if element.text and element.text.strip():
        fail(f"normalized xctrace export has unexpected {tag} text")
    if any(child.tail and child.tail.strip() for child in element):
        fail(f"normalized xctrace export has unexpected text after {tag} child")


def _integer(value: str, label: str, *, maximum: int) -> int:
    if re.fullmatch(r"0|[1-9][0-9]{0,19}", value) is None:
        fail(f"{label} must be a canonical nonnegative integer")
    number = int(value)
    if number > maximum:
        fail(f"{label} exceeds its bound")
    return number


def parse_export(data: bytes, *, expected_xcode_build: str, expected_pid: int,
                 expected_duration_ns: int, window_tolerance_ns: int) -> dict[str, Any]:
    """Validate the closed normalized XML contract emitted by this tool."""
    if not data or len(data) > MAX_INPUT_BYTES:
        fail("normalized xctrace export is empty or exceeds the bounded input size")
    lowered = data.lower()
    if b"<!doctype" in lowered or b"<!entity" in lowered:
        fail("normalized xctrace export must not contain a DTD or entity declarations")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        fail(f"normalized xctrace export is not well-formed XML: {error}")
    _closed(root, tag=ROOT_TAG, attributes={"schema-version", "xcode-build"}, children=["table"])
    if root.attrib != {"schema-version": "1", "xcode-build": expected_xcode_build}:
        fail("normalized xctrace export version or Xcode build is unsupported")
    table = root[0]
    _closed(table, tag="table", attributes={"name", "unit"}, children=["columns", "rows"])
    if table.attrib != {"name": TABLE_NAME, "unit": TABLE_UNIT}:
        fail("normalized xctrace export table or primary unit is unsupported")
    columns, rows = table
    _closed(columns, tag="columns", attributes=set(), children=["column"] * len(COLUMNS))
    actual_columns = []
    for column in columns:
        _closed(column, tag="column", attributes={"name", "unit"}, children=[])
        actual_columns.append((column.attrib["name"], column.attrib["unit"]))
    if tuple(actual_columns) != COLUMNS:
        fail("normalized xctrace export columns or units are unsupported")
    _closed(rows, tag="rows", attributes=set(), children=["row"])
    row = rows[0]
    _closed(row, tag="row", attributes={name for name, _ in COLUMNS}, children=[])
    pid = _integer(row.attrib["process-id"], "process-id", maximum=2**31 - 1)
    if pid != expected_pid:
        fail("normalized xctrace export process ID does not match the exact captured PID")
    start_ns = _integer(row.attrib["window-start"], "window-start", maximum=MAX_NS)
    end_ns = _integer(row.attrib["window-end"], "window-end", maximum=MAX_NS)
    cpu_ns = _integer(row.attrib["cpu-running"], "cpu-running", maximum=MAX_CPU_NS)
    wakeups = _integer(row.attrib["wakeups"], "wakeups", maximum=MAX_WAKEUPS)
    if end_ns <= start_ns:
        fail("normalized xctrace export capture window is empty or reversed")
    duration_ns = end_ns - start_ns
    if abs(duration_ns - expected_duration_ns) > window_tolerance_ns:
        fail("normalized xctrace export capture window differs from the declared duration")
    return {"pid": pid, "window_start_ns": start_ns, "window_end_ns": end_ns,
            "window_duration_ns": duration_ns, "cpu_running_ns": cpu_ns,
            "wakeups_count": wakeups}


def _decimal_seconds_ns(value: str, label: str) -> int:
    try:
        ns = Decimal(value) * Decimal(1_000_000_000)
    except InvalidOperation:
        fail(f"{label} must be finite decimal seconds")
    if not ns.is_finite() or ns < 0 or ns > MAX_NS or ns != ns.to_integral_value():
        fail(f"{label} must resolve exactly to integer nanoseconds")
    return _integer(str(int(ns)), label, maximum=MAX_NS)


def _time_limit_ns(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]{0,8}) (second|seconds|minute|minutes|hour|hours)", value)
    if match is None:
        fail("xctrace TOC time limit has unsupported units")
    count = int(match.group(1))
    unit = match.group(2)
    if (count == 1) != (not unit.endswith("s")):
        fail("xctrace TOC time limit is not canonical")
    multiplier = {"second": 1, "minute": 60, "hour": 3600}[unit.removesuffix("s")]
    seconds = count * multiplier
    if seconds > MAX_NS // 1_000_000_000:
        fail("xctrace TOC time limit exceeds its bound")
    return seconds * 1_000_000_000


def parse_toc(root: ET.Element, *, expected_pid: int, expected_xcode_build: str,
              expected_duration_ns: int, tolerance_ns: int) -> int:
    if root.tag != "trace-toc" or root.attrib or len(root.findall("run")) != 1:
        fail("xctrace TOC must contain exactly one run")
    run = root.find("run")
    if run is None or run.attrib != {"number": "1"}:
        fail("xctrace TOC run identity is unsupported")
    attached = run.findall("./info/target/process[@type='attached']")
    if len(attached) != 1 or _integer(attached[0].attrib.get("pid", ""), "attached PID",
                                      maximum=2**31 - 1) != expected_pid:
        fail("xctrace TOC must contain exactly one attached target matching the captured PID")
    summary = run.find("./info/summary")
    if summary is None:
        fail("xctrace TOC has no run summary")
    version = summary.findtext("instruments-version", "")
    match = re.fullmatch(r"[^()]+ \(([0-9]{1,3}[A-Z][A-Za-z0-9]{1,16})\)", version)
    if match is None or match.group(1) != expected_xcode_build:
        fail("xctrace TOC Xcode build does not match the capture contract")
    if summary.findtext("template-name") != "System Trace":
        fail("xctrace TOC template is not System Trace")
    duration_ns = _decimal_seconds_ns(summary.findtext("duration", ""), "TOC duration")
    if abs(duration_ns - expected_duration_ns) > tolerance_ns:
        fail("xctrace TOC duration differs from the declared duration")
    if _time_limit_ns(summary.findtext("time-limit", "")) != expected_duration_ns:
        fail("xctrace TOC time limit differs from the declared duration")
    tables = [table for table in run.findall("./data/table")
              if table.attrib.get("schema") == "thread-state"]
    expected_table = {
        "schema": "thread-state", "target-pid": "SINGLE",
        "documentation": "Determines that state of a thread during a given interval of time.",
    }
    if len(tables) != 1 or tables[0].attrib != expected_table:
        fail("xctrace TOC must contain exactly one target-pid=SINGLE thread-state table")
    return duration_ns


def _native_id(value: str, label: str) -> str:
    if re.fullmatch(r"[1-9][0-9]{0,18}", value) is None:
        fail(f"native {label} is not a canonical positive identifier")
    return value


class NativeReferences:
    def __init__(self, node: ET.Element):
        self.ids: dict[str, ET.Element] = {}
        for element in node.iter():
            if "id" in element.attrib:
                identifier = _native_id(element.attrib["id"], "id")
                if set(element.attrib) != {"id", "fmt"}:
                    fail("native thread-state definition has unsupported attributes")
                if identifier in self.ids:
                    fail("native thread-state export contains a duplicate id")
                self.ids[identifier] = element
            if element.tag == "sentinel" and (element.attrib or list(element)
                                               or (element.text or "").strip()):
                fail("native thread-state sentinel has unsupported payload")
        for element in node.iter():
            if "ref" in element.attrib:
                reference = _native_id(element.attrib["ref"], "ref")
                target = self.ids.get(reference)
                if target is None or target.tag != element.tag:
                    fail("native thread-state export contains a missing or wrong-tag ref")
                if set(element.attrib) != {"ref"} or list(element) or (element.text or "").strip():
                    fail("native thread-state ref has unsupported payload")
        self._validate_cycles()

    def _owned_refs(self, root: ET.Element) -> list[str]:
        refs: list[str] = []
        def visit(element: ET.Element) -> None:
            for child in element:
                if "ref" in child.attrib:
                    refs.append(child.attrib["ref"])
                elif "id" in child.attrib:
                    refs.append(child.attrib["id"])
                else:
                    visit(child)
        visit(root)
        return refs

    def _validate_cycles(self) -> None:
        graph = {identifier: self._owned_refs(element) for identifier, element in self.ids.items()}
        visiting: set[str] = set()
        visited: set[str] = set()
        def visit(identifier: str) -> None:
            if identifier in visiting:
                fail("native thread-state ref graph contains a cycle")
            if identifier in visited:
                return
            visiting.add(identifier)
            for target in graph[identifier]:
                visit(target)
            visiting.remove(identifier)
            visited.add(identifier)
        for identifier in graph:
            visit(identifier)

    def resolve(self, element: ET.Element) -> ET.Element:
        seen: set[str] = set()
        while "ref" in element.attrib:
            reference = element.attrib["ref"]
            if reference in seen:
                fail("native thread-state ref chain contains a cycle")
            seen.add(reference)
            element = self.ids[reference]
        return element

    def descendants(self, element: ET.Element, tag: str) -> list[ET.Element]:
        found: list[ET.Element] = []
        def visit(current: ET.Element) -> None:
            current = self.resolve(current)
            if current.tag == tag:
                found.append(current)
                return
            for child in current:
                visit(child)
        visit(element)
        return found


def _native_value(refs: NativeReferences, element: ET.Element, label: str,
                  *, maximum: int) -> int:
    resolved = refs.resolve(element)
    return _integer((resolved.text or "").strip(), label, maximum=maximum)


def _resolved_text(refs: NativeReferences, element: ET.Element, label: str) -> str:
    value = (refs.resolve(element).text or "").strip()
    if not value:
        fail(f"native {label} is empty")
    return value


def _process_pid(refs: NativeReferences, element: ET.Element, label: str) -> int:
    pids = refs.descendants(element, "pid")
    if len(pids) != 1:
        fail(f"native {label} does not resolve to exactly one PID")
    return _native_value(refs, pids[0], f"{label} PID", maximum=2**31 - 1)


def _validate_target_thread(refs: NativeReferences, element: ET.Element, expected_pid: int) -> None:
    tids = refs.descendants(element, "tid")
    processes = refs.descendants(element, "process")
    if len(tids) != 1 or len(processes) != 1 or _process_pid(refs, processes[0], "thread process") != expected_pid:
        fail("native target thread does not resolve to the captured PID")
    _native_value(refs, tids[0], "thread ID", maximum=2**63 - 1)


def normalize_native(toc: ET.Element, native: ET.Element, *, expected_pid: int,
                     expected_xcode_build: str, expected_duration_ns: int,
                     tolerance_ns: int) -> tuple[bytes, dict[str, Any]]:
    window_ns = parse_toc(toc, expected_pid=expected_pid,
                          expected_xcode_build=expected_xcode_build,
                          expected_duration_ns=expected_duration_ns, tolerance_ns=tolerance_ns)
    if native.tag != ROOT_TAG or native.attrib or len(native) != 1 or native[0].tag != "node":
        fail("native thread-state export has unsupported root shape")
    node = native[0]
    if set(node.attrib) != {"xpath"} or not re.fullmatch(
            r"//trace-toc\[1\]/run\[1\]/data\[1\]/table\[[1-9][0-9]*\]", node.attrib["xpath"]):
        fail("native thread-state export has unsupported node binding")
    if not list(node) or node[0].tag != "schema" or any(child.tag not in {"schema", "row"} for child in node):
        fail("native thread-state export has unsupported table shape")
    if sum(child.tag == "schema" for child in node) != 1:
        fail("native thread-state export must contain exactly one schema")
    schema = node[0]
    expected_schema_attrs = {
        "name": "thread-state",
        "documentation": "Determines that state of a thread during a given interval of time.",
    }
    if schema.attrib != expected_schema_attrs or len(schema) != len(NATIVE_COLUMNS):
        fail("native thread-state schema is unsupported")
    actual_columns = []
    for column in schema:
        if column.tag != "col" or column.attrib or [child.tag for child in column] != [
                "mnemonic", "name", "engineering-type"]:
            fail("native thread-state column shape is unsupported")
        if any(child.attrib or list(child) for child in column):
            fail("native thread-state column metadata is unsupported")
        actual_columns.append(tuple((child.text or "").strip() for child in column))
    if tuple(actual_columns) != NATIVE_COLUMNS:
        fail("native thread-state columns or engineering types drifted")
    rows = list(node)[1:]
    if not rows:
        fail("native thread-state export contains no rows")
    refs = NativeReferences(node)
    cpu_ns = 0
    wakeups = 0
    for row in rows:
        if row.tag != "row" or row.attrib or len(row) != len(NATIVE_COLUMNS):
            fail("native thread-state row shape is unsupported")
        for index, cell in enumerate(row):
            if cell.tag not in {NATIVE_CELL_TAGS[index], "sentinel"}:
                fail("native thread-state cell type drifted")
            if cell.tag != "sentinel" and not ({"id", "ref"} & set(cell.attrib)):
                fail("native thread-state cell has no typed definition or reference")
        if any(row[index].tag == "sentinel" for index in (0, 2, 3)):
            fail("native thread-state timing or state is missing")
        start_ns = _native_value(refs, row[0], "row start", maximum=MAX_NS)
        duration_ns = _native_value(refs, row[3], "row duration", maximum=MAX_NS)
        if duration_ns == 0:
            fail("native thread-state row duration must be positive")
        end_ns = start_ns + duration_ns
        if start_ns >= window_ns or end_ns <= 0:
            fail("native thread-state row is wholly outside the declared window")
        clipped_duration_ns = min(end_ns, window_ns) - start_ns
        if clipped_duration_ns <= 0 or clipped_duration_ns > window_ns:
            fail("native thread-state row has an invalid clipped interval")
        state = _resolved_text(refs, row[2], "thread state")
        if state not in KNOWN_STATES:
            fail("native thread-state export contains an unknown state")
        process_missing = row[4].tag == "sentinel"
        thread_missing = row[1].tag == "sentinel"
        if process_missing != thread_missing:
            fail("native thread-state row has inconsistent target identity")
        if process_missing:
            continue
        if _process_pid(refs, row[4], "process column") != expected_pid:
            fail("native process column does not match the captured PID")
        _validate_target_thread(refs, row[1], expected_pid)
        if state == "Running":
            if cpu_ns > MAX_CPU_NS - clipped_duration_ns:
                fail("aggregate target CPU running time exceeds its bound")
            cpu_ns += clipped_duration_ns
        if state == "Runnable" and start_ns < window_ns and row[11].tag != "sentinel":
            refs.resolve(row[11])
            if wakeups == MAX_WAKEUPS:
                fail("target wakeups count exceeds its bound")
            wakeups += 1
    normalized = ET.Element(ROOT_TAG, {"schema-version": "1", "xcode-build": expected_xcode_build})
    table = ET.SubElement(normalized, "table", {"name": TABLE_NAME, "unit": TABLE_UNIT})
    columns = ET.SubElement(table, "columns")
    for name, unit in COLUMNS:
        ET.SubElement(columns, "column", {"name": name, "unit": unit})
    output_rows = ET.SubElement(table, "rows")
    ET.SubElement(output_rows, "row", {
        "process-id": str(expected_pid), "window-start": "0", "window-end": str(window_ns),
        "cpu-running": str(cpu_ns), "wakeups": str(wakeups),
    })
    normalized_data = ET.tostring(normalized, encoding="utf-8", xml_declaration=True) + b"\n"
    metrics = parse_export(normalized_data, expected_xcode_build=expected_xcode_build,
                           expected_pid=expected_pid, expected_duration_ns=expected_duration_ns,
                           window_tolerance_ns=tolerance_ns)
    return normalized_data, metrics


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


def publish_outputs(outputs: list[tuple[pathlib.Path, bytes]], *, link=os.link) -> None:
    """Publish every output or remove every file created by this attempt."""
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


# Compatibility name retained for callers/tests of the transaction helper.
publish_json_pair = publish_outputs


def binding(args: argparse.Namespace) -> dict[str, Any]:
    values = {field: getattr(args, field) for field in
              ("run_id", "comparison_id", "artifact_role", "sample_kind", "sample_index", "scenario_id")}
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
    export_relative = validate_output_path(args.normalized_xml_out, run_dir)
    extraction_relative = validate_output_path(args.extraction_out, run_dir)
    summary_relative = validate_output_path(args.summary_out, run_dir)
    archive = pointer(args.trace_archive, run_dir)
    if (ARCHIVE_PATH_RE.fullmatch(archive["path"]) is None
            or EXPORT_PATH_RE.fullmatch(export_relative) is None
            or EXTRACTION_PATH_RE.fullmatch(extraction_relative) is None
            or summary_relative != SUMMARY_PATH):
        fail("idle inputs and outputs must use their closed opaque run-directory paths")
    native_paths = {args.toc_xml.resolve(), args.thread_state_xml.resolve()}
    published_paths = {args.trace_archive.resolve(), args.normalized_xml_out.resolve(),
                       args.extraction_out.resolve(), args.summary_out.resolve()}
    if len(native_paths) != 2 or native_paths & published_paths:
        fail("native XML inputs must be distinct private normalization inputs")
    if (args.toc_xml.resolve() != run_dir / ".xctrace-toc.xml"
            or args.thread_state_xml.resolve() != run_dir / ".xctrace-thread-state.xml"):
        fail("native XML inputs must use the closed private run-directory paths")
    normalized_data, metrics = normalize_native(
        _xml(args.toc_xml, "xctrace TOC"), _xml(args.thread_state_xml, "thread-state export"),
        expected_pid=args.expected_pid, expected_xcode_build=args.xcode_build,
        expected_duration_ns=args.duration_seconds * 1_000_000_000,
        tolerance_ns=args.window_tolerance_ms * 1_000_000,
    )
    normalized_pointer = {"path": export_relative,
                          "sha256": hashlib.sha256(normalized_data).hexdigest()}
    extraction = {
        "schema_version": 1,
        "tool": {"name": "labstream-xctrace-idle-summary", "version": "1"},
        "xcode_build": args.xcode_build,
        "table": {"name": TABLE_NAME, "unit": TABLE_UNIT,
                  "columns": [{"name": name, "unit": unit} for name, unit in COLUMNS]},
        "sources": {"trace_archive": archive, "source_export": normalized_pointer},
        "capture": {key: metrics[key] for key in
                    ("pid", "window_start_ns", "window_end_ns", "window_duration_ns")},
        "metrics": {key: metrics[key] for key in ("cpu_running_ns", "wakeups_count")},
    }
    extraction_data = json_bytes(extraction)
    extraction_pointer = {"path": extraction_relative,
                          "sha256": hashlib.sha256(extraction_data).hexdigest()}
    summary = {
        "schema_version": 1,
        "tool": {"name": "labstream-xctrace-idle-summary", "version": "1"},
        "binding": sample_binding,
        "sources": {"trace_archive": archive, "extraction": extraction_pointer},
        "capture": {"xcode_build": args.xcode_build, "pid": metrics["pid"],
                    "expected_duration_ns": args.duration_seconds * 1_000_000_000,
                    "window_tolerance_ns": args.window_tolerance_ms * 1_000_000,
                    "actual_duration_ns": metrics["window_duration_ns"]},
        "metrics": {key: metrics[key] for key in ("cpu_running_ns", "wakeups_count")},
    }
    publish_outputs([(args.normalized_xml_out, normalized_data),
                     (args.extraction_out, extraction_data),
                     (args.summary_out, json_bytes(summary))])


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toc-xml", required=True, type=pathlib.Path)
    parser.add_argument("--thread-state-xml", required=True, type=pathlib.Path)
    parser.add_argument("--normalized-xml-out", required=True, type=pathlib.Path)
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
