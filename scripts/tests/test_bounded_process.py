import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "bounded_process", Path(__file__).resolve().parents[1] / "bounded_process.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BoundedProcessTests(unittest.TestCase):
    def test_exited_leader_does_not_leave_term_resistant_child(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory) / "heartbeat"
            child = ("import signal,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                     f"p=Path({str(heartbeat)!r}); "
                     "exec('while True:\\n p.write_text(str(time.monotonic()))\\n time.sleep(.02)')")
            leader = subprocess.Popen(
                [sys.executable, "-c", "import subprocess,sys,time; "
                 f"subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(30)"],
                start_new_session=True)
            sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                        start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not heartbeat.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(heartbeat.exists())
                module.terminate_process_group(leader, grace=.15)
                time.sleep(.1)
                last = heartbeat.read_text()
                time.sleep(.15)
                self.assertEqual(last, heartbeat.read_text())
                self.assertIsNone(sentinel.poll())
            finally:
                module.terminate_process_group(leader, grace=0)
                sentinel.terminate()
                sentinel.wait()

    def test_already_exited_process_is_safe(self):
        process = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
        self.assertEqual(process.wait(), 0)
        module.terminate_process_group(process, grace=0)

    def test_agent_runner_cleans_group_on_cancellation(self):
        script = Path(__file__).resolve().parents[1] / "agent-playback-run.py"
        runner_spec = importlib.util.spec_from_file_location("agent_cleanup_test", script)
        runner = importlib.util.module_from_spec(runner_spec)
        runner_spec.loader.exec_module(runner)
        process = mock.MagicMock()
        process.__enter__.return_value = process
        process.wait.side_effect = KeyboardInterrupt
        with mock.patch.object(runner.subprocess, "Popen", return_value=process), \
             mock.patch.object(runner, "terminate_process_group") as cleanup:
            with self.assertRaises(KeyboardInterrupt):
                runner.run(["fixture"], None, 1)
            cleanup.assert_called_once_with(process)

    def test_generic_runner_timeout_and_success(self):
        script = Path(__file__).resolve().parents[1] / "run-bounded-command.py"
        with tempfile.TemporaryDirectory() as directory:
            for command, expected in (("pass", 0), ("import time; time.sleep(30)", 124)):
                result = subprocess.run(
                    [sys.executable, str(script), "--timeout", "1", "--output",
                     str(Path(directory) / "output"), "--", sys.executable, "-c", command],
                    timeout=10)
                self.assertEqual(result.returncode, expected)
