import subprocess
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class MacOSCIContractTests(unittest.TestCase):
    def test_pipeline_is_manual_main_only_and_labelled(self):
        pipeline = (REPO / ".woodpecker" / "macos.yml").read_text()
        self.assertIn("event: [manual]", pipeline)
        self.assertIn("branch: main", pipeline)
        self.assertNotIn("pull_request", pipeline)
        self.assertIn("platform: darwin/arm64", pipeline)
        self.assertIn("backend: local", pipeline)
        self.assertIn("purpose: mac-ci", pipeline)

    def test_wrapper_declares_isolation_and_unsigned_build_contract(self):
        wrapper = (REPO / "scripts" / "ci-macos-apple-platforms.sh").read_text()
        self.assertIn("MACOS_CI_MIN_FREE_GB:-100", wrapper)
        self.assertIn("-destination 'generic/platform=visionOS Simulator'", wrapper)
        self.assertIn("-destination 'generic/platform=iOS Simulator'", wrapper)
        self.assertEqual(wrapper.count("CODE_SIGNING_ALLOWED=NO"), 2)
        self.assertIn("-resultBundlePath", wrapper)
        self.assertIn("--scratch-path", wrapper)
        self.assertIn("trap cleanup EXIT", wrapper)
        self.assertIn("check_result_bundle", wrapper)

    def test_help_is_available_without_a_macos_host(self):
        result = subprocess.run(
            [str(REPO / "scripts" / "ci-macos-apple-platforms.sh"), "--help"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        self.assertIn("--preflight", result.stdout)
        self.assertIn("MACOS_CI_OUTPUT_DIR", result.stdout)


if __name__ == "__main__":
    unittest.main()
