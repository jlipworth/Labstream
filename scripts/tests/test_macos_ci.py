import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
VALIDATOR = REPO / "scripts" / "validate-macos-pipeline.py"


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

    def test_validator_passes_the_real_pipeline(self):
        result = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                str(REPO / ".woodpecker" / "macos.yml"),
                "--default-branch",
                "main",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_rejects_a_duplicate_top_level_when_block(self):
        # A duplicated top-level `when:` mapping key is valid YAML (last-wins on
        # duplicate keys), so Woodpecker would honor the second, looser block while
        # this line-scanning validator would otherwise only ever see the first,
        # restrictive one. The validator must reject the file outright instead of
        # silently validating the wrong block.
        pipeline = (REPO / ".woodpecker" / "macos.yml").read_text()
        smuggled = pipeline + (
            "\nwhen:\n"
            "  event: [manual, push]\n"
            "  branch: '*'\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "macos.yml"
            path.write_text(smuggled)
            result = subprocess.run(
                ["python3", str(VALIDATOR), str(path), "--default-branch", "main"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate top-level when", result.stderr)

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
