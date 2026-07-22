import hashlib
import importlib.util
import json
import pathlib
import stat
import struct
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-xctrace-idle-summary.py"
spec = importlib.util.spec_from_file_location("perf_xctrace_idle_summary", SCRIPT)
idle = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = idle
spec.loader.exec_module(idle)
CONTRACT = SCRIPT.parent / "performance-audit-contract.py"
contract_spec = importlib.util.spec_from_file_location("performance_contract_for_idle", CONTRACT)
contract = importlib.util.module_from_spec(contract_spec)
sys.modules[contract_spec.name] = contract
contract_spec.loader.exec_module(contract)

BUILD = "27A5218g"
PID = 123
DURATION_NS = 1_000_000_000
DOCUMENTATION = "Determines that state of a thread during a given interval of time."


def normalized_xml(*, build=BUILD, pid=PID, start=0, end=DURATION_NS,
                   cpu=650_000_000, wakeups=1, columns=None):
    columns = columns or idle.COLUMNS
    column_xml = "".join(f'<column name="{name}" unit="{unit}"/>' for name, unit in columns)
    return (f'<trace-query-result schema-version="1" xcode-build="{build}">'
            f'<table name="{idle.TABLE_NAME}" unit="nanoseconds">'
            f'<columns>{column_xml}</columns><rows><row process-id="{pid}" '
            f'window-start="{start}" window-end="{end}" cpu-running="{cpu}" '
            f'wakeups="{wakeups}"/></rows></table></trace-query-result>').encode()


def toc_xml(*, build=BUILD, pid=PID, duration="1.000000", target_pid="SINGLE",
            second_attached=False):
    extra = f'<process type="attached" pid="{pid + 1}"/>' if second_attached else ""
    return (f'<trace-toc><run number="1"><info><target>'
            f'<process type="attached" name="Labstream" pid="{pid}"/>{extra}'
            f'</target><summary><duration>{duration}</duration>'
            f'<instruments-version>27.0 ({build})</instruments-version>'
            f'<template-name>System Trace</template-name><time-limit>1 second</time-limit>'
            f'</summary></info><data><table schema="thread-state" target-pid="{target_pid}" '
            f'documentation="{DOCUMENTATION}"/></data></run></trace-toc>').encode()


def _sentinels(count):
    return "<sentinel/>" * count


def _row(*, start, duration, state, thread, process, made="<sentinel/>", suffix):
    return (f'<row><start-time id="{suffix}01" fmt="{start}">{start}</start-time>{thread}{state}'
            f'<duration id="{suffix}02" fmt="{duration}">{duration}</duration>{process}'
            f'{_sentinels(6)}{made}{_sentinels(4)}</row>')


def thread_state_xml(*, pid=PID, unknown_state=False, overflow=False,
                     schema_override=None):
    schema_columns = idle.NATIVE_COLUMNS if schema_override is None else schema_override
    columns = "".join(
        f'<col><mnemonic>{mnemonic}</mnemonic><name>{name}</name>'
        f'<engineering-type>{engineering}</engineering-type></col>'
        for mnemonic, name, engineering in schema_columns
    )
    running = "Mystery" if unknown_state else "Running"
    last_start = 900_000_000 if overflow else 750_000_000
    rows = [
        _row(
            start=0, duration=400_000_000,
            thread=('<thread id="10" fmt="main"><tid id="11" fmt="1001">1001</tid>'
                    '<process ref="20"/></thread>'),
            state=f'<thread-state id="30" fmt="{running}">{running}</thread-state>',
            process=(f'<process id="20" fmt="Labstream ({pid})"><pid id="21" fmt="{pid}">{pid}</pid>'
                     '<device-session id="22" fmt="TODO">TODO</device-session></process>'),
            suffix="10",
        ),
        _row(
            start=400_000_000, duration=200_000_000,
            thread='<thread ref="10"/>', state='<thread-state id="31" fmt="Runnable">Runnable</thread-state>',
            process='<process ref="20"/>', made='<thread ref="10"/>', suffix="20",
        ),
        _row(
            start=600_000_000, duration=100_000_000,
            thread='<thread ref="10"/>', state='<thread-state ref="31"/>',
            process='<process ref="20"/>', suffix="30",
        ),
        _row(
            start=700_000_000, duration=300_000_000,
            thread='<sentinel/>', state='<thread-state id="32" fmt="Idle">Idle</thread-state>',
            process='<sentinel/>', suffix="40",
        ),
        _row(
            start=last_start, duration=250_000_000,
            thread='<thread ref="10"/>', state='<thread-state ref="30"/>',
            process='<process ref="20"/>', suffix="50",
        ),
    ]
    return (f'<trace-query-result><node xpath="//trace-toc[1]/run[1]/data[1]/table[58]">'
            f'<schema name="thread-state" documentation="{DOCUMENTATION}">{columns}</schema>'
            f'{"".join(rows)}</node></trace-query-result>').encode()


class IdleSummaryTests(unittest.TestCase):
    def test_native_normalizer_sums_running_intervals_and_counts_runnable_provenance(self):
        normalized, metrics = idle.normalize_native(
            ET.fromstring(toc_xml()), ET.fromstring(thread_state_xml()), expected_pid=PID,
            expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS, tolerance_ns=0,
        )
        # CPU is the sum of the two target-process Running row durations. Wakeups count only
        # target Runnable rows whose made-runnable-by-thread column is non-sentinel.
        self.assertEqual(metrics["cpu_running_ns"], 650_000_000)
        self.assertEqual(metrics["wakeups_count"], 1)
        self.assertEqual(metrics["window_duration_ns"], DURATION_NS)
        self.assertEqual(
            idle.parse_export(normalized, expected_xcode_build=BUILD, expected_pid=PID,
                              expected_duration_ns=DURATION_NS, window_tolerance_ns=0), metrics,
        )

    def test_normalized_parser_accepts_only_closed_table_and_binding(self):
        parsed = idle.parse_export(
            normalized_xml(), expected_xcode_build=BUILD, expected_pid=PID,
            expected_duration_ns=DURATION_NS, window_tolerance_ns=0,
        )
        self.assertEqual(parsed["cpu_running_ns"], 650_000_000)
        self.assertEqual(parsed["wakeups_count"], 1)

        cases = (
            (normalized_xml(build="27A5218h"), "Xcode build"),
            (normalized_xml(pid=PID + 1), "process ID"),
            (normalized_xml(end=DURATION_NS - 1), "capture window"),
            (normalized_xml(columns=(("process-id", "count"),)), "columns"),
            (normalized_xml().replace(b"</rows>",
                                      b'<row process-id="123" window-start="0" window-end="1" '
                                      b'cpu-running="0" wakeups="0"/></rows>'), "shape"),
            (b'<!DOCTYPE x [<!ENTITY secret "private">]>' + normalized_xml(), "DTD"),
        )
        for value, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(idle.IdleSummaryError, message):
                idle.parse_export(value, expected_xcode_build=BUILD, expected_pid=PID,
                                  expected_duration_ns=DURATION_NS, window_tolerance_ns=0)

    def test_native_normalizer_rejects_toc_build_pid_target_and_schema_drift(self):
        drifted_schema = list(idle.NATIVE_COLUMNS)
        drifted_schema[3] = ("duration", "Duration", "time")
        cases = (
            (toc_xml(build="27A5218h"), thread_state_xml(), "Xcode build"),
            (toc_xml(pid=PID + 1), thread_state_xml(), "attached target"),
            (toc_xml(second_attached=True), thread_state_xml(), "exactly one attached"),
            (toc_xml(target_pid="ALL"), thread_state_xml(), "target-pid=SINGLE"),
            (toc_xml(), thread_state_xml(pid=PID + 1), "process column"),
            (toc_xml(), thread_state_xml(schema_override=drifted_schema), "engineering types"),
        )
        for toc, native, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(idle.IdleSummaryError, message):
                idle.normalize_native(
                    ET.fromstring(toc), ET.fromstring(native), expected_pid=PID,
                    expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS, tolerance_ns=0,
                )

    def test_native_normalizer_rejects_missing_wrong_tag_and_cyclic_refs(self):
        base = thread_state_xml()
        missing = base.replace(b'<process ref="20"/>', b'<process ref="999"/>', 1)
        wrong_tag = base.replace(b'<process ref="20"/>', b'<process ref="10"/>', 1)
        cyclic = base.replace(
            b'<sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><thread ref="10"/>',
            b'<sentinel/><sentinel/><sentinel/><sentinel/>'
            b'<narrative id="80" fmt="a"><narrative ref="81"/></narrative>'
            b'<narrative id="81" fmt="b"><narrative ref="80"/></narrative><thread ref="10"/>',
            1,
        )
        for native, message in (
                (missing, "missing or wrong-tag ref"),
                (wrong_tag, "missing or wrong-tag ref"),
                (cyclic, "cycle")):
            with self.subTest(message=message), self.assertRaisesRegex(idle.IdleSummaryError, message):
                idle.normalize_native(
                    ET.fromstring(toc_xml()), ET.fromstring(native), expected_pid=PID,
                    expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS, tolerance_ns=0,
                )

    def test_native_normalizer_rejects_unknown_state_and_invalid_timing(self):
        zero_duration = thread_state_xml().replace(
            b'<duration id="5002" fmt="250000000">250000000</duration>',
            b'<duration id="5002" fmt="0">0</duration>',
        )
        negative_start = thread_state_xml().replace(
            b'<start-time id="5001" fmt="750000000">750000000</start-time>',
            b'<start-time id="5001" fmt="-1">-1</start-time>',
        )
        overflow_duration = thread_state_xml().replace(
            b'<duration id="5002" fmt="250000000">250000000</duration>',
            b'<duration id="5002" fmt="overflow">999999999999999999999</duration>',
        )
        for native, message in (
                (thread_state_xml(unknown_state=True), "unknown state"),
                (zero_duration, "positive"),
                (negative_start, "canonical nonnegative"),
                (overflow_duration, "canonical nonnegative")):
            with self.subTest(message=message), self.assertRaisesRegex(idle.IdleSummaryError, message):
                idle.normalize_native(
                    ET.fromstring(toc_xml()), ET.fromstring(native), expected_pid=PID,
                    expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS, tolerance_ns=0,
                )

        after_actual_window = thread_state_xml().replace(
            b'<start-time id="5001" fmt="750000000">750000000</start-time>',
            b'<start-time id="5001" fmt="1500000000">1500000000</start-time>',
        )
        with self.assertRaisesRegex(idle.IdleSummaryError, "declared window"):
            idle.normalize_native(
                ET.fromstring(toc_xml(duration="1.500000")),
                ET.fromstring(after_actual_window), expected_pid=PID,
                expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS,
                tolerance_ns=500_000_000,
            )

    def test_native_normalizer_clips_boundary_crossing_rows_but_rejects_wholly_outside(self):
        crossing = thread_state_xml().replace(
            b'<duration id="5002" fmt="250000000">250000000</duration>',
            b'<duration id="5002" fmt="500000000">500000000</duration>',
        ).replace(
            b'<duration id="4002" fmt="300000000">300000000</duration>',
            b'<duration id="4002" fmt="600000000">600000000</duration>',
        )
        _, metrics = idle.normalize_native(
            ET.fromstring(toc_xml()), ET.fromstring(crossing), expected_pid=PID,
            expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS, tolerance_ns=0,
        )
        # The final Running row is [750ms, 1250ms), so only 250ms contributes.
        # The sentinel Idle row also crosses the boundary and is accepted but contributes nothing.
        self.assertEqual(metrics["cpu_running_ns"], 650_000_000)
        self.assertEqual(metrics["wakeups_count"], 1)
        self.assertEqual(metrics["window_end_ns"], DURATION_NS)

        wholly_outside = thread_state_xml().replace(
            b'<start-time id="5001" fmt="750000000">750000000</start-time>',
            b'<start-time id="5001" fmt="1000000000">1000000000</start-time>',
        )
        with self.assertRaisesRegex(idle.IdleSummaryError, "wholly outside"):
            idle.normalize_native(
                ET.fromstring(toc_xml()), ET.fromstring(wholly_outside), expected_pid=PID,
                expected_xcode_build=BUILD, expected_duration_ns=DURATION_NS, tolerance_ns=0,
            )

    def _write_outputs(self, root: pathlib.Path):
        raw = root / "raw"
        raw.mkdir()
        archive = raw / "artifact-0001.trace.zip"
        normalized = raw / "artifact-0002.xml"
        extraction = raw / "artifact-0003.json"
        summary = root / "summary/redacted.json"
        toc = root / ".xctrace-toc.xml"
        native = root / ".xctrace-thread-state.xml"
        toc.write_bytes(toc_xml())
        native.write_bytes(thread_state_xml())
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            member = zipfile.ZipInfo("sample.trace/private-data")
            member.external_attr = (stat.S_IFREG | 0o600) << 16
            output.writestr(member, b"private trace archive")
        result = idle.main([
            "--toc-xml", str(toc), "--thread-state-xml", str(native),
            "--normalized-xml-out", str(normalized), "--trace-archive", str(archive),
            "--run-dir", str(root), "--extraction-out", str(extraction),
            "--summary-out", str(summary), "--xcode-build", BUILD,
            "--expected-pid", str(PID), "--duration-seconds", "1",
            "--window-tolerance-ms", "0", "--run-id", "run-0123456789ab",
            "--comparison-id", "comparison-0123456789ab", "--artifact-role", "control",
            "--sample-kind", "measured", "--sample-index", "0",
            "--scenario-id", "scenario-0123456789ab",
        ])
        self.assertEqual(result, 0)
        return archive, normalized, extraction, summary

    @staticmethod
    def _pointer(path: pathlib.Path, root: pathlib.Path):
        return {"path": path.relative_to(root).as_posix(),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    def _manifest(self, root, files):
        archive, source, extraction, summary = files
        return {
            "schema_version": 1,
            "tool": {"name": "labstream-performance-audit", "version": "1"},
            "run": {"id": "run-0123456789ab", "recorded_at": "2026-07-23T00:00:00Z",
                    "comparison_id": "comparison-0123456789ab", "artifact_role": "control",
                    "sample_kind": "measured", "sample_index": 0,
                    "order_seed": "seed-0123456789abcdef"},
            "product": {"commit": "a" * 40, "sha256": "b" * 64,
                        "configuration": "PerformanceAudit", "target": "LabstreamMac",
                        "platform": "macos", "os_build": "25A123", "xcode_build": BUILD},
            "device": {"label": "local-device-01", "power_source": "external",
                       "battery_state": "full", "thermal_state": "nominal",
                       "free_storage_bytes": 1_000_000, "display_mode": "windowed"},
            "state": {"install_state": "direct_staged_artifact",
                      "container_state": "restored_fixture",
                      "cache_reset": {"command_id": "fixture-cache-seed-v1", "result": "success"}},
            "scenario": {"id": "scenario-0123456789ab", "category": "idle",
                         "run_kind": "deterministic_fixture",
                         "fixture_id": "fixture-0123456789ab", "fixture_sha256": "c" * 64,
                         "backend_kind": "none", "server_version": None,
                         "cache_state": "declared_seed"},
            "launch_contract": {"arguments": [], "environment_keys": [],
                                "ui_test_fixture": False, "live_probe": False,
                                "tv_event_swizzle": False, "verbose_debug_evidence": False},
            "evidence": {
                "artifacts": [self._pointer(path, root) for path in (archive, source, extraction)],
                "redacted_summary": self._pointer(summary, root),
                "privacy_review": "pending", "retention_deadline": "2099-08-21T00:00:00Z",
                "publishable": False,
            },
        }

    def test_outputs_are_typed_private_and_contract_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            files = self._write_outputs(root)
            summary = json.loads(files[-1].read_text())
            extraction = json.loads(files[-2].read_text())
            self.assertEqual(summary["metrics"], {
                "cpu_running_ns": 650_000_000, "wakeups_count": 1,
            })
            self.assertNotIn("private trace archive", files[-1].read_text())
            self.assertEqual(extraction["sources"]["trace_archive"]["path"],
                             "raw/artifact-0001.trace.zip")
            self.assertEqual(extraction["sources"]["source_export"]["path"],
                             "raw/artifact-0002.xml")
            contract.validate_manifest(self._manifest(root, files), root)

    def test_output_collision_and_escape_fail_before_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            files = self._write_outputs(root)
            before = files[-2].read_bytes()
            with self.assertRaisesRegex(idle.IdleSummaryError, "must not already exist"):
                idle.validate_output_path(files[-2], root)
            self.assertEqual(files[-2].read_bytes(), before)
            outside = root.parent / "idle-summary-escape.json"
            try:
                with self.assertRaisesRegex(idle.IdleSummaryError, "inside the run directory"):
                    idle.validate_output_path(outside, root)
            finally:
                outside.unlink(missing_ok=True)

    def test_contract_rejects_summary_extraction_and_source_binding_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            files = self._write_outputs(root)
            manifest = self._manifest(root, files)
            summary_path = files[-1]
            summary = json.loads(summary_path.read_text())
            summary["metrics"]["wakeups_count"] += 1
            summary_path.write_text(json.dumps(summary))
            manifest["evidence"]["redacted_summary"] = self._pointer(summary_path, root)
            with self.assertRaisesRegex(contract.ContractError, "metrics do not match"):
                contract.validate_manifest(manifest, root)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            files = self._write_outputs(root)
            manifest = self._manifest(root, files)
            extraction_path = files[-2]
            extraction = json.loads(extraction_path.read_text())
            extraction["xcode_build"] = "27A5218h"
            extraction_path.write_text(json.dumps(extraction))
            manifest["evidence"]["artifacts"][2] = self._pointer(extraction_path, root)
            summary_path = files[-1]
            summary = json.loads(summary_path.read_text())
            summary["sources"]["extraction"] = manifest["evidence"]["artifacts"][2]
            summary_path.write_text(json.dumps(summary))
            manifest["evidence"]["redacted_summary"] = self._pointer(summary_path, root)
            with self.assertRaisesRegex(contract.ContractError, "Xcode build"):
                contract.validate_manifest(manifest, root)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            files = self._write_outputs(root)
            manifest = self._manifest(root, files)
            normalized_path = files[1]
            normalized_path.write_bytes(normalized_path.read_bytes().replace(
                b'cpu-running="650000000"', b'cpu-running="650000001"'))
            manifest["evidence"]["artifacts"][1] = self._pointer(normalized_path, root)
            extraction_path = files[2]
            extraction = json.loads(extraction_path.read_text())
            extraction["sources"]["source_export"] = manifest["evidence"]["artifacts"][1]
            extraction_path.write_text(json.dumps(extraction))
            manifest["evidence"]["artifacts"][2] = self._pointer(extraction_path, root)
            summary_path = files[3]
            summary = json.loads(summary_path.read_text())
            summary["sources"]["extraction"] = manifest["evidence"]["artifacts"][2]
            summary_path.write_text(json.dumps(summary))
            manifest["evidence"]["redacted_summary"] = self._pointer(summary_path, root)
            with self.assertRaisesRegex(contract.ContractError, "cpu-running"):
                contract.validate_manifest(manifest, root)

    def test_idle_trace_manifest_cannot_be_marked_publishable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            files = self._write_outputs(root)
            manifest = self._manifest(root, files)
            manifest["evidence"]["privacy_review"] = "reviewed"
            manifest["evidence"]["publishable"] = True
            with self.assertRaisesRegex(contract.ContractError, "local and non-publishable"):
                contract.validate_manifest(manifest, root, verify_files=False)

    def test_trace_archive_rejects_traversal_and_symlink_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for name, mode in (("../escape", stat.S_IFREG | 0o600),
                               ("sample.trace/link", stat.S_IFLNK | 0o777)):
                archive = root / "sample.zip"
                with zipfile.ZipFile(archive, "w") as output:
                    member = zipfile.ZipInfo(name)
                    member.external_attr = mode << 16
                    output.writestr(member, b"value")
                with self.subTest(name=name), self.assertRaises(contract.ContractError):
                    contract.validate_trace_archive(archive)
                archive.unlink()

    def test_trace_archive_streams_every_member_and_rejects_bad_crc(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = pathlib.Path(temporary) / "sample.zip"
            payload = b"unique-streamed-trace-payload"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as output:
                member = zipfile.ZipInfo("sample.trace/data")
                member.external_attr = (stat.S_IFREG | 0o600) << 16
                output.writestr(member, payload)
            damaged = bytearray(archive.read_bytes())
            offset = damaged.index(payload)
            damaged[offset] ^= 0x01
            archive.write_bytes(damaged)
            with self.assertRaisesRegex(contract.ContractError, "readable ZIP"):
                contract.validate_trace_archive(archive)

    def test_trace_archive_normalizes_deflate_stream_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = pathlib.Path(temporary) / "sample.zip"
            payload = bytes(range(256)) * 100
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
                member = zipfile.ZipInfo("sample.trace/data")
                member.compress_type = zipfile.ZIP_DEFLATED
                member.external_attr = (stat.S_IFREG | 0o600) << 16
                output.writestr(member, payload)
            with zipfile.ZipFile(archive) as source:
                info = source.infolist()[0]
                self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
                self.assertLess(info.compress_size, info.file_size)
                raw = bytearray(archive.read_bytes())
                name_length, extra_length = struct.unpack_from("<HH", raw, info.header_offset + 26)
                compressed_offset = info.header_offset + 30 + name_length + extra_length
            raw[compressed_offset] = (raw[compressed_offset] & 0xF8) | 0x07
            archive.write_bytes(raw)
            with self.assertRaisesRegex(contract.ContractError, "readable ZIP") as caught:
                contract.validate_trace_archive(archive)
            self.assertIsInstance(caught.exception.__cause__, zlib.error)

    def test_output_transaction_cleans_all_outputs_when_second_link_fails_then_retries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            outputs = [(root / "raw/artifact-0002.xml", b"xml\n"),
                       (root / "raw/artifact-0003.json", b"extraction\n"),
                       (root / "summary/redacted.json", b"summary\n")]
            calls = 0

            def fail_second(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("deterministic second-link failure")
                return __import__("os").link(source, destination)

            with self.assertRaisesRegex(OSError, "second-link"):
                idle.publish_outputs(outputs, link=fail_second)
            self.assertTrue(all(not path.exists() for path, _ in outputs))
            self.assertEqual(list(root.rglob("*.idle-tmp-*")), [])

            idle.publish_outputs(outputs)
            self.assertEqual([path.read_bytes() for path, _ in outputs],
                             [data for _, data in outputs])

    def test_invalid_binding_fails_before_any_output_is_written(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            raw = root / "raw"
            raw.mkdir()
            archive = raw / "artifact-0001.trace.zip"
            with zipfile.ZipFile(archive, "w") as output:
                member = zipfile.ZipInfo("sample.trace/data")
                member.external_attr = (stat.S_IFREG | 0o600) << 16
                output.writestr(member, b"trace")
            toc = root / ".xctrace-toc.xml"
            native = root / ".xctrace-thread-state.xml"
            toc.write_bytes(toc_xml())
            native.write_bytes(thread_state_xml())
            normalized = raw / "artifact-0002.xml"
            extraction = raw / "artifact-0003.json"
            summary = root / "summary/redacted.json"
            arguments = [
                "--toc-xml", str(toc), "--thread-state-xml", str(native),
                "--normalized-xml-out", str(normalized), "--trace-archive", str(archive),
                "--run-dir", str(root), "--extraction-out", str(extraction),
                "--summary-out", str(summary), "--xcode-build", BUILD,
                "--expected-pid", str(PID), "--duration-seconds", "1",
                "--run-id", "invalid", "--comparison-id", "comparison-0123456789ab",
                "--artifact-role", "control", "--sample-kind", "measured",
                "--sample-index", "0", "--scenario-id", "scenario-0123456789ab",
            ]
            with self.assertRaisesRegex(idle.IdleSummaryError, "run_id"):
                idle.main(arguments)
            self.assertFalse(normalized.exists())
            self.assertFalse(extraction.exists())
            self.assertFalse(summary.exists())

            arguments[arguments.index("invalid")] = "run-0123456789ab"
            wrong_summary = root / "summary/wrong.json"
            arguments[arguments.index(str(summary))] = str(wrong_summary)
            with self.assertRaisesRegex(idle.IdleSummaryError, "closed opaque"):
                idle.main(arguments)
            self.assertFalse(normalized.exists())
            self.assertFalse(extraction.exists())
            self.assertFalse(wrong_summary.exists())

    def test_schema_and_runtime_contract_accept_honest_idle_artifact_paths(self):
        schema = json.loads((SCRIPT.parent / "schemas/performance-audit-manifest-v1.schema.json").read_text())
        categories = schema["$defs"]["scenario"]["properties"]["category"]["enum"]
        pattern = schema["$defs"]["rawArtifactPath"]["pattern"]
        self.assertIn("idle", categories)
        self.assertRegex("raw/artifact-0001.trace.zip", pattern)
        self.assertRegex("raw/artifact-0002.xml", pattern)
        self.assertRegex("raw/artifact-0003.json", pattern)
        self.assertRegex("raw/artifact-0001.trace.zip", contract.RAW_ARTIFACT_PATH_RE)
        idle_rule = schema["allOf"][0]
        self.assertEqual(idle_rule["if"]["properties"]["scenario"]["properties"]
                         ["category"]["const"], "idle")
        self.assertIs(idle_rule["then"]["properties"]["evidence"]["properties"]
                      ["publishable"]["const"], False)


if __name__ == "__main__":
    unittest.main()
