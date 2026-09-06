import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "playback-evidence.py"
spec = importlib.util.spec_from_file_location("playback_evidence", SCRIPT)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class PlaybackEvidenceTests(unittest.TestCase):
    def test_sustained_progress_is_scoped(self):
        result = evidence.evaluate(evidence.fixture())
        self.assertEqual(result["status"], "passed")
        for field in ("videoDecision", "audioDecision", "visibleAttachment", "hardwareDecode", "serverCleanup"):
            self.assertEqual(result[field], "unknown")

    def test_three_seconds_then_paused_or_waiting_or_frozen_playing_fail(self):
        for phase in ("paused", "waiting", "playing"):
            payload = evidence.fixture()
            for sample in payload["samples"][4:]:
                sample.update(positionSeconds=3, phase=phase)
            self.assertEqual(evidence.evaluate(payload)["reason"], "sustained_nonprogress")

    def test_endpoint_seek_is_not_progress(self):
        payload = evidence.fixture()
        payload["samples"][-1]["positionSeconds"] += 600
        self.assertEqual(evidence.evaluate(payload)["reason"], "timeline_discontinuity")

    def test_gap_and_short_window_block(self):
        for samples, reason in (([0, 60], "observation_gap"), (list(range(4)), "insufficient_observation")):
            payload = evidence.fixture()
            payload["samples"] = [payload["samples"][i] for i in samples]
            self.assertEqual(evidence.evaluate(payload)["reason"], reason)

    def test_cancel_and_failure_never_pass(self):
        for phase, status in (("cancelled", "blocked"), ("failed", "failed")):
            payload = evidence.fixture()
            payload["samples"][-1]["phase"] = phase
            self.assertEqual(evidence.evaluate(payload)["status"], status)

    def test_reject_invalid_schema_secret_fields_and_stale_generation(self):
        mutations = [
            lambda p: p.update(token="private-sentinel"),
            lambda p: p.update(schemaVersion=2),
            lambda p: p.update(generation=True),
            lambda p: p.update(holdSeconds=float("nan")),
            lambda p: p.update(backend="https://private-sentinel"),
            lambda p: p["samples"][1].update(generation=2),
            lambda p: p["samples"][1].update(elapsedSeconds=0),
            lambda p: p["samples"][1].update(positionSeconds=float("inf")),
            lambda p: p["samples"][1].update(url="private-sentinel"),
        ]
        for mutate in mutations:
            payload = copy.deepcopy(evidence.fixture())
            mutate(payload)
            with self.assertRaises(evidence.InvalidEvidence):
                evidence.evaluate(payload)

    def test_cli_fixture_and_private_input_errors(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--fixture"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["evidenceKind"], "synthetic")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private-sentinel.json"
            for data in ('{"private-sentinel":1}', '{"schemaVersion":1,"schemaVersion":1}', 'x' * (evidence.MAX_BYTES + 1)):
                path.write_text(data)
                result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("private-sentinel", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
