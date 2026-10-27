"""Regression package admission, bounded execution, and explicit result scopes."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("regression", Path(__file__).parents[1] / "playback-regression.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def put(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        runner.write_json(path, value)
        return path

    def test_default_plan_has_six_controlled_cases_and_no_simulator(self):
        commands = runner.planned_commands(self.root, [])
        self.assertEqual(len(runner.CASES), 6)
        self.assertEqual([command[0] for command in commands], ["core-generate", "core-offline", "core-host"])
        self.assertNotIn("simctl", str(commands))
        self.assertTrue(all(timeout > 0 for _, _, timeout in commands))
        self.assertEqual(commands[-1][1][3], "run-host")

    def test_missing_duplicate_extra_cells_fail_closed(self):
        for rows in ([], [{"case": "clean"}], [{"case": name} for name in runner.CASES] + [{"case": "clean"}]):
            with self.subTest(rows=rows), self.assertRaises(runner.InvalidEvidence):
                runner.exact_cells(rows, "case", runner.CASES)
        runner.exact_cells([{"case": name} for name in reversed(runner.CASES)], "case", runner.CASES)

    def test_defect_detection_is_not_clean_playback(self):
        rows = []
        measurements = {}
        for case, expected in runner.CASES.items():
            rid = "host-" + str(uuid.uuid4())
            self.put(f"runs/{rid}/capture.json", {})
            rows.append(dict(case=case, runID=rid, failures=expected))
            measurements[rid] = dict(failures=expected, audioEnvelopeOffsetSeconds=.1)
        self.put("host-results.json", list(reversed(rows)))
        module = SimpleNamespace(analyze=lambda directory, reference, rid, baseline: measurements[rid])
        with patch.object(runner, "load_module", return_value=module):
            result = runner.detector_results(self.root, "host-results.json", "host")
        self.assertTrue(all(row["status"] == "pass" for row in result))
        self.assertEqual(sum(row["cleanPlayback"] for row in result), 1)
        self.assertTrue(all(row["expectation"] == "detect-injected-defect" for row in result[1:]))

    def test_claimed_classification_must_match_raw_reanalysis(self):
        rows = []
        for case, expected in runner.CASES.items():
            rid = "host-" + str(uuid.uuid4())
            self.put(f"runs/{rid}/capture.json", {})
            rows.append(dict(case=case, runID=rid, failures=expected))
        self.put("host-results.json", rows)
        module = SimpleNamespace(analyze=lambda *args: dict(failures=["audio-gap"], audioEnvelopeOffsetSeconds=.1))
        with patch.object(runner, "load_module", return_value=module), self.assertRaises(runner.InvalidEvidence):
            runner.detector_results(self.root, "host-results.json", "host")

    def test_matrix_requires_successful_detector_preflight(self):
        manifest = self.put("matrix-manifest.json", {"profiles": [{"name": "one"}]})
        self.put("matrix-results.json", dict(schema=1, status="complete", runID=str(uuid.uuid4()),
                 results=[dict(name="one", status="signal-pass")], manifestSHA256=runner.digest(manifest)))
        with patch.object(runner, "load_module", return_value=SimpleNamespace(PROFILES=[("one",)])), \
             patch.object(runner, "detector_results", return_value=[{"status": "failure"}]), \
             self.assertRaisesRegex(runner.InvalidEvidence, "preflight"):
            runner.matrix_results(self.root)

    def multichannel_fixture(self):
        import numpy as np
        media = self.root / "fixture.m4s"
        media.write_bytes(b"fixture")
        self.put("manifest.json", dict(schema=1, profiles=[dict(name="aac", status="generated", files={media.name: runner.digest(media)})]))
        rows = []
        for channels in (2, 6):
            rid = str(uuid.uuid4())
            self.put(f"runs/{rid}/capture.json", dict(schema=1, runID=rid, channels=channels, sampleRate=48000,
                     observedChannelLayoutTags=[1], audio=[dict(pts=i / 10, frames=4800, offset=i * 4800 * channels * 4) for i in range(100)]))
            np.zeros((480000, channels), dtype="<f4").tofile(self.root / "runs" / rid / "audio.f32le")
            rows.append(dict(profile="aac", requestedChannels=channels, runID=rid, status="routing-pass", failures=[]))
        self.put("results.json", rows)
        return rows, SimpleNamespace(PROFILES=[("aac",)], measure=lambda _: {"failures": []})

    def test_multichannel_requires_complete_cells_and_raw_bytes(self):
        rows, module = self.multichannel_fixture()
        with patch.object(runner, "load_module", return_value=module):
            self.assertEqual(len(runner.multichannel_results(self.root)), 2)
            (self.root / "runs" / rows[0]["runID"] / "audio.f32le").write_bytes(b"")
            with self.assertRaisesRegex(runner.InvalidEvidence, "truncated"):
                runner.multichannel_results(self.root)
            self.put("results.json", [dict(profile="aac", status="fixture-invalid")])
            results = runner.multichannel_results(self.root)
            self.assertEqual(len(results), 2)
            self.assertTrue(all(row["status"] == "inconclusive" for row in results))
            self.put("results.json", [])
            with self.assertRaisesRegex(runner.InvalidEvidence, "missing"):
                runner.multichannel_results(self.root)

    def test_multichannel_layout_and_discontinuous_time_cannot_pass(self):
        rows, module = self.multichannel_fixture()
        manifest = self.root / "runs" / rows[1]["runID"] / "capture.json"
        data = runner.read_json(manifest)
        data["observedChannelLayoutTags"] = []
        runner.write_json(manifest, data)
        with patch.object(runner, "load_module", return_value=module), self.assertRaisesRegex(runner.InvalidEvidence, "mapping"):
            runner.multichannel_results(self.root)
        data["observedChannelLayoutTags"] = [1]
        data["audio"][2]["pts"] += .02
        runner.write_json(manifest, data)
        with patch.object(runner, "load_module", return_value=module), self.assertRaisesRegex(runner.InvalidEvidence, "metadata"):
            runner.multichannel_results(self.root)

    def external_fixture(self):
        rid = str(uuid.uuid4())
        rows = [dict(case="jellyfin/original", status="pass", scope="transport-only", reason="completed")]
        artifact = self.put("evidence.json", dict(schemaVersion=1, runID=rid, results=rows))
        source = "Labstream/Shared/Debug/DebugPlaybackSignalCapture.swift"
        data = dict(schemaVersion=1, kind="native-evidence", runID=rid, capturedAtUTC=datetime.now(timezone.utc).isoformat(),
                    sourceSHA256={source: runner.digest(runner.ROOT / source)},
                    app=dict(executableSHA256="a" * 64, pid=123, exactExecutableVerified=True),
                    artifact=dict(path=artifact.name, sha256=runner.digest(artifact)), results=rows)
        path = self.put("envelope.json", data)
        return path, data

    def test_external_import_preserves_transport_scope_and_requires_bound_results(self):
        path, data = self.external_fixture()
        rows = runner.external_results(path, data["runID"])
        self.assertEqual(rows[0]["scope"], "transport-only")
        data["results"][0]["status"] = "failure"
        runner.write_json(path, data)
        with self.assertRaisesRegex(runner.InvalidEvidence, "differ"):
            runner.external_results(path, data["runID"])

    def test_external_rejects_stale_id_time_source_and_identity(self):
        for mutation in ("run", "time", "source", "identity", "artifact"):
            with self.subTest(mutation=mutation):
                path, data = self.external_fixture()
                expected_id = data["runID"]
                if mutation == "run": expected_id = str(uuid.uuid4())
                if mutation == "time": data["capturedAtUTC"] = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
                if mutation == "source": data["sourceSHA256"][next(iter(data["sourceSHA256"]))] = "f" * 64
                if mutation == "identity": data["app"]["exactExecutableVerified"] = False
                if mutation == "artifact": data["artifact"]["sha256"] = "f" * 64
                runner.write_json(path, data)
                with self.assertRaises(runner.InvalidEvidence): runner.external_results(path, expected_id)

    def test_unsupported_capture_never_turns_package_green(self):
        self.assertEqual(runner.summarize(dict(results=[]))["status"], "inconclusive")
        for status in ("unsupported-capture", "inconclusive", "failure"):
            result = runner.summarize(dict(results=[dict(status=status)]))
            self.assertNotEqual(result["status"], "pass")

    def test_json_rejects_duplicate_keys_and_nonfinite_values(self):
        for payload in ('{"status":"failure","status":"pass"}', '{"value":NaN}'):
            path = self.root / "malformed.json"
            path.write_text(payload)
            with self.assertRaises(runner.InvalidEvidence): runner.read_json(path)

    def test_cleanup_removes_only_owned_media_and_keeps_compact_evidence(self):
        for name in ("capture.json", "analysis.json", "audio.f32le", "reference.rgba", "clip.m4s", "signal-host"):
            (self.root / name).write_bytes(b"test")
        runner.clean_raw(self.root)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["analysis.json", "capture.json"])

    def test_execute_has_real_timeout_and_clears_inherited_probe_flags(self):
        with patch.dict("os.environ", {"SIGNAL_LAB_CHANNELS": "6"}):
            outcome = runner.execute([sys.executable, "-c", "import os; assert 'SIGNAL_LAB_CHANNELS' not in os.environ"], self.root / "environment.log", 5)
        self.assertEqual(outcome["exitCode"], 0)
        outcome = runner.execute([sys.executable, "-c", "import time; time.sleep(10)"], self.root / "timeout.log", .05)
        self.assertEqual(outcome["execution"], "timeout")
        self.assertLess(outcome["elapsedSeconds"], 6)

    def test_saved_report_rejects_changed_artifacts(self):
        rid = str(uuid.uuid4())
        directory = self.root / rid
        directory.mkdir()
        artifact = directory / "evidence.json"
        artifact.write_text("{}")
        rows = [dict(case="core", status="inconclusive", scope="capture-harness", reason="test")]
        admitted = directory / "admitted-results.json"
        runner.write_json(admitted, rows)
        data = dict(schemaVersion=1, state="complete", runID=rid,
                    sourceSHA256={name: runner.digest(runner.ROOT / name) for name in runner.SOURCE_PATHS},
                    suites=["core"], rawCapturesRetained=False,
                    artifacts={artifact.name: runner.digest(artifact), admitted.name: runner.digest(admitted)}, results=rows)
        runner.write_json(directory / "run.json", data)
        self.assertEqual(runner.validate_saved(directory)["runID"], rid)
        artifact.write_text('{"changed":true}')
        with self.assertRaisesRegex(runner.InvalidEvidence, "changed"): runner.validate_saved(directory)

    def test_timeout_kills_descendant_even_after_leader_exits(self):
        child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
        pidfile = self.root / "descendant.pid"
        parent = ("import subprocess,sys,time,pathlib; "
                  f"p=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                  f"pathlib.Path({str(pidfile)!r}).write_text(str(p.pid)); time.sleep(30)")
        outcome = runner.execute([sys.executable, "-c", parent], self.root / "descendant.log", .3)
        self.assertEqual(outcome["execution"], "timeout")
        pid = int(pidfile.read_text())
        state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), state)

    def test_green_saved_package_requires_full_requested_grid(self):
        rid = str(uuid.uuid4())
        directory = self.root / rid
        directory.mkdir()
        rows = [dict(case="host/clean", status="pass", scope="decoded-reference", reason="test")]
        admitted = directory / "admitted-results.json"
        runner.write_json(admitted, rows)
        data = dict(schemaVersion=1, state="complete", runID=rid,
                    sourceSHA256={name: runner.digest(runner.ROOT / name) for name in runner.SOURCE_PATHS},
                    suites=["core"], rawCapturesRetained=False,
                    commands=[dict(name=name, exitCode=0, execution="completed") for name, _, _ in runner.planned_commands(directory, [])],
                    artifacts={admitted.name: runner.digest(admitted)}, results=rows)
        runner.write_json(directory / "run.json", data)
        with self.assertRaisesRegex(runner.InvalidEvidence, "cells"):
            runner.validate_saved(directory)

    def test_saved_external_summary_cannot_promote_bound_inconclusive(self):
        path, envelope = self.external_fixture()
        rows = runner.external_results(path, envelope["runID"])
        rows[0]["case"] = "external/0/jellyfin/original"
        rows[0]["scope"] = "decoded-audio-reference"
        data = dict(suites=["core"], results=rows,
                    externalImports=[dict(path=path.name, runID=envelope["runID"])])
        with self.assertRaisesRegex(runner.InvalidEvidence, "external summary"):
            runner.validate_complete_package(self.root, data)

    def test_saved_matrix_summary_cannot_promote_bound_signal_failure(self):
        self.put("matrix/matrix-results.json", dict(schema=1, status="complete",
                 results=[dict(name="one", status="signal-mismatch", failures=["audio-gap"])]))
        self.put("matrix/matrix-manifest.json", {})
        self.put("matrix/host-results.json", [])
        data = dict(suites=["core", "matrix"], results=[dict(case="matrix/one", status="pass")])
        with patch.object(runner, "load_module", return_value=SimpleNamespace(PROFILES=[("one",)])), \
             self.assertRaisesRegex(runner.InvalidEvidence, "cannot support"):
            runner.validate_complete_package(self.root, data)

    def test_saved_core_scope_preserves_defect_detection(self):
        summaries = []
        for suite, filename in (("offline", "self-test-results.json"), ("host", "host-results.json")):
            rows = []
            for case, findings in runner.CASES.items():
                rid = str(uuid.uuid4())
                rows.append(dict(case=case, runID=rid, failures=findings))
                capture = dict(schema=1, runID=rid, sampleRate=48000, channels=2, width=160, height=90, position=10,
                               audio=[dict(pts=i / 10, host=i / 10, player=i / 10, frames=4800, offset=i * 4800 * 8) for i in range(100)],
                               video=[dict(pts=i / 30, host=i / 30, player=i / 30, offset=i * 160 * 90 * 4) for i in range(300)])
                self.put(f"core/runs/{rid}/capture.json", capture)
                self.put(f"core/runs/{rid}/analysis.json", dict(runID=rid, failures=findings))
                summaries.append(runner.record(suite + "/" + case, "pass", "offline-detector" if suite == "offline" else "decoded-reference",
                                 "expected classification", expectation="clean-playback" if case == "clean" else "detect-injected-defect",
                                 expectedFindings=findings, findings=findings, captureRunID=rid, cleanPlayback=case == "clean"))
            self.put("core/" + filename, rows)
        self.put("core/fixture.json", {})
        data = dict(suites=["core"], results=summaries)
        runner.validate_complete_package(self.root, data)
        summaries[1]["cleanPlayback"] = True
        with self.assertRaisesRegex(runner.InvalidEvidence, "scope or expectation"):
            runner.validate_complete_package(self.root, data)


if __name__ == "__main__": unittest.main()
