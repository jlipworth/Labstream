import io
import contextlib
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-log-summary.py"
spec = importlib.util.spec_from_file_location("perf_log_summary", SCRIPT)
perf = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = perf
spec.loader.exec_module(perf)


class PerfLogSummaryTests(unittest.TestCase):
    def test_parse_plain_and_json_records(self):
        plain = perf.parse_span_line(
            "2026 perf.span phase=home.load backend=Plex result=success duration_ms=123 item_count=12"
        )
        encoded = perf.parse_span_line(
            '{"eventMessage":"perf.span phase=playback.startup backend=Jellyfin result=success duration_ms=20 path_mode=remote_stream"}'
        )
        self.assertEqual(plain.duration_ms, 123)
        self.assertEqual(plain.fields, {"item_count": "12"})
        self.assertEqual(encoded.fields["path_mode"], "remote_stream")

    def test_current_nonterminal_results_are_known(self):
        for result in ("superseded", "orphaned"):
            with self.subTest(result=result):
                span = perf.parse_span_line(
                    f"perf.span phase=playback.item_load backend=Plex result={result} duration_ms=1 path_mode=plex_stream"
                )
                self.assertEqual(span.result, result)

    def test_current_home_and_detail_fields_match_closed_schema(self):
        home = perf.parse_span_line(
            "perf.span phase=home.load backend=Jellyfin result=success duration_ms=10 "
            "view_count=2 rail_count=3 pending_rail_count=1 item_count=9 degraded=1"
        )
        detail = perf.parse_span_line(
            "perf.span phase=detail.metadata backend=Emby result=success duration_ms=8 "
            "media_count=2 swr_refresh=1"
        )

        self.assertEqual(home.fields["pending_rail_count"], "1")
        self.assertEqual(detail.fields["swr_refresh"], "1")
        self.assertEqual(perf.parse_span_line_diagnostic(
            "perf.span phase=detail.metadata backend=Emby result=success duration_ms=8 "
            "media_count=2 swr_refresh=true"
        )[1], "invalid_boolean_field")

    def test_browse_and_artwork_measurement_fields_are_closed(self):
        records = (
            ("perf.span phase=home.first_content backend=Emby result=success duration_ms=4 "
             "content_present=1 rail_count=1 item_count=8 publication_count=1", "home.first_content"),
            ("perf.span phase=search.load backend=Plex result=success duration_ms=5 "
             "group_count=2 item_count=9 publication_count=1", "search.load"),
            ("perf.span phase=library_grid.first_content backend=Jellyfin result=success duration_ms=6 "
             "item_count=200 total_count=10000 page_count=1 publication_count=1 collapse_mode=collapsed",
             "library_grid.first_content"),
            ("perf.span phase=library_grid.complete backend=Jellyfin result=success duration_ms=20 "
             "item_count=9500 total_count=10000 page_count=50 publication_count=51 collapse_mode=collapsed",
             "library_grid.complete"),
            ("perf.span phase=library_grid.page backend=Plex result=success duration_ms=7 "
             "item_count=200 page=3 page_size=200 attempt=1", "library_grid.page"),
            ("perf.span phase=artwork.load backend=Emby result=success duration_ms=8 attempts=1 bytes=100 "
             "status=200 width=100 height=150 pixel_width=200 pixel_height=300 delivery=inflight_join "
             "scoped=1 milestone=library_first_poster",
             "artwork.load"),
        )
        for line, phase in records:
            with self.subTest(phase=phase):
                parsed = perf.parse_span_line(line)
                self.assertEqual(parsed.phase, phase)

        self.assertEqual(perf.parse_span_line_diagnostic(
            "perf.span phase=artwork.load backend=Emby result=success duration_ms=8 "
            "attempts=1 bytes=100 status=200 width=100 height=150 pixel_width=200 pixel_height=300 "
            "delivery=memory_magic"
        )[1], "invalid_enum_field")

        # Publication completion order is diagnostic only and must not be correctness-signed.
        self.assertEqual(
            perf.evidence_schema.validate_correctness_fields(
                "home.load", "Plex", ["hub_count", "item_count"]
            ),
            ("hub_count", "item_count"),
        )
        with self.assertRaisesRegex(ValueError, "correctness_fields_must_match"):
            perf.evidence_schema.validate_correctness_fields(
                "home.load", "Plex", ["hub_count", "item_count", "publication_count"]
            )
        self.assertEqual(
            perf.evidence_schema.validate_correctness_fields(
                "home.first_content", "Emby", ["content_present"]
            ),
            ("content_present",),
        )
        self.assertEqual(perf.parse_span_line_diagnostic(
            "perf.span phase=home.first_content backend=Emby result=success duration_ms=4 "
            "content_present=2 rail_count=1 item_count=8 publication_count=1"
        )[1], "invalid_boolean_field")

    def test_launch_spans_use_closed_backend_and_correctness_fields(self):
        composition = perf.parse_span_line(
            "perf.span phase=runtime.composition backend=App result=success duration_ms=4 "
            "downloads_capable=1"
        )
        download_manager = perf.parse_span_line(
            "perf.span phase=runtime.download_manager backend=App result=success duration_ms=3 "
            "background_events=1"
        )
        download_store = perf.parse_span_line(
            "perf.span phase=runtime.download_store backend=App result=success duration_ms=2 "
            "default_store=1"
        )
        restore = perf.parse_span_line(
            "perf.span phase=session.restore backend=Emby result=partial duration_ms=7 "
            "restored=0"
        )
        cancelled = perf.parse_span_line(
            "perf.span phase=session.restore backend=Plex result=cancelled duration_ms=3 restored=0"
        )

        self.assertEqual(composition.fields, {"downloads_capable": "1"})
        self.assertEqual(download_manager.fields, {"background_events": "1"})
        self.assertEqual(download_store.fields, {"default_store": "1"})
        self.assertEqual(restore.fields, {"restored": "0"})
        self.assertEqual(cancelled.result, "cancelled")
        self.assertEqual(
            perf.evidence_schema.validate_correctness_fields(
                "runtime.composition", "App", ["downloads_capable"]
            ),
            ("downloads_capable",),
        )
        self.assertEqual(
            perf.evidence_schema.validate_correctness_fields(
                "runtime.download_manager", "App", ["background_events"]
            ),
            ("background_events",),
        )
        self.assertEqual(
            perf.evidence_schema.validate_correctness_fields(
                "runtime.download_store", "App", ["default_store"]
            ),
            ("default_store",),
        )
        self.assertEqual(
            perf.evidence_schema.validate_correctness_fields(
                "session.restore", "Emby", ["restored"]
            ),
            ("restored",),
        )
        self.assertEqual(perf.parse_span_line_diagnostic(
            "perf.span phase=runtime.composition backend=Plex result=success duration_ms=4 "
            "downloads_capable=1"
        )[1], "unexpected_phase_backend")
        self.assertEqual(perf.parse_span_line_diagnostic(
            "perf.span phase=session.restore backend=Emby result=success duration_ms=7 restored=2"
        )[1], "invalid_boolean_field")

    def test_error_values_are_closed_categories_not_copied(self):
        span = perf.parse_span_line(
            "perf.span phase=home.load backend=Plex result=failure duration_ms=1 error=Nas.Home.Internal"
        )
        self.assertEqual(span.fields["error"], "error_other")
        self.assertNotIn("Nas", span.fields["error"])

    def test_strict_parser_rejects_missing_duplicate_trailing_and_unknown_fields(self):
        cases = (
            ("perf.span phase=home.load backend=Plex duration_ms=1 force=0", "missing_core_field"),
            ("perf.span phase=home.load backend=Plex result=success result=failure duration_ms=1", "duplicate_field"),
            ("perf.span phase=home.load backend=Plex result=success duration_ms=1 trailing", "unparsed_text"),
            ("perf.span phase=home.load backend=Plex result=success duration_ms=1 title=Movie", "unexpected_phase_field"),
            ("perf.span phase=unknown backend=Plex result=success duration_ms=1", "unknown_phase"),
            ("perf.span phase=home.load backend=Unknown result=success duration_ms=1", "unknown_backend"),
            ("perf.span phase=home.load backend=Plex result=mystery duration_ms=1", "unknown_result"),
        )
        for line, expected in cases:
            with self.subTest(expected=expected):
                span, reason = perf.parse_span_line_diagnostic(line)
                self.assertIsNone(span)
                self.assertEqual(reason, expected)

    def test_strict_parser_rejects_negative_and_private_values(self):
        cases = (
            ("perf.span phase=home.load backend=Plex result=success duration_ms=-1", "negative_duration"),
            ("perf.span phase=home.load backend=Plex result=success duration_ms=1 item_count=SecretMovie", "invalid_integer_field"),
            ("perf.span phase=playback.startup backend=Plex result=success duration_ms=1 path_mode=SecretMovie", "invalid_enum_field"),
            ("perf.span phase=home.load backend=Plex result=success duration_ms=999999999999 hub_count=1 item_count=1", "invalid_duration"),
        )
        for line, expected in cases:
            with self.subTest(line=line):
                self.assertEqual(perf.parse_span_line_diagnostic(line)[1], expected)

    def test_diagnostics_ignore_noise_and_count_rejection_reasons(self):
        spans, rejected = perf.parse_spans_with_diagnostics([
            "ordinary app log",
            "perf.span phase=home.load backend=Plex result=success duration_ms=10 item_count=1",
            "perf.span phase=home.load backend=Plex result=success duration_ms=oops item_count=1",
        ])
        self.assertEqual(len(spans), 1)
        self.assertEqual(rejected, {"invalid_duration": 1})

    def test_summary_and_json_document_are_versioned(self):
        spans = perf.parse_spans([
            "perf.span phase=home.load backend=Plex result=success duration_ms=100 hub_count=2 item_count=10",
            "perf.span phase=home.load backend=Plex result=failure duration_ms=300 error=URLError",
        ])
        rows = perf.summarize(spans)
        self.assertEqual(rows[0]["failures"], 1)
        self.assertEqual(rows[0]["p50_ms"], 200)
        binding = {
            "run_id": "run-0123456789ab", "comparison_id": "comparison-0123456789ab",
            "artifact_role": "control", "sample_kind": "measured", "sample_index": 0,
            "scenario_id": "scenario-0123456789ab", "backend_kind": "plex",
        }
        workload = {
            "id": "workload-0123456789ab", "phase": "home.load", "backend": "Plex",
            "fields": {}, "correctness_fields": ["hub_count", "item_count"],
            "expected_span_count": 2, "aggregation": "median",
        }
        document = perf.json_document(
            spans, {}, binding=binding, workload=workload,
            source_artifact={"path": "raw/artifact-0001.log", "sha256": "a" * 64},
            capture_binding={"run_id": binding["run_id"], "workload_id": workload["id"],
                             "launch_nonce": "nonce-0123456789abcdef",
                             "binding_kind": "declared_capture"},
        )
        self.assertEqual(document["schema_version"], 1)
        self.assertEqual(document["binding"], binding)
        self.assertEqual(document["workload"], workload)

    def test_strict_cli_fails_closed_on_one_bad_perf_record(self):
        stdin = io.StringIO(
            "perf.span phase=home.load backend=Plex result=success duration_ms=10 item_count=1\n"
            "perf.span phase=home.load backend=Plex result=success duration_ms=-1 item_count=1\n"
        )
        with mock.patch("sys.stdin", stdin):
            self.assertEqual(perf.main(["--strict"]), 2)

    def test_json_cli_is_bound_to_exact_raw_artifact_and_capture_nonce(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            raw_dir = root / "raw"
            raw_dir.mkdir()
            raw = raw_dir / "artifact-0001.log"
            manifest = root / "manifest.json"
            manifest_data = {
                "run": {"id": "run-0123456789ab", "comparison_id": "comparison-0123456789ab",
                        "artifact_role": "control", "sample_kind": "measured", "sample_index": 0},
                "scenario": {"id": "scenario-0123456789ab", "backend_kind": "plex"},
                "evidence": {"artifacts": []},
            }
            manifest.write_text(json.dumps(manifest_data))
            marker = io.StringIO()
            with contextlib.redirect_stdout(marker):
                self.assertEqual(perf.main([
                    "--emit-capture-marker", "--manifest", str(manifest),
                    "--workload-id", "workload-0123456789ab",
                    "--launch-nonce", "nonce-0123456789abcdef",
                ]), 0)
            raw.write_text(marker.getvalue()
                           + "perf.span phase=home.load backend=Plex result=success duration_ms=10 "
                           "hub_count=1 item_count=2 publication_count=1\n")
            manifest_data["evidence"]["artifacts"] = [{
                "path": "raw/artifact-0001.log", "sha256": hashlib.sha256(raw.read_bytes()).hexdigest(),
            }]
            manifest.write_text(json.dumps(manifest_data))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = perf.main([
                    "--json", "--strict", "--manifest", str(manifest), "--raw-artifact", str(raw),
                    "--workload-id", "workload-0123456789ab", "--phase", "home.load",
                    "--backend", "Plex", "--correctness-field", "hub_count",
                    "--correctness-field", "item_count",
                    "--expected-span-count", "1",
                ])
            self.assertEqual(result, 0)
            document = json.loads(output.getvalue())
            self.assertEqual(document["capture_binding"]["launch_nonce"], "nonce-0123456789abcdef")
            raw.write_text(raw.read_text().replace("duration_ms=10", "duration_ms=11"))
            self.assertEqual(perf.main([
                "--json", "--strict", "--manifest", str(manifest), "--raw-artifact", str(raw),
                "--workload-id", "workload-0123456789ab", "--phase", "home.load",
                "--backend", "Plex", "--correctness-field", "hub_count",
                "--correctness-field", "item_count",
                "--expected-span-count", "1",
            ]), 2)


if __name__ == "__main__":
    unittest.main()
