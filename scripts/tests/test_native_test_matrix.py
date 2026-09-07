import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "native-test-matrix.py"
MANIFEST = ROOT / "scripts" / "native-test-matrix.json"

spec = importlib.util.spec_from_file_location("native_test_matrix", SCRIPT)
assert spec and spec.loader
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class NativeTestMatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = matrix.load_manifest(MANIFEST)

    def test_git_discovery_includes_deleted_and_both_renamed_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()
            git("init", "-q")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            old = "Labstream/Platforms/Mobile/Old.swift"
            deleted = "Labstream/Shared/Delete\nMe.swift"
            new = "Labstream/Platforms/macOS/New.swift"
            for name in (old, deleted):
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture")
            git("add", ".")
            git("commit", "-qm", "baseline")
            base = git("rev-parse", "HEAD")
            (repo / new).parent.mkdir(parents=True)
            (repo / old).rename(repo / new)
            (repo / deleted).unlink()
            expected = sorted([old, new, deleted])
            moved_lanes = matrix.affected_lanes(self.manifest, [old, new])
            self.assertIn("mobile-build", moved_lanes)
            self.assertIn("macos-build", moved_lanes)
            deleted_lanes = matrix.affected_lanes(self.manifest, [deleted])
            for lane in ("mobile-build", "macos-build", "tvos-build", "visionos-build"):
                self.assertIn(lane, deleted_lanes)
            self.assertEqual(matrix.changed_paths(repo, base, "HEAD", True), expected)
            git("add", "-A")
            git("commit", "-qm", "move and delete")
            self.assertEqual(matrix.changed_paths(repo, base, "HEAD", False), expected)

    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

    def test_manifest_is_valid_and_full_tier_keeps_vision_gap_visible(self) -> None:
        lanes = self.manifest["tiers"]["full"]
        self.assertIn("visionos-hosted", lanes)
        self.assertIn("mobile-ui-smoke", lanes)
        self.assertEqual(self.manifest["lanes"]["visionos-hosted"]["status"], "planned")

    def test_platform_root_is_exclusive_after_source_split(self) -> None:
        lanes = matrix.affected_lanes(
            self.manifest, ["Labstream/Platforms/tvOS/Player/TVChrome.swift"]
        )
        self.assertEqual(lanes, ["tvos-build", "tvos-hosted", "tvos-ui-smoke"])

    def test_current_shared_app_root_selects_every_platform(self) -> None:
        lanes = matrix.affected_lanes(
            self.manifest, ["Labstream/Shared/Player/PlaybackController.swift"]
        )
        for expected in (
            "visionos-build",
            "visionos-hosted",
            "mobile-build",
            "mobile-hosted",
            "mobile-ui-smoke",
            "tvos-build",
            "tvos-hosted",
            "tvos-ui-smoke",
            "macos-build",
            "macos-hosted",
        ):
            self.assertIn(expected, lanes)

    def test_mobile_ui_test_root_selects_semantic_smoke_lane(self) -> None:
        lanes = matrix.affected_lanes(
            self.manifest,
            ["LabstreamMobileUITests/LabstreamMobileFixtureUITests.swift"],
        )
        self.assertEqual(lanes, ["mobile-build", "mobile-ui-smoke"])

    def test_download_capability_excludes_tvos_lanes(self) -> None:
        lanes = matrix.affected_lanes(
            self.manifest,
            ["Labstream/Capabilities/Downloads/Core/DownloadManager.swift"],
        )
        self.assertIn("visionos-build", lanes)
        self.assertIn("mobile-build", lanes)
        self.assertIn("macos-build", lanes)
        self.assertNotIn("tvos-build", lanes)
        self.assertNotIn("tvos-hosted", lanes)

    def test_live_probes_are_not_part_of_pmskit_correctness_command(self) -> None:
        command = self.manifest["lanes"]["pmskit-correctness"]["command"]
        self.assertIn("--skip", command)
        self.assertIn("Live.*ProbeTests", command)

    def test_tv_event_swizzle_is_explicit_opt_in(self) -> None:
        source = (
            ROOT / "Labstream" / "Platforms" / "tvOS" / "Debug" / "TVInputEvidence.swift"
        ).read_text()
        player_tests = (
            ROOT / "LabstreamTVUITests" / "LabstreamTVPlayerTests.swift"
        ).read_text()
        self.assertIn('arguments.contains("--tv-input-evidence")', source)
        self.assertNotIn('arguments.contains("--no-tv-input-evidence")', source)
        self.assertIn('"--tv-input-evidence"', player_tests)

    def test_tv_ui_lanes_use_the_ui_only_test_plan(self) -> None:
        for lane in ("tvos-ui-smoke", "tvos-ui-full"):
            command = self.manifest["lanes"][lane]["command"]
            self.assertIn("-testPlan", command)
            self.assertIn("LabstreamTVUITests", command)

    def test_affected_json_reports_simulator_lane_as_blocked_without_id(self) -> None:
        result = self.run_script(
            "affected",
            "--changed-file",
            "Labstream/Platforms/iOS/MobileRoot.swift",
            "--format",
            "json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        hosted = next(lane for lane in payload["lanes"] if lane["name"] == "mobile-hosted")
        self.assertFalse(hosted["executable"])
        self.assertIn("simulator lease", hosted["reason"])

    def test_run_requires_one_explicit_lane(self) -> None:
        result = self.run_script("smoke", "--run")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--run requires exactly one --lane", result.stderr)

    def test_simulator_lane_requires_explicit_lease_confirmation(self) -> None:
        result = self.run_script(
            "affected",
            "--changed-file",
            "LabstreamTVUITests/LabstreamTVLaunchTests.swift",
            "--tvos-sim-id",
            "00000000-0000-0000-0000-000000000000",
            "--run",
            "--lane",
            "tvos-ui-smoke",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --allow-simulator", result.stderr)

    def test_simulator_execution_rejects_id_not_owned_by_this_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / ".simid-tvos").write_text("OWNED-SIM\n")
            with self.assertRaisesRegex(matrix.MatrixError, "not this worktree"):
                matrix.require_worktree_simulator("tvos", "OTHER-SIM", repo)

    def test_simulator_execution_requires_worktree_sim_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(
                matrix.MatrixError, "worktree-sim.sh --platform tvos setup"
            ):
                matrix.require_worktree_simulator("tvos", "SIM-1", Path(directory))

    def test_simulator_execution_requires_the_owned_id_to_be_booted(self) -> None:
        inventory = {"devices": {"runtime": [{"udid": "SIM-1", "state": "Shutdown"}]}}
        completed = subprocess.CompletedProcess([], 0, json.dumps(inventory), "")
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / ".simid-iphone").write_text("SIM-1\n")
            with mock.patch.object(matrix.subprocess, "run", return_value=completed):
                with self.assertRaisesRegex(matrix.MatrixError, "is not Booted"):
                    matrix.require_worktree_simulator("iphone", "SIM-1", repo)

    def test_simulator_execution_rejects_an_additional_booted_simulator(self) -> None:
        inventory = {
            "devices": {
                "runtime": [
                    {"udid": "SIM-1", "state": "Booted"},
                    {"udid": "SIM-2", "state": "Booted"},
                ]
            }
        }
        completed = subprocess.CompletedProcess([], 0, json.dumps(inventory), "")
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / ".simid-tvos").write_text("SIM-1\n")
            with mock.patch.object(matrix.subprocess, "run", return_value=completed):
                with self.assertRaisesRegex(matrix.MatrixError, "one-simulator invariant"):
                    matrix.require_worktree_simulator("tvos", "SIM-1", repo)

    def test_owned_sole_booted_simulator_passes_read_only_inventory_check(self) -> None:
        inventory = {"devices": {"runtime": [{"udid": "SIM-1", "state": "Booted"}]}}
        completed = subprocess.CompletedProcess([], 0, json.dumps(inventory), "")
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / ".simid-tvos").write_text("SIM-1\n")
            with mock.patch.object(matrix.subprocess, "run", return_value=completed) as run:
                matrix.require_worktree_simulator("tvos", "SIM-1", repo)
        run.assert_called_once_with(
            ["xcrun", "simctl", "list", "devices", "--json"], text=True, capture_output=True
        )

    def test_invalid_manifest_fails_before_planning(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            data = json.loads(MANIFEST.read_text())
            data["tiers"]["smoke"].append("not-a-lane")
            path.write_text(json.dumps(data))
            result = self.run_script("smoke", "--manifest", str(path))
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown lanes", result.stderr)


if __name__ == "__main__":
    unittest.main()
