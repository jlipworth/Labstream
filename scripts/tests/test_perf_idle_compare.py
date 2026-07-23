import hashlib
import importlib.util
import json
import pathlib
import shutil
import statistics
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "perf-idle-compare.py"
SPEC = importlib.util.spec_from_file_location("perf_idle_compare", SCRIPT)
assert SPEC and SPEC.loader
idle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = idle
SPEC.loader.exec_module(idle)


class IdleCompareTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.runner_path = self.root / "runner.json"
        self.seed = 20260726
        self.runner, self.records, self.samples = self.make_evidence()
        self.write_runner()

    def tearDown(self):
        self.temporary.cleanup()

    def write_runner(self):
        self.runner["records"] = self.records
        self.runner_path.write_text(json.dumps(self.runner))

    def make_evidence(self, *, candidate_cpu=1.0, candidate_wakeups=1.0,
                      control_cpu=12_000_000, control_wakeups=120,
                      warmups=1, measured=5):
        shutil.rmtree(self.root / "runner-logs", ignore_errors=True)
        schedule = idle._expected_schedule(self.seed, warmups, measured)
        order_seed = "seed-" + hashlib.sha256(str(self.seed).encode()).hexdigest()[:16]
        commits = {"control": "a" * 40, "candidate": "b" * 40}
        fixture_sha = idle.CANONICAL_INDEX["sha256"]
        identities = {
            "comparison_id": idle._opaque("comparison", self.seed, commits["control"], commits["candidate"]),
            "fixture_id": idle._opaque("fixture", self.seed, commits["control"], commits["candidate"],
                                       fixture_sha),
            "order_seed": order_seed,
            "scenario_id": idle._opaque("scenario", self.seed, commits["control"], commits["candidate"],
                                        "idle"),
            "workload_id": idle._opaque("workload", self.seed, commits["control"], commits["candidate"],
                                        "idle.metrics")}
        runner = {"schema_version": 1, "mode": "capture", "scenario": "idle",
                  "seed": self.seed, "warmups": warmups, "measured": measured,
                  "duration_seconds": 120, "identities": identities, "commits": commits,
                  "capture_status": "success", "output": str(self.runner_path),
                  "canonical_index": dict(idle.CANONICAL_INDEX)}
        records, samples = [], []
        origin = datetime(2026, 7, 23, tzinfo=timezone.utc)
        for ordinal, raw in enumerate(schedule):
            role, kind, index = raw["role"], raw["sample_kind"], raw["sample_index"]
            run_id = idle._opaque("run", identities["comparison_id"], "idle", role, kind, index,
                                  raw["pair_order"])
            run_dir = self.root / "runner-logs" / run_id
            run_dir.parent.mkdir(exist_ok=True)
            run_dir.mkdir()
            manifest_path = run_dir / "manifest.json"
            summary_dir = run_dir / "summary"
            summary_dir.mkdir()
            recorded = origin + timedelta(seconds=130 * ordinal)
            cpu = control_cpu if role == "control" else round(control_cpu * candidate_cpu)
            wakeups = control_wakeups if role == "control" else round(control_wakeups * candidate_wakeups)
            manifest = {
                "schema_version": 1, "tool": {"name": "labstream-performance-audit", "version": "1"},
                "run": {"id": run_id, "recorded_at": recorded.isoformat().replace("+00:00", "Z"),
                        "comparison_id": identities["comparison_id"], "artifact_role": role,
                        "sample_kind": kind, "sample_index": index, "order_seed": order_seed},
                "product": {"commit": commits[role], "sha256": ("c" if role == "control" else "d") * 64,
                            "configuration": "PerformanceAudit", "target": "LabstreamMac",
                            "platform": "macos", "os_build": "26A5388g", "xcode_build": "27A5218g"},
                "device": {"label": "local-device-01", "power_source": "external",
                           "battery_state": "charging", "thermal_state": "nominal",
                           "free_storage_bytes": 50_000_000_000 - ordinal * 1_000_000,
                           "display_mode": "windowed"},
                "state": {"install_state": "direct_staged_artifact", "container_state": "restored_fixture",
                          "cache_reset": {"command_id": "fixture-cache-seed-v1", "result": "success"}},
                "scenario": {"id": identities["scenario_id"], "category": "idle",
                             "run_kind": "deterministic_fixture", "fixture_id": identities["fixture_id"],
                             "fixture_sha256": fixture_sha, "backend_kind": "none",
                             "server_version": None, "cache_state": "declared_seed"},
                "launch_contract": {"arguments": [], "environment_keys": [], "ui_test_fixture": False,
                                    "live_probe": False, "tv_event_swizzle": False,
                                    "verbose_debug_evidence": False},
                "evidence": {"artifacts": [{"path": "raw/artifact-0003.json", "sha256": "f" * 64}],
                             "redacted_summary": {"path": "summary/redacted.json", "sha256": "0" * 64},
                             "privacy_review": "pending", "retention_deadline": "2099-01-01T00:00:00Z",
                             "publishable": False},
            }
            summary = {"schema_version": 1,
                       "tool": {"name": "labstream-xctrace-idle-summary", "version": "1"},
                       "binding": {}, "sources": {},
                       "capture": {"xcode_build": "27A5218g", "pid": 1000 + ordinal,
                                   "expected_duration_ns": 120_000_000_000,
                                   "window_tolerance_ns": 1_000_000_000,
                                   "actual_duration_ns": 120_000_000_000},
                       "metrics": {"cpu_running_ns": cpu, "wakeups_count": wakeups}}
            summary_path = summary_dir / "redacted.json"
            summary_path.write_text(json.dumps(summary))
            manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(
                summary_path.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest))
            digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
            record = {**raw, "status": "success", "failure": None,
                      "manifest": str(manifest_path), "manifest_sha256": digest}
            records.append(record)
            samples.append(idle.IdleSample(manifest_path, digest, manifest, summary))
        return runner, records, samples

    @staticmethod
    def thresholds():
        return {"schema_version": 1, "tool": idle.THRESHOLD_TOOL, "sample_policy": "long",
                "duration_seconds": 120, "rationale": "Fixed engineering guardrail",
                "metrics": {
                    "cpu_running_ns_per_second": {"absolute_mde": 1_000.0,
                                                  "relative_mde_percent": 5.0},
                    "wakeups_per_minute": {"absolute_mde": 1.0,
                                           "relative_mde_percent": 5.0}}}

    def result(self, *, thresholds=True, storage=10_000_000, gap=140, window=1_000_000):
        return idle.compare(self.runner_path, self.runner, self.records, self.samples,
                            runner_sha256=hashlib.sha256(self.runner_path.read_bytes()).hexdigest(),
                            thresholds=self.thresholds() if thresholds else None,
                            threshold_path=self.root / "thresholds.json" if thresholds else None,
                            threshold_sha256="1" * 64 if thresholds else None,
                            max_storage_drift=storage, max_pair_start_gap=gap,
                            max_window_drift_ns=window)

    def test_exact_long_pair_is_duration_normalized_and_noise(self):
        result = self.result()
        self.assertEqual(result["outcome"], "noise")
        self.assertEqual(len(result["pairs"]), 5)
        self.assertEqual(result["pairs"][0]["rates"]["wakeups_per_minute"]["control"], 60.0)
        self.assertEqual(result["statistics_contract"]["bootstrap_resamples"], 10_000)

    def test_strong_regression_and_improvement_are_deterministic(self):
        self.runner, self.records, self.samples = self.make_evidence(candidate_cpu=1.2,
                                                                     candidate_wakeups=1.2)
        self.write_runner()
        first = self.result()
        second = self.result()
        self.assertEqual(first["outcome"], "regression")
        self.assertEqual(first["metrics"], second["metrics"])
        self.runner, self.records, self.samples = self.make_evidence(candidate_cpu=.8,
                                                                     candidate_wakeups=.8)
        self.write_runner()
        self.assertEqual(self.result()["outcome"], "improvement")

    def test_zero_baseline_is_absolute_and_relative_is_null(self):
        self.runner, self.records, self.samples = self.make_evidence(control_wakeups=0,
                                                                     candidate_wakeups=1.0)
        self.write_runner()
        row = self.result()["pairs"][0]["rates"]["wakeups_per_minute"]
        self.assertEqual(row["delta"], 0)
        self.assertIsNone(row["delta_percent"])
        for sample in self.samples:
            if sample.role == "candidate":
                sample.summary["metrics"]["wakeups_count"] = 2
        row = self.result()["pairs"][0]["rates"]["wakeups_per_minute"]
        self.assertEqual(row["delta"], 1.0)
        self.assertIsNone(row["delta_percent"])

    def test_missing_threshold_is_descriptive_insufficient(self):
        result = self.result(thresholds=False)
        self.assertEqual(result["outcome"], "insufficient_data")
        self.assertIsNotNone(result["metrics"]["cpu_running_ns_per_second"]["paired_median_delta_ci"])
        self.assertIn("no admissible", result["reasons"][0])

    def test_complete_zero_warmup_one_pair_smoke_is_descriptive_insufficient(self):
        self.runner, self.records, self.samples = self.make_evidence(warmups=0, measured=1)
        self.write_runner()
        with mock.patch.object(idle.contract, "validate_manifest"):
            runner, records, samples, runner_sha256 = idle.load_runner(self.runner_path)
        result = idle.compare(
            self.runner_path, runner, records, samples, runner_sha256=runner_sha256,
            thresholds=None, threshold_path=None, threshold_sha256=None,
            max_storage_drift=10_000_000, max_pair_start_gap=140,
            max_window_drift_ns=1_000_000)
        self.assertEqual(result["outcome"], "insufficient_data")
        self.assertEqual(len(result["pairs"]), 1)
        self.assertIsNone(result["metrics"]["cpu_running_ns_per_second"]["paired_median_delta_ci"])
        self.assertTrue(any("exact long policy" in reason for reason in result["reasons"]))

        output = self.root / "smoke-comparison.json"
        with mock.patch.object(idle.contract, "validate_manifest"):
            status = idle.main([
                "--runner-result", str(self.runner_path),
                "--max-free-storage-drift-bytes", "10000000",
                "--max-pair-start-gap-seconds", "140",
                "--max-actual-window-drift-ms", "1",
                "--json-out", str(output),
            ])
        self.assertEqual(status, 3)
        self.assertEqual(json.loads(output.read_text())["outcome"], "insufficient_data")

    def test_candidate_failure_is_preserved_and_regression(self):
        target = next(i for i, record in enumerate(self.records)
                      if record["sample_kind"] == "measured" and record["role"] == "candidate")
        failed = self.records[target]
        failed.clear()
        failed.update({**idle._expected_schedule(self.seed)[target], "status": "failure",
                       "failure": {"type": "RunnerError", "message": "app exited"}})
        self.samples = [sample for sample in self.samples
                        if not (sample.kind == "measured" and sample.index == 0
                                and sample.role == "candidate")]
        self.write_runner()
        self.runner["capture_status"] = "failure"
        result = self.result()
        self.assertEqual(result["outcome"], "regression")
        self.assertEqual(result["capture_failures"], [{
            "sample_kind": "measured", "sample_index": 0, "pair_order": failed["pair_order"],
            "role": "candidate", "type": "RunnerError"}])
        self.assertNotIn("app exited", json.dumps(result))

    def test_warmup_failure_is_insufficient(self):
        target = 0
        failed = self.records[target]
        failed_role = failed["role"]
        failed.clear()
        failed.update({**idle._expected_schedule(self.seed)[target], "status": "failure",
                       "failure": {"type": "RunnerError", "message": "trace failed"}})
        self.samples = [sample for sample in self.samples
                        if not (sample.kind == "warmup" and sample.role == failed_role)]
        self.assertEqual(self.result()["outcome"], "insufficient_data")

    def test_equal_failure_counts_with_candidate_only_mode_is_regression(self):
        removed = []
        for role, failure_type in (("control", "ControlFailure"), ("candidate", "CandidateFailure")):
            target = next(i for i, record in enumerate(self.records)
                          if record["sample_kind"] == "measured" and record["sample_index"] == 0
                          and record["role"] == role)
            raw = idle._expected_schedule(self.seed)[target]
            self.records[target] = {**raw, "status": "failure",
                                    "failure": {"type": failure_type, "message": "bounded"}}
            removed.append(role)
        self.samples = [sample for sample in self.samples
                        if not (sample.kind == "measured" and sample.index == 0
                                and sample.role in removed)]
        result = self.result()
        self.assertEqual(result["outcome"], "regression")
        self.assertEqual(result["candidate"]["new_measured_failure_modes"], ["CandidateFailure"])

    def test_pair_schedule_chronology_and_identity_fail_closed(self):
        self.samples[0].manifest["run"]["recorded_at"] = self.samples[1].manifest["run"]["recorded_at"]
        with self.assertRaisesRegex(idle.IdleCompareError, "chronology"):
            self.result()
        self.samples[0].manifest["run"]["recorded_at"] = "2026-07-23T00:00:00Z"
        self.samples[0].manifest["run"]["id"] = self.samples[1].manifest["run"]["id"]
        with self.assertRaisesRegex(idle.IdleCompareError, "globally unique"):
            self.result()

    def test_environment_power_thermal_storage_gap_and_window_fail_closed(self):
        self.samples[0].manifest["device"]["power_source"] = "battery"
        with self.assertRaisesRegex(idle.IdleCompareError, "stable"):
            self.result()
        self.samples[0].manifest["device"]["power_source"] = "external"
        self.samples[0].manifest["device"]["thermal_state"] = "serious"
        for sample in self.samples:
            sample.manifest["device"]["thermal_state"] = "serious"
        with self.assertRaisesRegex(idle.IdleCompareError, "nominal/fair"):
            self.result()
        for sample in self.samples:
            sample.manifest["device"]["thermal_state"] = "nominal"
        with self.assertRaisesRegex(idle.IdleCompareError, "free-storage"):
            self.result(storage=0)
        with self.assertRaisesRegex(idle.IdleCompareError, "start-gap"):
            self.result(gap=125)
        self.samples[0].summary["capture"]["actual_duration_ns"] += 2_000_000
        with self.assertRaisesRegex(idle.IdleCompareError, "actual-window"):
            self.result(window=1_000_000)

    def test_threshold_artifact_is_closed_checksummed_and_nonzero(self):
        path = self.root / "thresholds.json"
        path.write_text(json.dumps(self.thresholds()))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(idle.load_thresholds(path, digest, duration_seconds=120)["tool"],
                         idle.THRESHOLD_TOOL)
        with self.assertRaisesRegex(idle.IdleCompareError, "checksum"):
            idle.load_thresholds(path, "0" * 64, duration_seconds=120)
        artifact = self.thresholds()
        artifact["metrics"]["wakeups_per_minute"] = {"absolute_mde": 0,
                                                       "relative_mde_percent": 0}
        path.write_text(json.dumps(artifact))
        with self.assertRaisesRegex(idle.IdleCompareError, "entirely zero"):
            idle.load_thresholds(path, hashlib.sha256(path.read_bytes()).hexdigest(),
                                 duration_seconds=120)

    def test_threshold_parser_authenticates_the_exact_decisive_bytes(self):
        path = self.root / "thresholds.json"
        payload = json.dumps(self.thresholds()).encode()
        path.write_bytes(payload)
        with mock.patch.object(idle.os, "open", wraps=idle.os.open) as opened:
            loaded = idle.load_thresholds(path, hashlib.sha256(payload).hexdigest(),
                                          duration_seconds=120)
        self.assertEqual(loaded["metrics"], self.thresholds()["metrics"])
        self.assertEqual(opened.call_count, 1)

    def test_freeze_is_deterministic_and_uses_control_only(self):
        digest = hashlib.sha256(self.runner_path.read_bytes()).hexdigest()
        first = idle.freeze_thresholds(
            self.runner, self.records, self.samples, runner_sha256=digest,
            rationale="Control only pilot")
        for sample in self.samples:
            if sample.role == "candidate":
                sample.summary["metrics"]["cpu_running_ns"] *= 1000
                sample.summary["metrics"]["wakeups_count"] *= 1000
        second = idle.freeze_thresholds(
            self.runner, self.records, self.samples, runner_sha256=digest,
            rationale="Control only pilot")
        self.assertEqual(first, second)
        self.assertEqual(
            first["metrics"]["cpu_running_ns_per_second"]["relative_mde_percent"], 5.0)
        self.assertEqual(
            first["metrics"]["wakeups_per_minute"]["relative_mde_percent"], 5.0)
        self.assertEqual(
            [item["sample_index"] for item in
             first["control_provenance"]["evidence_manifests"]], list(range(5)))

    def test_freeze_formula_uses_twice_bootstrap_width(self):
        controls = sorted(
            (sample for sample in self.samples
             if sample.role == "control" and sample.kind == "measured"),
            key=lambda sample: sample.index)
        for sample, cpu, wakeups in zip(
                controls, (1, 2, 4, 8, 16), (1, 2, 4, 8, 16), strict=True):
            sample.summary["metrics"]["cpu_running_ns"] = cpu * 120
            sample.summary["metrics"]["wakeups_count"] = wakeups
        result = idle.freeze_thresholds(
            self.runner, self.records, self.samples,
            runner_sha256="9" * 64, rationale="Formula fixture")
        for metric in idle.METRICS:
            values = [sample.rates[metric] for sample in controls]
            low, high = idle._bootstrap(
                values, idle._metric_seed(
                    self.runner["identities"]["order_seed"], f"control-threshold:{metric}"))
            width = high - low
            expected_relative = max(5.0, 200.0 * width / statistics.median(values))
            self.assertEqual(result["metrics"][metric]["absolute_mde"], 2.0 * width)
            self.assertEqual(
                result["metrics"][metric]["relative_mde_percent"], expected_relative)

    def test_freeze_zero_wakeup_floor_and_zero_cpu_rejection(self):
        for sample in self.samples:
            if sample.role == "control" and sample.kind == "measured":
                sample.summary["metrics"]["wakeups_count"] = 0
        result = idle.freeze_thresholds(
            self.runner, self.records, self.samples,
            runner_sha256="8" * 64, rationale="Zero wakeups")
        self.assertEqual(result["metrics"]["wakeups_per_minute"]["absolute_mde"], 0.5)
        for sample in self.samples:
            if sample.role == "control" and sample.kind == "measured":
                sample.summary["metrics"]["cpu_running_ns"] = 0
        with self.assertRaisesRegex(idle.IdleCompareError, "zero CPU"):
            idle.freeze_thresholds(
                self.runner, self.records, self.samples,
                runner_sha256="8" * 64, rationale="Zero CPU")
        controls = sorted(
            (sample for sample in self.samples
             if sample.role == "control" and sample.kind == "measured"),
            key=lambda sample: sample.index)
        for sample, cpu in zip(controls, (0, 0, 0, 120, 120), strict=True):
            sample.summary["metrics"]["cpu_running_ns"] = cpu
        informative = idle.freeze_thresholds(
            self.runner, self.records, self.samples,
            runner_sha256="8" * 64, rationale="Sparse CPU")
        self.assertGreater(
            informative["metrics"]["cpu_running_ns_per_second"]["absolute_mde"], 0)

    def test_freeze_requires_exact_completed_long_policy(self):
        for warmups, measured, duration in ((0, 5, 120), (1, 4, 120), (1, 5, 60)):
            runner = dict(self.runner, warmups=warmups, measured=measured,
                          duration_seconds=duration)
            with self.subTest(warmups=warmups, measured=measured, duration=duration):
                with self.assertRaisesRegex(idle.IdleCompareError, "exactly one warmup"):
                    idle.freeze_thresholds(
                        runner, self.records, self.samples,
                        runner_sha256="7" * 64, rationale="Policy")
        self.records[0]["status"] = "failure"
        self.records[0]["failure"] = {"type": "RunnerError", "message": "failure"}
        self.runner["capture_status"] = "failure"
        with self.assertRaisesRegex(idle.IdleCompareError, "completed successful"):
            idle.freeze_thresholds(
                self.runner, self.records, self.samples,
                runner_sha256="7" * 64, rationale="Failure")

    def test_freeze_rejects_control_environment_and_chronology_drift(self):
        control = next(sample for sample in self.samples if sample.role == "control")
        control.manifest["device"]["thermal_state"] = "serious"
        with self.assertRaisesRegex(idle.IdleCompareError, "must remain stable"):
            idle.freeze_thresholds(
                self.runner, self.records, self.samples,
                runner_sha256="7" * 64, rationale="Drift")
        control.manifest["device"]["thermal_state"] = "nominal"
        measured = sorted(
            (sample for sample in self.samples
             if sample.role == "control" and sample.kind == "measured"),
            key=lambda sample: sample.index)
        measured[1].manifest["run"]["recorded_at"] = measured[0].manifest["run"]["recorded_at"]
        with self.assertRaisesRegex(idle.IdleCompareError, "chronology"):
            idle.freeze_thresholds(
                self.runner, self.records, self.samples,
                runner_sha256="7" * 64, rationale="Chronology")

    def test_freeze_rejects_inadmissible_control_power_state(self):
        for sample in self.samples:
            if sample.role == "control":
                sample.manifest["device"]["power_source"] = "battery"
        with self.assertRaisesRegex(idle.IdleCompareError, "external power"):
            idle.freeze_thresholds(
                self.runner, self.records, self.samples,
                runner_sha256="7" * 64, rationale="Power")

    def test_derived_threshold_provenance_is_closed_and_reported(self):
        artifact = idle.freeze_thresholds(
            self.runner, self.records, self.samples,
            runner_sha256="6" * 64, rationale="Authenticated pilot")
        artifact["control_provenance"]["comparison_id"] = "comparison-" + "1" * 12
        artifact["control_provenance"]["order_seed"] = "seed-" + "1" * 16
        for index, item in enumerate(
                artifact["control_provenance"]["evidence_manifests"]):
            item["run_id"] = f"run-{index + 1:012x}"
            item["sha256"] = f"{index + 1:064x}"
        path = self.root / "derived-thresholds.json"
        path.write_text(json.dumps(artifact))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        loaded = idle.load_thresholds(path, digest, duration_seconds=120)
        self.assertEqual(
            loaded["control_provenance"]["pilot_runner_result_sha256"], "6" * 64)
        result = idle.compare(
            self.runner_path, self.runner, self.records, self.samples,
            runner_sha256=hashlib.sha256(self.runner_path.read_bytes()).hexdigest(),
            thresholds=loaded, threshold_path=path, threshold_sha256=digest,
            max_storage_drift=10_000_000, max_pair_start_gap=140,
            max_window_drift_ns=1_000_000)
        self.assertEqual(
            result["threshold_artifact"]["control_provenance"]["kind"],
            "control_only_pilot")
        tampered = json.loads(path.read_text())
        tampered["control_provenance"]["evidence_manifests"][0]["sha256"] = "bad"
        path.write_text(json.dumps(tampered))
        with self.assertRaisesRegex(idle.IdleCompareError, "manifest identity"):
            idle.load_thresholds(
                path, hashlib.sha256(path.read_bytes()).hexdigest(), duration_seconds=120)
        for field, value in (("commit", 1), ("comparison_id", []),
                             ("product_sha256", True)):
            malformed = json.loads(json.dumps(artifact))
            malformed["control_provenance"][field] = value
            path.write_text(json.dumps(malformed))
            with self.subTest(field=field), self.assertRaisesRegex(
                    idle.IdleCompareError, "provenance identity"):
                idle.load_thresholds(
                    path, hashlib.sha256(path.read_bytes()).hexdigest(),
                    duration_seconds=120)
        malformed = json.loads(json.dumps(artifact))
        malformed["control_provenance"]["evidence_manifests"][0]["sample_index"] = True
        path.write_text(json.dumps(malformed))
        with self.assertRaisesRegex(idle.IdleCompareError, "manifest identity"):
            idle.load_thresholds(
                path, hashlib.sha256(path.read_bytes()).hexdigest(), duration_seconds=120)

    def test_derived_threshold_must_use_separate_matching_control(self):
        actual_digest = hashlib.sha256(self.runner_path.read_bytes()).hexdigest()
        artifact = idle.freeze_thresholds(
            self.runner, self.records, self.samples,
            runner_sha256=actual_digest, rationale="Pilot")
        with self.assertRaisesRegex(idle.IdleCompareError, "separate paired"):
            idle.compare(
                self.runner_path, self.runner, self.records, self.samples,
                runner_sha256=actual_digest, thresholds=artifact,
                threshold_path=self.root / "thresholds.json", threshold_sha256="5" * 64,
                max_storage_drift=10_000_000, max_pair_start_gap=140,
                max_window_drift_ns=1_000_000)
        artifact["control_provenance"]["pilot_runner_result_sha256"] = "4" * 64
        with self.assertRaisesRegex(idle.IdleCompareError, "distinct comparison"):
            idle.compare(
                self.runner_path, self.runner, self.records, self.samples,
                runner_sha256=actual_digest, thresholds=artifact,
                threshold_path=self.root / "thresholds.json", threshold_sha256="5" * 64,
                max_storage_drift=10_000_000, max_pair_start_gap=140,
                max_window_drift_ns=1_000_000)
        artifact["control_provenance"]["comparison_id"] = "comparison-" + "2" * 12
        artifact["control_provenance"]["order_seed"] = "seed-" + "2" * 16
        # Changing ignored runner metadata changes its checksum, but unchanged evidence
        # must still be rejected as the same pilot.
        with self.assertRaisesRegex(idle.IdleCompareError, "evidence overlaps"):
            idle.compare(
                self.runner_path, self.runner, self.records, self.samples,
                runner_sha256="3" * 64, thresholds=artifact,
                threshold_path=self.root / "thresholds.json", threshold_sha256="5" * 64,
                max_storage_drift=10_000_000, max_pair_start_gap=140,
                max_window_drift_ns=1_000_000)
        for index, item in enumerate(
                artifact["control_provenance"]["evidence_manifests"]):
            item["run_id"] = f"run-{index + 10:012x}"
            item["sha256"] = f"{index + 10:064x}"
        artifact["control_provenance"]["commit"] = "e" * 40
        with self.assertRaisesRegex(idle.IdleCompareError, "control commit"):
            idle.compare(
                self.runner_path, self.runner, self.records, self.samples,
                runner_sha256=actual_digest, thresholds=artifact,
                threshold_path=self.root / "thresholds.json", threshold_sha256="5" * 64,
                max_storage_drift=10_000_000, max_pair_start_gap=140,
                max_window_drift_ns=1_000_000)
        artifact["control_provenance"]["commit"] = self.runner["commits"]["control"]
        artifact["control_provenance"]["product_sha256"] = "e" * 64
        with self.assertRaisesRegex(idle.IdleCompareError, "product checksum"):
            idle.compare(
                self.runner_path, self.runner, self.records, self.samples,
                runner_sha256=actual_digest, thresholds=artifact,
                threshold_path=self.root / "thresholds.json", threshold_sha256="5" * 64,
                max_storage_drift=10_000_000, max_pair_start_gap=140,
                max_window_drift_ns=1_000_000)

    def test_freeze_cli_is_exclusive_and_protects_evidence(self):
        self.write_runner()
        output = self.root / "frozen.json"
        with mock.patch.object(idle.contract, "validate_manifest"):
            status = idle.main([
                "freeze", "--runner-result", str(self.runner_path),
                "--thresholds-out", str(output), "--rationale", "CLI pilot"])
        self.assertEqual(status, 0)
        self.assertTrue(output.is_file())
        with mock.patch.object(idle.contract, "validate_manifest"):
            self.assertEqual(idle.main([
                "freeze", "--runner-result", str(self.runner_path),
                "--thresholds-out", str(output)]), 1)
        manifest = pathlib.Path(self.records[0]["manifest"])
        with mock.patch.object(idle.contract, "validate_manifest"):
            self.assertEqual(idle.main([
                "freeze", "--runner-result", str(self.runner_path),
                "--thresholds-out", str(manifest)]), 1)

    def test_load_runner_recomputes_schedule_and_revalidates_manifest_contract(self):
        self.write_runner()
        with mock.patch.object(idle.contract, "validate_manifest") as validate:
            runner, records, samples, runner_sha256 = idle.load_runner(self.runner_path)
        self.assertEqual(len(samples), 12)
        self.assertEqual(validate.call_count, 12)
        self.assertEqual(runner_sha256, hashlib.sha256(self.runner_path.read_bytes()).hexdigest())
        self.runner_path.write_text("{}")
        result = idle.compare(
            self.runner_path, runner, records, samples, runner_sha256=runner_sha256,
            thresholds=None, threshold_path=None, threshold_sha256=None,
            max_storage_drift=10_000_000, max_pair_start_gap=140,
            max_window_drift_ns=1_000_000)
        self.assertEqual(result["input"]["sha256"], runner_sha256)
        self.assertNotEqual(result["input"]["sha256"],
                            hashlib.sha256(self.runner_path.read_bytes()).hexdigest())
        records[0]["role"] = "wrong"
        self.runner_path.write_text(json.dumps({**runner, "records": records}))
        with self.assertRaisesRegex(idle.IdleCompareError, "seeded schedule"):
            idle.load_runner(self.runner_path)

    def test_load_runner_rederives_all_runner_and_run_identities(self):
        self.write_runner()
        changed = json.loads(self.runner_path.read_text())
        changed["identities"]["scenario_id"] = "scenario-ffffffffffff"
        self.runner_path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(idle.IdleCompareError, "derive from seed"):
            idle.load_runner(self.runner_path)
        changed = json.loads(json.dumps(self.runner))
        changed["commits"]["candidate"] = changed["commits"]["control"]
        self.runner_path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(idle.IdleCompareError, "distinct exact commit"):
            idle.load_runner(self.runner_path)
        for field, value in (("relative_path", "Data/wrong.json"), ("sha256", "f" * 64),
                             ("bytes", 31)):
            changed = json.loads(json.dumps(self.runner))
            changed["canonical_index"][field] = value
            self.runner_path.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaisesRegex(
                    idle.IdleCompareError, "canonical index identity"):
                idle.load_runner(self.runner_path)
        self.write_runner()
        manifest_path = pathlib.Path(self.records[0]["manifest"])
        manifest = json.loads(manifest_path.read_text())
        manifest["run"]["id"] = "run-ffffffffffff"
        manifest_path.write_text(json.dumps(manifest))
        self.records[0]["manifest_sha256"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        self.write_runner()
        with mock.patch.object(idle.contract, "validate_manifest"):
            with self.assertRaisesRegex(idle.IdleCompareError, "run id does not derive"):
                idle.load_runner(self.runner_path)

    def test_load_runner_binds_manifest_to_canonical_fixture_checksum(self):
        manifest_path = pathlib.Path(self.records[0]["manifest"])
        manifest = json.loads(manifest_path.read_text())
        manifest["scenario"]["fixture_sha256"] = "f" * 64
        manifest_path.write_text(json.dumps(manifest))
        self.records[0]["manifest_sha256"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        self.write_runner()
        with mock.patch.object(idle.contract, "validate_manifest"):
            with self.assertRaisesRegex(idle.IdleCompareError, "canonical idle seed"):
                idle.load_runner(self.runner_path)

    def test_load_runner_rejects_manifest_checksum_and_contract_failure(self):
        self.write_runner()
        self.records[0]["manifest_sha256"] = "0" * 64
        self.write_runner()
        with self.assertRaisesRegex(idle.IdleCompareError, "checksum mismatch"):
            idle.load_runner(self.runner_path)
        self.records[0]["manifest_sha256"] = hashlib.sha256(
            pathlib.Path(self.records[0]["manifest"]).read_bytes()).hexdigest()
        self.write_runner()
        with mock.patch.object(idle.contract, "validate_manifest",
                               side_effect=idle.contract.ContractError("typed idle drift")):
            with self.assertRaisesRegex(idle.IdleCompareError, "typed idle drift"):
                idle.load_runner(self.runner_path)

    def test_load_runner_uses_exact_manifest_bound_summary_bytes(self):
        self.write_runner()
        summary_path = pathlib.Path(self.records[0]["manifest"]).parent / "summary/redacted.json"
        summary = json.loads(summary_path.read_text())
        summary["metrics"]["wakeups_count"] += 1
        summary_path.write_text(json.dumps(summary))
        with mock.patch.object(idle.contract, "validate_manifest"):
            with self.assertRaisesRegex(idle.IdleCompareError, "summary checksum mismatch"):
                idle.load_runner(self.runner_path)

    def test_output_collision_atomic_publish_and_cli_exit_codes(self):
        protected = {self.runner_path.resolve()}
        with self.assertRaisesRegex(idle.IdleCompareError, "collides"):
            idle._publish([(self.runner_path, b"bad")], protected)
        output = self.root / "result.json"
        idle._publish([(output, b"ok")], protected)
        self.assertEqual(output.read_bytes(), b"ok")
        with self.assertRaisesRegex(idle.IdleCompareError, "already exist"):
            idle._publish([(output, b"again")], protected)

        sealed_run = self.samples[0].manifest_path.parent
        with self.assertRaisesRegex(idle.IdleCompareError, "collides"):
            idle._publish([(sealed_run / "unmanifested.json", b"bad")], {sealed_run})

        first, second = self.root / "pair.json", self.root / "pair.csv"
        real_replace = idle.os.replace
        calls = 0

        def fail_second(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected second-output failure")
            return real_replace(source, destination)

        with mock.patch.object(idle.os, "replace", side_effect=fail_second):
            with self.assertRaisesRegex(OSError, "second-output"):
                idle._publish([(first, b"json"), (second, b"csv")], protected)
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())

        raced = self.root / "exclusive.json"
        real_link = idle.os.link

        def race_link(source, destination):
            pathlib.Path(destination).write_bytes(b"competitor")
            return real_link(source, destination)

        with mock.patch.object(idle.os, "link", side_effect=race_link):
            with self.assertRaises(OSError):
                idle._publish([(raced, b"ours")], protected, exclusive=True)
        self.assertEqual(raced.read_bytes(), b"competitor")

        self.write_runner()
        cli_output = self.root / "cli-result.json"
        with mock.patch.object(idle.contract, "validate_manifest"):
            status = idle.main([
                "--runner-result", str(self.runner_path),
                "--max-free-storage-drift-bytes", "10000000",
                "--max-pair-start-gap-seconds", "140",
                "--max-actual-window-drift-ms", "1",
                "--json-out", str(cli_output),
            ])
        self.assertEqual(status, 3)
        result = json.loads(cli_output.read_text())
        self.assertEqual(result["outcome"], "insufficient_data")
        self.assertNotIn(str(self.root), json.dumps(result))


if __name__ == "__main__":
    unittest.main()
