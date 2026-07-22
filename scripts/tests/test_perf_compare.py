import hashlib
import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-compare.py"
spec = importlib.util.spec_from_file_location("perf_compare", SCRIPT)
compare = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = compare
spec.loader.exec_module(compare)

SUMMARY_SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-log-summary.py"
summary_spec = importlib.util.spec_from_file_location("perf_log_summary_for_compare", SUMMARY_SCRIPT)
summary_tool = importlib.util.module_from_spec(summary_spec)
sys.modules[summary_spec.name] = summary_tool
summary_spec.loader.exec_module(summary_tool)


class PerfCompareTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.sequence = 0

    def tearDown(self):
        self.temporary.cleanup()

    def test_runtime_composition_uses_backendless_manifest_identity(self):
        self.assertEqual(compare.BACKEND_LABELS["none"], "App")

    def make_sample(self, role, kind, index, duration, *, result="success", item_count=100, mutate=None,
                    comparison_id="comparison-0123456789ab", order_seed="seed-0123456789abcdef"):
        self.sequence += 1
        root = self.root / f"{role}-{kind}-{index}-{self.sequence}"
        (root / "raw").mkdir(parents=True)
        (root / "summary").mkdir()
        raw = root / "raw" / "artifact-0001.log"
        run_id = f"run-{self.sequence:012x}"
        launch_nonce = f"nonce-{self.sequence:016x}"
        raw.write_text(
            f"perf.capture run_id={run_id} workload_id=workload-0123456789ab launch_nonce={launch_nonce}\n"
            f"perf.span phase=home.load backend=Plex result={result} duration_ms={duration} "
            f"hub_count=10 item_count={item_count} publication_count=1\n"
        )
        manifest = {
            "schema_version": 1,
            "tool": {"name": "labstream-performance-audit", "version": "1"},
            "run": {
                "id": run_id, "recorded_at": "2026-07-21T00:00:00Z",
                "comparison_id": comparison_id, "artifact_role": role, "sample_kind": kind,
                "sample_index": index, "order_seed": order_seed,
            },
            "product": {
                "commit": ("a" if role == "control" else "c") * 40,
                "sha256": ("b" if role == "control" else "d") * 64,
                "configuration": "PerformanceAudit", "target": "Labstream", "platform": "visionos",
                "os_build": "24A123", "xcode_build": "17A456",
            },
            "device": {
                "label": "local-device-01", "power_source": "external", "battery_state": "full",
                "thermal_state": "nominal", "free_storage_bytes": 1_000_000_000,
                "display_mode": "windowed",
            },
            "state": {
                "install_state": "reinstall_same_artifact", "container_state": "restored_fixture",
                "cache_reset": {"command_id": "fixture-cache-seed-v1", "result": "success"},
            },
            "scenario": {
                "id": "scenario-0123456789ab", "category": "home",
                "run_kind": "deterministic_fixture", "fixture_id": "fixture-0123456789ab",
                "fixture_sha256": "e" * 64, "backend_kind": "plex", "server_version": None,
                "cache_state": "declared_seed",
            },
            "launch_contract": {
                "arguments": [], "environment_keys": [], "ui_test_fixture": False,
                "live_probe": False, "tv_event_swizzle": False, "verbose_debug_evidence": False,
            },
            "evidence": {"artifacts": [], "redacted_summary": {}, "privacy_review": "pending",
                         "retention_deadline": "2026-08-21T00:00:00Z", "publishable": False},
        }
        binding = {
            "run_id": run_id, "comparison_id": comparison_id, "artifact_role": role,
            "sample_kind": kind, "sample_index": index, "scenario_id": "scenario-0123456789ab",
            "backend_kind": "plex",
        }
        raw_pointer = {"path": "raw/artifact-0001.log",
                       "sha256": hashlib.sha256(raw.read_bytes()).hexdigest()}
        workload = {"id": "workload-0123456789ab", "phase": "home.load", "backend": "Plex",
                    "fields": {}, "correctness_fields": ["hub_count", "item_count"],
                    "expected_span_count": 1, "aggregation": "median"}
        summary_document = {
            "schema_version": 1, "tool": {"name": "labstream-perf-log-summary", "version": "2"},
            "binding": binding,
            "capture_binding": {"run_id": run_id, "workload_id": workload["id"],
                                "launch_nonce": launch_nonce, "binding_kind": "declared_capture"},
            "source_artifact": raw_pointer, "workload": workload,
            "spans": [{"phase": "home.load", "backend": "Plex", "result": result,
                       "duration_ms": duration,
                       "fields": {"hub_count": "10", "item_count": str(item_count),
                                  "publication_count": "1"}}],
            "rows": [], "diagnostics": {"rejected_span_count": 0, "rejection_reasons": {}},
        }
        if mutate:
            mutate(manifest, summary_document)
        spans = summary_document["spans"]
        durations = [span["duration_ms"] for span in spans]
        if durations:
            summary_document["rows"] = [{
                "phase": spans[0]["phase"], "backend": spans[0]["backend"], "count": len(spans),
                "failures": sum(span["result"] != "success" for span in spans),
                "min_ms": min(durations), "p50_ms": durations[0], "p95_ms": durations[0],
                "max_ms": max(durations),
            }]
        summary = root / "summary" / "redacted.json"
        summary.write_text(json.dumps(summary_document))
        def pointer(path):
            return {"path": path.relative_to(root).as_posix(),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        manifest["evidence"]["artifacts"] = [raw_pointer]
        manifest["evidence"]["redacted_summary"] = pointer(summary)
        path = root / "manifest.json"
        path.write_text(json.dumps(manifest))
        return path

    def set_time(self, path, ordinal, day=21):
        manifest = json.loads(path.read_text())
        manifest["run"]["recorded_at"] = f"2026-07-{day:02d}T00:{ordinal // 60:02d}:{ordinal % 60:02d}Z"
        path.write_text(json.dumps(manifest))

    def regenerate_summary_with_cli(self, path):
        manifest = json.loads(path.read_text())
        raw = path.parent / manifest["evidence"]["artifacts"][0]["path"]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = summary_tool.main([
                "--json", "--strict", "--manifest", str(path), "--raw-artifact", str(raw),
                "--workload-id", "workload-0123456789ab", "--phase", "home.load",
                "--backend", "Plex", "--correctness-field", "hub_count",
                "--correctness-field", "item_count",
                "--expected-span-count", "1",
            ])
        self.assertEqual(result, 0)
        summary = path.parent / manifest["evidence"]["redacted_summary"]["path"]
        summary.write_text(output.getvalue())
        manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(summary.read_bytes()).hexdigest()
        path.write_text(json.dumps(manifest))

    def schedule_pairs(self, controls, candidates):
        by_key = {(json.loads(path.read_text())["run"]["sample_kind"],
                   json.loads(path.read_text())["run"]["sample_index"],
                   json.loads(path.read_text())["run"]["artifact_role"]): path
                  for path in controls + candidates}
        ordinal = 0
        for kind in ("warmup", "measured"):
            indexes = sorted(index for k, index, role in by_key if k == kind and role == "control")
            for index in indexes:
                first = compare._expected_first_role("seed-0123456789abcdef", kind, index)
                second = "candidate" if first == "control" else "control"
                self.set_time(by_key[(kind, index, first)], ordinal)
                ordinal += 1
                self.set_time(by_key[(kind, index, second)], ordinal)
                ordinal += 1

    def paired_set(self, factor=0.8, measured=20, candidate_failure=None, warmup_failure=None,
                   candidate_item_count=100):
        controls, candidates = [], []
        for index in range(3):
            controls.append(self.make_sample("control", "warmup", index, 100 + index))
            candidates.append(self.make_sample("candidate", "warmup", index, round((100 + index) * factor),
                                               item_count=candidate_item_count,
                                               result=warmup_failure if warmup_failure and index == 0 else "success"))
        for index in range(measured):
            duration = 100 + index % 3
            controls.append(self.make_sample("control", "measured", index, duration))
            candidates.append(self.make_sample("candidate", "measured", index, round(duration * factor),
                                               item_count=candidate_item_count,
                                               result=candidate_failure if candidate_failure and index == 0 else "success"))
        self.schedule_pairs(controls, candidates)
        return controls, candidates

    def freeze_set(self):
        paths = []
        ordinal = 0
        for kind, count in (("warmup", 3), ("measured", 20)):
            for index in range(count):
                path = self.make_sample("control", kind, index, 100 + index % 3,
                                        comparison_id="comparison-fedcba987654")
                self.set_time(path, ordinal, day=20)
                ordinal += 1
                paths.append(path)
        return paths

    def load(self, paths, role):
        return [compare.load_sample(path, role) for path in paths]

    def selector(self):
        return {"id": "workload-0123456789ab", "phase": "home.load", "backend": "Plex",
                "fields": {}, "correctness_fields": ["hub_count", "item_count"],
                "expected_span_count": 1, "aggregation": "median"}

    def frozen(self):
        return compare.freeze_control(self.load(self.freeze_set(), "control"),
                                      selector=self.selector(), sample_policy="short")

    def result(self, controls, candidates, frozen=None, tolerance=1024):
        artifact = frozen or self.frozen()
        return compare.compare(self.load(controls, "control"), self.load(candidates, "candidate"),
                               selector=self.selector(), sample_policy="short",
                               frozen_artifact=artifact,
                               frozen_artifact_sha256=compare._canonical_sha256(artifact),
                               max_free_storage_drift_bytes=tolerance, max_pair_gap_seconds=120)

    def test_improvement_regression_noise_and_deterministic_bootstrap(self):
        for factor, expected in ((0.8, "improvement"), (1.2, "regression"), (0.99, "noise")):
            with self.subTest(expected=expected):
                controls, candidates = self.paired_set(factor)
                frozen = self.frozen()
                first = self.result(controls, candidates, frozen)
                second = self.result(controls, candidates, frozen)
                self.assertEqual(first["outcome"], expected)
                self.assertEqual(first["statistics"], second["statistics"])
                self.assertEqual(first["statistics"]["bootstrap_resamples"], 10_000)

    def test_failed_warmup_is_insufficient_and_reported(self):
        controls, candidates = self.paired_set(warmup_failure="timeout")
        result = self.result(controls, candidates)
        self.assertEqual(result["outcome"], "insufficient_data")
        self.assertEqual(result["candidate"]["warmup_failed"], 1)
        self.assertIn("failed warmups", " ".join(result["reasons"]))

    def test_invalid_collection_takes_precedence_over_failure_regression(self):
        controls, candidates = self.paired_set(candidate_failure="timeout", warmup_failure="timeout")
        self.assertEqual(self.result(controls, candidates)["outcome"], "insufficient_data")
        controls, candidates = self.paired_set(candidate_failure="timeout")
        controls.pop(3)  # candidate measured failure is now unmatched invalid evidence
        self.assertEqual(self.result(controls, candidates)["outcome"], "insufficient_data")

    def test_new_measured_failure_mode_is_regression_not_dropped(self):
        controls, candidates = self.paired_set(candidate_failure="timeout")
        result = self.result(controls, candidates)
        self.assertEqual(result["outcome"], "regression")
        self.assertEqual(result["candidate"]["new_failure_modes"], ["timeout"])
        self.assertIsNone(result["pairs"][0]["delta_percent"])

    def test_insufficient_pair_count_is_explicit(self):
        controls, candidates = self.paired_set(measured=5)
        self.assertEqual(self.result(controls, candidates)["outcome"], "insufficient_data")

    def test_same_index_blocks_seed_order_and_warmup_order_are_enforced(self):
        controls, candidates = self.paired_set()
        # Reverse one same-index pair: still alternating, but no longer seed-derived.
        expected = compare._expected_first_role("seed-0123456789abcdef", "warmup", 0)
        expected_path = controls[0] if expected == "control" else candidates[0]
        other_path = candidates[0] if expected == "control" else controls[0]
        self.set_time(expected_path, 1)
        self.set_time(other_path, 0)
        with self.assertRaisesRegex(compare.CompareError, "order_seed"):
            self.result(controls, candidates)
        controls, candidates = self.paired_set()
        self.set_time(controls[3], 0)  # measured run before warmup blocks
        with self.assertRaisesRegex(compare.CompareError, "unique|warmup"):
            self.result(controls, candidates)

    def test_summary_binding_workload_and_cardinality_fail_closed(self):
        mutations = (
            (lambda _, summary: summary["binding"].update(run_id="run-ffffffffffff"), "binding"),
            (lambda _, summary: summary["workload"].update(expected_span_count=2), "cardinality"),
            (lambda _, summary: summary["spans"][0].update(backend="Emby"), "foreign"),
            (lambda _, summary: summary["workload"].update(correctness_fields=["item_count"]), "semantic schema"),
        )
        for mutation, message in mutations:
            with self.subTest(message=message):
                path = self.make_sample("control", "measured", 0, 100, mutate=mutation)
                with self.assertRaisesRegex(compare.CompareError, message):
                    compare.load_sample(path, "control")

    def test_handcrafted_summary_must_obey_shared_semantics_and_raw_derivation(self):
        path = self.make_sample(
            "control", "measured", 0, 100,
            mutate=lambda _, summary: summary["spans"][0]["fields"].update(item_count="SecretMovie"),
        )
        with self.assertRaisesRegex(compare.CompareError, "semantic schema"):
            compare.load_sample(path, "control")
        path = self.make_sample(
            "control", "measured", 0, 100,
            mutate=lambda _, summary: summary["spans"][0].update(duration_ms=99),
        )
        with self.assertRaisesRegex(compare.CompareError, "exact derivation"):
            compare.load_sample(path, "control")

    def test_manifest_privacy_contract_runs_before_summary(self):
        path = self.make_sample("control", "measured", 0, 100,
                                mutate=lambda manifest, _: manifest["device"].update(label="https://private.invalid"))
        with self.assertRaisesRegex(compare.CompareError, "forbidden URL"):
            compare.load_sample(path, "control")

    def test_frozen_mde_checksum_and_provenance_are_required(self):
        artifact = self.frozen()
        path = self.root / "frozen.json"
        path.write_text(json.dumps(artifact, sort_keys=True))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(compare.load_frozen(path, digest), artifact)
        with self.assertRaisesRegex(compare.CompareError, "checksum"):
            compare.load_frozen(path, "0" * 64)
        artifact["control"]["commit"] = "f" * 40
        controls, candidates = self.paired_set()
        with self.assertRaisesRegex(compare.CompareError, "commit mismatch"):
            self.result(controls, candidates, artifact)
        artifact = self.frozen()
        artifact["statistics"]["control_median_ms"] = 10 ** 400
        with self.assertRaisesRegex(compare.CompareError, "finite number"):
            compare._validate_frozen_shape(artifact)

    def test_pairwise_battery_thermal_and_storage_covariates(self):
        controls, candidates = self.paired_set()
        candidate = json.loads(candidates[3].read_text())
        candidate["device"]["battery_state"] = "charging"
        candidates[3].write_text(json.dumps(candidate))
        with self.assertRaisesRegex(compare.CompareError, "battery_state"):
            self.result(controls, candidates)

        controls, candidates = self.paired_set()
        for path in (controls[3], candidates[3]):
            manifest = json.loads(path.read_text())
            manifest["device"]["thermal_state"] = "serious"
            path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(compare.CompareError, "unsupported thermal"):
            self.result(controls, candidates)

        controls, candidates = self.paired_set()
        manifest = json.loads(candidates[3].read_text())
        manifest["device"]["free_storage_bytes"] += 2048
        candidates[3].write_text(json.dumps(manifest))
        with self.assertRaisesRegex(compare.CompareError, "storage drift"):
            self.result(controls, candidates, tolerance=1024)

    def test_pairing_rejects_external_automation_provenance_drift(self):
        controls, candidates = self.paired_set()
        common = {
            "fixture_implementation_sha256": "d" * 64,
            "driver_sha256": "e" * 64,
            "workload_spec_sha256": "f" * 64,
            "client_state_seed_sha256": "a" * 64,
            "fixture_protocol_version": 1,
            "driver_protocol_version": 1,
        }
        for path in controls + candidates:
            manifest = json.loads(path.read_text())
            manifest["automation"] = dict(common)
            path.write_text(json.dumps(manifest))
        candidate = json.loads(candidates[-1].read_text())
        candidate["automation"]["driver_sha256"] = "a" * 64
        candidates[-1].write_text(json.dumps(candidate))
        with self.assertRaisesRegex(compare.CompareError, "environment metadata"):
            self.result(controls, candidates)

    def test_correctness_work_fields_must_match_before_latency_classification(self):
        controls, candidates = self.paired_set(factor=0.5, candidate_item_count=1)
        with self.assertRaisesRegex(compare.CompareError, "correctness/work"):
            self.result(controls, candidates)

    def test_freeze_is_order_independent_and_rejects_mixed_seed(self):
        paths = self.freeze_set()
        forward = compare.freeze_control(self.load(paths, "control"), selector=self.selector(), sample_policy="short")
        reverse = compare.freeze_control(self.load(list(reversed(paths)), "control"),
                                         selector=self.selector(), sample_policy="short")
        self.assertEqual(forward, reverse)
        manifest = json.loads(paths[-1].read_text())
        manifest["run"]["order_seed"] = "seed-fedcba9876543210"
        paths[-1].write_text(json.dumps(manifest))
        with self.assertRaisesRegex(compare.CompareError, "order seed"):
            compare.freeze_control(self.load(paths, "control"), selector=self.selector(), sample_policy="short")

    def test_pair_gap_and_missing_frozen_file_fail_closed(self):
        controls, candidates = self.paired_set()
        with self.assertRaisesRegex(compare.CompareError, "time-gap"):
            compare.compare(self.load(controls, "control"), self.load(candidates, "candidate"),
                            selector=self.selector(), sample_policy="short", frozen_artifact=self.frozen(),
                            frozen_artifact_sha256="a" * 64, max_free_storage_drift_bytes=1024,
                            max_pair_gap_seconds=0.5)
        with self.assertRaisesRegex(compare.CompareError, "unreadable"):
            compare.load_frozen(self.root / "missing.json", "a" * 64)

    def test_cli_freeze_then_compare_writes_outputs(self):
        freeze_paths = self.freeze_set()
        for path in freeze_paths:
            self.regenerate_summary_with_cli(path)
        frozen_path = self.root / "frozen.json"
        argv = ["freeze", "--control-manifest", *map(str, freeze_paths), "--phase", "home.load",
                "--backend", "Plex", "--correctness-field", "hub_count",
                "--correctness-field", "item_count",
                "--out", str(frozen_path)]
        self.assertEqual(compare.main(argv), 0)
        digest = hashlib.sha256(frozen_path.read_bytes()).hexdigest()
        controls, candidates = self.paired_set(factor=1.2)
        for path in controls + candidates:
            self.regenerate_summary_with_cli(path)
        json_out, csv_out = self.root / "result.json", self.root / "pairs.csv"
        argv = ["compare", "--control-manifest", *map(str, controls), "--candidate-manifest",
                *map(str, candidates), "--phase", "home.load", "--backend", "Plex",
                "--correctness-field", "hub_count", "--correctness-field", "item_count",
                "--frozen-mde", str(frozen_path),
                "--frozen-mde-sha256", digest,
                "--max-free-storage-drift-bytes", "1024", "--json-out", str(json_out),
                "--max-pair-gap-seconds", "120", "--csv-out", str(csv_out)]
        self.assertEqual(compare.main(argv), 2)
        result = json.loads(json_out.read_text())
        self.assertEqual(result["outcome"], "regression")
        self.assertEqual(result["frozen_mde_artifact"]["sha256"], digest)
        self.assertEqual(result["protocol"]["frozen_before_candidate"], "operator_attested")
        self.assertEqual(len(result["control"]["evidence_manifests"]), 23)
        self.assertEqual(len(csv_out.read_text().splitlines()), 21)

        collision_argv = list(argv)
        collision_argv[collision_argv.index(str(csv_out))] = str(json_out)
        self.assertEqual(compare.main(collision_argv), 1)

    def test_freeze_output_cannot_overwrite_input_manifest(self):
        paths = self.freeze_set()
        argv = ["freeze", "--control-manifest", *map(str, paths), "--phase", "home.load",
                "--backend", "Plex", "--correctness-field", "hub_count",
                "--correctness-field", "item_count",
                "--out", str(paths[0])]
        self.assertEqual(compare.main(argv), 1)


if __name__ == "__main__":
    unittest.main()
