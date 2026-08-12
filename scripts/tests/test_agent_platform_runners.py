import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class AgentPlatformRunnerTests(unittest.TestCase):
    def run_script(self, name: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(ROOT / "scripts" / name), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

    def test_mobile_help_advertises_passive_and_semantic_scenarios(self) -> None:
        result = self.run_script("agent-mobile-run.sh", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture-home-passive", result.stdout)
        self.assertIn("fixture-detail-semantic", result.stdout)

    def test_tvos_help_advertises_home_and_local_player_scenarios(self) -> None:
        result = self.run_script("agent-tvos-run.sh", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture-home-semantic", result.stdout)
        self.assertIn("fixture-player-basic", result.stdout)

    def test_simulator_runners_require_explicit_lease_assertion(self) -> None:
        for name, arguments in (
            ("agent-mobile-run.sh", ("iphone", "fixture-detail-semantic")),
            ("agent-tvos-run.sh", ("fixture-home-semantic",)),
        ):
            with self.subTest(name=name):
                result = self.run_script(name, *arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn("without --allow-simulator", result.stderr)

    def test_semantic_runners_preserve_xcresult_and_machine_summary(self) -> None:
        mobile = (ROOT / "scripts" / "agent-mobile-run.sh").read_text()
        tv = (ROOT / "scripts" / "agent-tvos-run.sh").read_text()
        for source in (mobile, tv):
            self.assertIn("xcresulttool get test-results summary", source)
            self.assertIn("xcresulttool export attachments", source)
            self.assertIn("test-summary.json", source)
            self.assertIn("run.json", source)


if __name__ == "__main__":
    unittest.main()
