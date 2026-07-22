import hashlib
import importlib.util
import json
import pathlib
import stat
import struct
import sys
import tempfile
import unittest
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


def export_xml(*, build="17A456", pid=123, start=10_000_000_000,
               end=130_000_000_000, cpu=2_000_000_000, wakeups=42,
               columns=None):
    columns = columns or idle.COLUMNS
    column_xml = "".join(f'<column name="{name}" unit="{unit}"/>' for name, unit in columns)
    return (f'<trace-query-result schema-version="1" xcode-build="{build}">'
            f'<table name="{idle.TABLE_NAME}" unit="nanoseconds">'
            f'<columns>{column_xml}</columns><rows><row process-id="{pid}" '
            f'window-start="{start}" window-end="{end}" cpu-running="{cpu}" '
            f'wakeups="{wakeups}"/></rows></table></trace-query-result>').encode()


class IdleSummaryTests(unittest.TestCase):
    def test_parser_accepts_only_exact_pid_window_table_columns_and_units(self):
        parsed = idle.parse_export(export_xml(), expected_xcode_build="17A456", expected_pid=123,
                                   expected_duration_ns=120_000_000_000,
                                   window_tolerance_ns=0)
        self.assertEqual(parsed["cpu_running_ns"], 2_000_000_000)
        self.assertEqual(parsed["wakeups_count"], 42)
        self.assertEqual(parsed["window_duration_ns"], 120_000_000_000)

        cases = (
            (export_xml(build="17A457"), "Xcode build"),
            (export_xml(pid=124), "process ID"),
            (export_xml(end=129_000_000_000), "capture window"),
            (export_xml(cpu=121_000_000_000), "CPU running time"),
            (export_xml(columns=(("process-id", "count"),)), "columns"),
        )
        for value, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(idle.IdleSummaryError, message):
                idle.parse_export(value, expected_xcode_build="17A456", expected_pid=123,
                                  expected_duration_ns=120_000_000_000,
                                  window_tolerance_ns=0)

    def test_parser_rejects_multiple_rows_unknown_attributes_and_entities(self):
        multiple = export_xml().replace(b"</rows>",
                                        b'<row process-id="123" window-start="0" window-end="1" '
                                        b'cpu-running="0" wakeups="0"/></rows>')
        unknown = export_xml().replace(b'<row process-id=', b'<row process-name="private" process-id=')
        entity = b'<!DOCTYPE x [<!ENTITY secret "private">]>' + export_xml()
        for value in (multiple, unknown, entity):
            with self.subTest(value=value[:30]), self.assertRaises(idle.IdleSummaryError):
                idle.parse_export(value, expected_xcode_build="17A456", expected_pid=123,
                                  expected_duration_ns=120_000_000_000,
                                  window_tolerance_ns=0)

    def _write_outputs(self, root: pathlib.Path):
        raw = root / "raw"
        raw.mkdir()
        archive = raw / "artifact-0001.trace.zip"
        source = raw / "artifact-0002.xml"
        extraction = raw / "artifact-0003.json"
        summary = root / "summary/redacted.json"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            member = zipfile.ZipInfo("sample.trace/private-data")
            member.external_attr = (stat.S_IFREG | 0o600) << 16
            output.writestr(member, b"private trace archive")
        source.write_bytes(export_xml())
        result = idle.main([
            "--input-xml", str(source), "--trace-archive", str(archive),
            "--run-dir", str(root), "--extraction-out", str(extraction),
            "--summary-out", str(summary), "--xcode-build", "17A456",
            "--expected-pid", "123", "--duration-seconds", "120",
            "--window-tolerance-ms", "0", "--run-id", "run-0123456789ab",
            "--comparison-id", "comparison-0123456789ab", "--artifact-role", "control",
            "--sample-kind", "measured", "--sample-index", "0",
            "--scenario-id", "scenario-0123456789ab",
        ])
        self.assertEqual(result, 0)
        return archive, source, extraction, summary

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
                        "platform": "macos", "os_build": "25A123", "xcode_build": "17A456"},
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
                "cpu_running_ns": 2_000_000_000, "wakeups_count": 42,
            })
            self.assertNotIn("private trace archive", files[-1].read_text())
            self.assertEqual(extraction["sources"]["trace_archive"]["path"],
                             "raw/artifact-0001.trace.zip")
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
            extraction["xcode_build"] = "17A999"
            extraction_path.write_text(json.dumps(extraction))
            manifest["evidence"]["artifacts"][2] = self._pointer(extraction_path, root)
            summary_path = files[-1]
            summary = json.loads(summary_path.read_text())
            summary["sources"]["extraction"] = manifest["evidence"]["artifacts"][2]
            summary_path.write_text(json.dumps(summary))
            manifest["evidence"]["redacted_summary"] = self._pointer(summary_path, root)
            with self.assertRaisesRegex(contract.ContractError, "Xcode build"):
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
            # A DEFLATE block type of binary 11 is reserved and must make zlib reject the stream.
            raw[compressed_offset] = (raw[compressed_offset] & 0xF8) | 0x07
            archive.write_bytes(raw)
            with self.assertRaisesRegex(contract.ContractError, "readable ZIP") as caught:
                contract.validate_trace_archive(archive)
            self.assertIsInstance(caught.exception.__cause__, zlib.error)

    def test_pair_publication_cleans_both_outputs_when_second_link_fails_then_retries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            first = root / "raw/artifact-0003.json"
            second = root / "summary/redacted.json"
            calls = 0

            def fail_second(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("deterministic second-link failure")
                return __import__("os").link(source, destination)

            with self.assertRaisesRegex(OSError, "second-link"):
                idle.publish_json_pair([(first, b"first\n"), (second, b"second\n")],
                                       link=fail_second)
            self.assertFalse(first.exists())
            self.assertFalse(second.exists())
            self.assertEqual(list(root.rglob("*.idle-tmp-*")), [])

            idle.publish_json_pair([(first, b"first\n"), (second, b"second\n")])
            self.assertEqual(first.read_bytes(), b"first\n")
            self.assertEqual(second.read_bytes(), b"second\n")

    def test_invalid_binding_fails_before_any_output_is_written(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            raw = root / "raw"
            raw.mkdir()
            archive = raw / "artifact-0001.trace.zip"
            source = raw / "artifact-0002.xml"
            with zipfile.ZipFile(archive, "w") as output:
                member = zipfile.ZipInfo("sample.trace/data")
                member.external_attr = (stat.S_IFREG | 0o600) << 16
                output.writestr(member, b"trace")
            source.write_bytes(export_xml())
            extraction = raw / "artifact-0003.json"
            summary = root / "summary/redacted.json"
            arguments = [
                "--input-xml", str(source), "--trace-archive", str(archive),
                "--run-dir", str(root), "--extraction-out", str(extraction),
                "--summary-out", str(summary), "--xcode-build", "17A456",
                "--expected-pid", "123", "--duration-seconds", "120",
                "--run-id", "invalid", "--comparison-id", "comparison-0123456789ab",
                "--artifact-role", "control", "--sample-kind", "measured",
                "--sample-index", "0", "--scenario-id", "scenario-0123456789ab",
            ]
            with self.assertRaisesRegex(idle.IdleSummaryError, "run_id"):
                idle.main(arguments)
            self.assertFalse(extraction.exists())
            self.assertFalse(summary.exists())

            arguments[arguments.index("invalid")] = "run-0123456789ab"
            wrong_summary = root / "summary/wrong.json"
            arguments[arguments.index(str(summary))] = str(wrong_summary)
            with self.assertRaisesRegex(idle.IdleSummaryError, "closed opaque"):
                idle.main(arguments)
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
