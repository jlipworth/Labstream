"""Hermetic native CLI checks; real decoder verdicts remain opt-in evidence."""
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"),
                     "requires native Apple media frameworks")
class DVDecoderInitProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = pathlib.Path(cls.temp.name) / "dv-init-probe"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(ROOT / "scripts/dv-decoder-init-probe.swift"),
                        "-o", str(cls.binary)], check=True, capture_output=True, timeout=120)

    def run_probe(self, *arguments):
        return subprocess.run([str(self.binary), *map(str, arguments)],
                              capture_output=True, text=True, timeout=15)

    def test_dictionary_contrast_preserves_other_extensions_and_input(self):
        result = self.run_probe("--self-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Self-test passed", result.stdout)

    def test_requires_one_argument(self):
        for arguments in [(), ("one", "two")]:
            result = self.run_probe(*arguments)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")

    def test_missing_private_path_is_not_printed(self):
        private = pathlib.Path(self.temp.name) / "private-source-marker.mp4"
        result = self.run_probe(private)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(str(private), result.stdout + result.stderr)
        self.assertNotIn(private.name, result.stdout + result.stderr)

    def test_oversized_input_rejected_before_asset_loading(self):
        oversized = pathlib.Path(self.temp.name) / "oversized.mp4"
        with oversized.open("wb") as handle:
            handle.truncate(1_048_577)
        result = self.run_probe(oversized)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(str(oversized), result.stdout + result.stderr)
