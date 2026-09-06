import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "agent-playback-run.py"
spec = importlib.util.spec_from_file_location("agent_playback_run", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class AgentPlaybackRunnerTests(unittest.TestCase):
    def invoke(self, summary, *, failure=None):
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(summary).encode())
            with mock.patch.object(runner, "ROOT", Path(directory)), mock.patch.object(sys, "platform", "darwin"), \
                 mock.patch.object(sys, "argv", [str(SCRIPT), "fixture-consent"]), \
                 mock.patch.object(runner, "run", side_effect=failure, return_value=0) as execute, \
                 mock.patch.object(subprocess, "run", return_value=completed), mock.patch("sys.stdout", output):
                code = runner.main()
            value = json.loads(output.getvalue())
            self.assertNotIn(directory, output.getvalue())
            if execute.call_args:
                command = execute.call_args.args[0]
                self.assertIn("-only-testing:LabstreamMacTests/PlaybackAgentEvidenceTests", command)
                self.assertTrue(any(arg.startswith("PRODUCT_BUNDLE_IDENTIFIER=org.labstream.Labstream.dev.") for arg in command))
                self.assertFalse(any("--vp-probe-allow-live" in arg for arg in command))
            return code, value

    def test_only_complete_fixture_assertions_pass(self):
        summary = dict(result="Passed", passedTests=4, failedTests=0, skippedTests=0)
        code, value = self.invoke(summary)
        self.assertEqual(code, 0)
        self.assertEqual(value["visibleAttachment"], "unknown")
        for bad in [dict(summary, passedTests=0), dict(summary, failedTests=1), dict(summary, skippedTests=1)]:
            self.assertEqual(self.invoke(bad)[0], 1)

    def test_timeout_is_blocked_and_does_not_echo_error(self):
        code, value = self.invoke({}, failure=subprocess.TimeoutExpired("private-sentinel", 1))
        self.assertEqual(code, 2)
        self.assertNotIn("private-sentinel", json.dumps(value))


if __name__ == "__main__":
    unittest.main()
