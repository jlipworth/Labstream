from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ui_checkpoint_driver as driver  # noqa: E402

# A stand-in UI test: reaches two checkpoints, waits for each acknowledgement, prints a secret.
FAKE_TEST = r'''
import os, sys, time, pathlib
d = pathlib.Path(os.environ["LABSTREAM_UI_CHECKPOINT_DIR"])
for name in ("home", "detail"):
    (d / f"{name}.ready").touch()
    for _ in range(200):
        done = d / f"{name}.done"
        if done.exists():
            if done.read_text().startswith("fail"):
                print("FAILED", name); sys.exit(1)
            break
        time.sleep(0.05)
    else:
        sys.exit(3)
print("Type 'hunter22' into SecureTextField and https://review.example.invalid")
'''


class CheckpointDriverTests(unittest.TestCase):
    def run_fake(self, directory: Path, on_checkpoint):
        return driver.run([sys.executable, "-c", FAKE_TEST], checkpoint_dir=directory / "cp",
                          on_checkpoint=on_checkpoint, log_path=directory / "test.log",
                          env={driver.CHECKPOINT_ENV: str(directory / "cp")},
                          secrets=["hunter22", "https://review.example.invalid", ""], timeout=60)

    def test_checkpoints_are_captured_in_order_and_secrets_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            captured: list[str] = []
            code, seen = self.run_fake(directory, captured.append)
            log = (directory / "test.log").read_text()
        self.assertEqual(code, 0)
        self.assertEqual(seen, ["home", "detail"])
        self.assertEqual(captured, ["home", "detail"])
        self.assertNotIn("hunter22", log)
        self.assertNotIn("review.example.invalid", log)
        self.assertIn("<redacted>", log)

    def test_capture_failure_fails_the_test(self) -> None:
        def explode(name: str) -> None:
            raise RuntimeError(f"no display for hunter22 at {name}")
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            code, seen = self.run_fake(directory, explode)
            log = (directory / "test.log").read_text()
        self.assertEqual(code, 1)
        self.assertEqual(seen, [])
        self.assertNotIn("hunter22", log)

    def test_runner_environment_uses_test_runner_prefix(self) -> None:
        self.assertEqual(driver.runner_environment({"A": "1"}), {"TEST_RUNNER_A": "1"})


if __name__ == "__main__":
    unittest.main()
