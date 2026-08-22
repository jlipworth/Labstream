from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "app-store-screenshots.py"

spec = importlib.util.spec_from_file_location("app_store_screenshots", SCRIPT)
assert spec and spec.loader
screenshots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screenshots)


class AppStoreScreenshotTests(unittest.TestCase):
    def test_checked_spec_manifest_covers_every_native_target(self) -> None:
        manifest = screenshots.load_specs()
        self.assertEqual(tuple(manifest["targets"]), screenshots.TARGET_ORDER)
        self.assertEqual(manifest["verifiedAt"], "2026-08-21")
        self.assertTrue(manifest["officialSource"].startswith("https://developer.apple.com/"))
        for target in screenshots.TARGET_ORDER:
            self.assertIn(
                manifest["targets"][target]["capturePixels"],
                manifest["targets"][target]["acceptedPixels"],
            )

    def test_capture_fails_closed_without_simulator_lease_assertion(self) -> None:
        with self.assertRaisesRegex(screenshots.ScreenshotError, "--allow-simulator"):
            screenshots.capture(("iphone",), Path("ignored"), allow_simulator=False)

    def test_mac_only_capture_does_not_require_simulator_lease(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(screenshots, "_run", side_effect=screenshots.ScreenshotError("stop")):
                with self.assertRaisesRegex(screenshots.ScreenshotError, "stop"):
                    screenshots.capture(("macos",), Path(directory), allow_simulator=False,
                                        allow_dirty=True)

    def test_capture_rejects_dirty_source_without_review_escape_hatch(self) -> None:
        with mock.patch.object(screenshots.subprocess, "check_output", return_value=" M source\n"):
            with self.assertRaisesRegex(screenshots.ScreenshotError, "uncommitted source tree"):
                screenshots.capture(("macos",), Path("ignored"), allow_simulator=False)

    def _export(self, root: Path, *, checksum: str | None = None) -> Path:
        image = root / "iphone.jpg"
        image.write_bytes(b"synthetic-jpeg")
        payload = {
            "schemaVersion": 1,
            "screenshots": [{
                "target": "iphone",
                "file": image.name,
                "sha256": checksum or hashlib.sha256(image.read_bytes()).hexdigest(),
            }],
        }
        (root / "manifest.json").write_text(json.dumps(payload))
        return image

    def test_export_validation_rejects_alpha_even_at_an_accepted_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self._export(root)
            with mock.patch.object(screenshots, "image_properties", return_value=(1206, 2622, True)):
                with self.assertRaisesRegex(screenshots.ScreenshotError, "alpha"):
                    screenshots.validate_export(root, required_targets=("iphone",))

    def test_export_validation_rejects_unaccepted_dimensions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self._export(root)
            with mock.patch.object(screenshots, "image_properties", return_value=(1000, 1000, False)):
                with self.assertRaisesRegex(screenshots.ScreenshotError, "not Apple-accepted"):
                    screenshots.validate_export(root, required_targets=("iphone",))

    def test_export_validation_binds_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self._export(root, checksum="0" * 64)
            with mock.patch.object(screenshots, "image_properties", return_value=(1206, 2622, False)):
                with self.assertRaisesRegex(screenshots.ScreenshotError, "checksum"):
                    screenshots.validate_export(root, required_targets=("iphone",))

    def test_platform_runners_keep_fixture_and_exact_worktree_simulator_contracts(self) -> None:
        commands = {
            target: screenshots._runner_command(target, Path("evidence"))
            for target in screenshots.TARGET_ORDER
        }
        for target in screenshots.SIMULATOR_TARGETS:
            self.assertIn("fixture", " ".join(commands[target]))
        self.assertIn("--allow-simulator", commands["iphone"])
        self.assertIn("--allow-simulator", commands["ipad"])
        self.assertIn("--allow-simulator", commands["tvos"])
        self.assertIn("--allow-simulator", commands["visionos"])
        vision_runner = (ROOT / "scripts" / "agent-sim-run.sh").read_text()
        self.assertIn("worktree-sim.sh --platform visionos id", vision_runner)
        self.assertIn("DerivedData-agent-visionos", vision_runner)

    def test_visible_fixture_catalog_uses_store_safe_merchandising_copy(self) -> None:
        catalog = (ROOT / "Labstream" / "Shared" / "Debug" / "DebugUIFixtureCatalog.swift").read_text()
        self.assertNotIn('title: "Fixture Shelf', catalog)
        self.assertNotIn('title: "Shelf \\(shelf)', catalog)
        self.assertIn('"Recommended For You"', catalog)
        self.assertIn('"Glass Horizon"', catalog)


if __name__ == "__main__":
    unittest.main()
