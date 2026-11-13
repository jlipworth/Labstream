from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from _script_loader import load_script
import itertools


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "app-store-screenshots.py"

screenshots = load_script("app_store_screenshots", SCRIPT)


class AppStoreScreenshotTests(unittest.TestCase):
    def test_checked_spec_manifest_covers_every_native_target(self) -> None:
        manifest = screenshots.load_specs()
        self.assertEqual(tuple(manifest["targets"]), screenshots.TARGET_ORDER)
        self.assertEqual(manifest["verifiedAt"], "2026-11-05")
        self.assertTrue(manifest["officialSource"].startswith("https://developer.apple.com/"))
        for target in screenshots.TARGET_ORDER:
            entry = manifest["targets"][target]
            self.assertIn(entry["capturePixels"],
                          manifest["displayClasses"][entry["displayClass"]]["acceptedPixels"])

    def test_spec_records_apple_classes_duo_sizes_and_unknowns(self) -> None:
        specs = screenshots.load_specs()
        classes = specs["displayClasses"]
        self.assertIn([1398, 2034], classes["iphone-duo-outer"]["acceptedPixels"])
        self.assertIn([2007, 2853], classes["iphone-duo-inner"]["acceptedPixels"])
        self.assertIn([1320, 2868], classes["iphone-dynamic-island-large"]["acceptedPixels"])
        self.assertIn([1206, 2622], classes["iphone-dynamic-island-medium"]["acceptedPixels"])
        self.assertIn([2064, 2752], classes["ipad-13"]["acceptedPixels"])
        self.assertEqual(specs["targets"]["iphone69"]["capturePixels"], [1320, 2868])
        self.assertTrue(specs["targets"]["duo-inner"]["fixtureProxy"])
        duo = next(rule for rule in specs["coverageRules"] if rule["id"] == "iphone-duo")
        self.assertEqual(duo["effectiveFrom"], "2027-04-01")
        self.assertTrue(any("April 2027" in note for note in specs["unknowns"]))
        statement = " ".join(specs["appleRequiredStatement"])
        self.assertIn("Dynamic Island (medium display)", statement)
        self.assertIn("iPad 13-inch display", statement)

    def test_every_target_has_named_scenes_and_tvos_has_no_downloads(self) -> None:
        for target in screenshots.TARGET_ORDER:
            scenes = screenshots.live_scenes(target)
            self.assertEqual(scenes[:4], ("home", "library", "detail", "playback"))
            self.assertEqual("downloads" in scenes, target != "tvos")
        self.assertNotIn("playback", screenshots.fixture_scenes("visionos"))
        self.assertNotIn("library", screenshots.fixture_scenes("macos"))
        self.assertIn("library", screenshots.live_scenes("macos"))
        for target in screenshots.MOBILE_TARGETS | {"tvos", "macos"}:
            self.assertIn("playback", screenshots.fixture_scenes(target))

    def test_export_names_order_scenes_and_record_pixels(self) -> None:
        self.assertEqual(screenshots.export_name("iphone69", "detail", (1320, 2868)),
                         "iphone69-03-detail-1320x2868.jpg")

    def test_runner_commands_use_fixture_routes_and_build_once(self) -> None:
        first = screenshots._runner_command("iphone69", "detail", Path("e"), first=True, last=False)
        self.assertEqual(first[:3], ["scripts/agent-mobile-run.sh", "iphone69", "fixture-home-passive"])
        self.assertIn("--keep-booted", first)
        self.assertNotIn("--skip-build", first)
        self.assertIn("plex-orbit", first)
        last = screenshots._runner_command("iphone69", "playback", Path("e"), first=False, last=True)
        self.assertIn("--skip-build", last)
        self.assertNotIn("--keep-booted", last)
        self.assertEqual(last[last.index("--fixture") + 1], "player")
        inner = screenshots._runner_command("duo-inner", "home", Path("e"), first=True, last=True)
        self.assertEqual(inner[1], "duo")
        self.assertEqual(inner[inner.index("--duo-display") + 1], "inner")
        outer = screenshots._runner_command("duo-outer", "home", Path("e"), first=True, last=True)
        self.assertNotIn("--duo-display", outer)
        vision = screenshots._runner_command("visionos", "downloads", Path("e"), first=True, last=True)
        self.assertIn("offline", vision)
        with self.assertRaisesRegex(screenshots.ScreenshotError, "no fixture route"):
            screenshots._runner_command("visionos", "playback", Path("e"), first=True, last=True)
        with self.assertRaisesRegex(screenshots.ScreenshotError, "no fixture route"):
            screenshots._runner_command("tvos", "downloads", Path("e"), first=True, last=True)

    def test_coverage_requires_each_apple_class(self) -> None:
        specs = screenshots.load_specs()
        def manifest(*classes):
            return {"screenshots": [{"displayClass": name} for name in classes]}
        everything_now = ["vision-pro", "iphone-dynamic-island-medium", "iphone-dynamic-island-large",
                          "ipad-13", "apple-tv", "mac"]
        report = screenshots.coverage_report([manifest(*everything_now)], specs,
                                             as_of=screenshots.date(2026, 11, 5))
        self.assertEqual(report["missing"], [])
        self.assertIn({"id": "iphone-duo", "status": "upcoming", "effectiveFrom": "2027-04-01"},
                      report["rules"])
        later = screenshots.coverage_report([manifest(*everything_now)], specs,
                                            as_of=screenshots.date(2027, 4, 1))
        self.assertEqual(later["missing"], ["iphone-duo"])
        strict = screenshots.coverage_report([manifest(*everything_now, "iphone-duo-outer")], specs,
                                             as_of=screenshots.date(2026, 11, 5), include_upcoming=True)
        self.assertEqual(strict["missing"], ["iphone-duo"])
        only_medium = [name for name in everything_now if name != "iphone-dynamic-island-large"]
        report = screenshots.coverage_report([manifest(*only_medium)], specs,
                                             as_of=screenshots.date(2026, 11, 5))
        self.assertEqual(report["missing"], ["iphone-large"])
        fallback = screenshots.coverage_report(
            [manifest(*only_medium, "iphone-face-id-large")], specs, as_of=screenshots.date(2026, 11, 5))
        self.assertEqual(fallback["missing"], [])
        only_large = [name for name in everything_now if name != "iphone-dynamic-island-medium"]
        report = screenshots.coverage_report([manifest(*only_large)], specs,
                                             as_of=screenshots.date(2026, 11, 5))
        self.assertEqual(report["missing"], ["iphone-dynamic-island-medium"])
        ipad_only = screenshots.coverage_report([manifest("ipad-13")], specs, families={"ipad"},
                                                as_of=screenshots.date(2026, 11, 5))
        self.assertEqual(ipad_only["missing"], [])
        self.assertEqual([rule["id"] for rule in ipad_only["rules"]], ["ipad-13"])

    def test_review_media_manifest_preserves_provenance_and_open_capture_gate(self) -> None:
        manifest = json.loads((ROOT / "scripts" / "app-review-media-provenance.json").read_text())
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["catalogRelease"], "open-films-v2")
        self.assertRegex(manifest["sourceManifestSha256"], r"^[0-9a-f]{64}$")
        self.assertIn("not a fresh live-server", manifest["scope"])
        self.assertIn("not yet produced", manifest["storefrontGate"])
        self.assertEqual([film["title"] for film in manifest["openFilms"]], ["Spring", "Wing It!"])
        paths = set()
        for film in manifest["openFilms"]:
            self.assertEqual(film["license"]["spdx"], "CC-BY-4.0")
            self.assertTrue(film["license"]["requiredAttribution"])
            self.assertTrue(film["license"]["excludedMaterial"])
            self.assertEqual(film["source"]["authoritativeHost"], "video.blender.org")
            self.assertEqual(film["source"]["sha256"], film["playable"]["sha256"])
            self.assertTrue(film["playable"]["fullEndCreditsPreserved"])
            self.assertEqual(len(film["derivedArtwork"]), 2)
            for asset in [film["playable"], *film["derivedArtwork"]]:
                self.assertRegex(asset["sha256"], r"^[0-9a-f]{64}$")
                path = Path(asset["relativePath"])
                self.assertFalse(path.is_absolute())
                self.assertNotIn("..", path.parts)
                self.assertNotIn(str(path), paths)
                paths.add(str(path))
                self.assertTrue(asset["transform"])
        self.assertEqual(len(paths), 6)

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

    def _export(self, root: Path, *, checksum: str | None = None, mode: str = "fixture",
                launch: list[str] | None = None, content: str | None = None,
                entries: int = 1) -> Path:
        image = root / "iphone.jpg"
        image.write_bytes(b"synthetic-jpeg")
        default_launch = (["--ui-testing", "--ui-testing-fixture", "browse"]
                          if mode == "fixture" else [])
        payload = {
            "schemaVersion": 2,
            "mode": mode,
            "releaseEligible": False,
            "screenshots": [{
                "target": "iphone",
                "scene": screenshots.SCENE_ORDER[index % 5],
                "displayClass": "iphone-dynamic-island-medium",
                "file": image.name,
                "mode": mode,
                "launchArguments": default_launch if launch is None else launch,
                "content": content or (screenshots.FIXTURE_CONTENT if mode == "fixture"
                                       else screenshots.LIVE_CONTENT),
                "sha256": checksum or hashlib.sha256(image.read_bytes()).hexdigest(),
            } for index in range(entries)],
        }
        (root / "manifest.json").write_text(json.dumps(payload))
        return image

    def test_export_validation_accepts_fixture_and_live_exports(self) -> None:
        for mode in ("fixture", "live"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                self._export(root, mode=mode)
                with mock.patch.object(screenshots, "image_properties", return_value=(1206, 2622, False)):
                    manifest = screenshots.validate_export(root, required_targets=("iphone",))
                self.assertEqual(manifest["mode"], mode)

    def test_export_validation_rejects_invalid_exports(self) -> None:
        cases = (
            ("alpha", {}, (1206, 2622, True), "alpha"),
            ("unaccepted-dimensions", {}, (1000, 1000, False), "not Apple-accepted"),
            ("other-class-size", {}, (1320, 2868, False), "not Apple-accepted"),
            ("checksum", {"checksum": "0" * 64}, (1206, 2622, False), "checksum"),
            ("live-with-flags", {"mode": "live", "launch": ["--ui-testing"]}, (1206, 2622, False),
             "records launch arguments"),
            ("fixture-without-flags", {"launch": []}, (1206, 2622, False), "lacks its fixture flags"),
            ("live-with-fixture-wording", {"mode": "live", "content": screenshots.FIXTURE_CONTENT},
             (1206, 2622, False), "content wording"),
            ("fixture-with-live-wording", {"content": screenshots.LIVE_CONTENT},
             (1206, 2622, False), "content wording"),
        )
        for name, options, properties, message in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                self._export(root, **options)
                with mock.patch.object(screenshots, "image_properties", return_value=properties):
                    with self.assertRaisesRegex(screenshots.ScreenshotError, message):
                        screenshots.validate_export(root, required_targets=("iphone",))

    def test_export_validation_rejects_self_certified_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self._export(root)
            payload = json.loads((root / "manifest.json").read_text())
            payload["releaseEligible"] = True
            (root / "manifest.json").write_text(json.dumps(payload))
            with self.assertRaisesRegex(screenshots.ScreenshotError, "release eligible"):
                screenshots.validate_export(root)

    def test_live_start_launches_without_arguments(self) -> None:
        calls: list[list[str]] = []
        def fake_run(command, *, output=None):
            calls.append(command)
            if command[:3] == ["scripts/worktree-sim.sh", "--platform", "iphone69"]:
                return "SIM\n"
            if command[:4] == ["xcrun", "simctl", "list", "devices"]:
                return json.dumps({"devices": {"r": [{"udid": "SIM", "state": "Shutdown"}]}})
            return ""
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(screenshots, "_run", side_effect=fake_run), \
                mock.patch.object(screenshots.subprocess, "run"), \
                mock.patch.object(screenshots.time, "sleep"), \
                mock.patch.object(screenshots, "_app_pid", return_value=42), \
                mock.patch.object(screenshots, "_installed_version", return_value={"buildNumber": "1"}), \
                mock.patch.object(screenshots, "load_live_config", return_value={"k": "v"}), \
                mock.patch.object(screenshots, "reset_review_progress",
                                  side_effect=lambda config: calls.append(["reset"]) or 3) as reset:
            session = screenshots.live_start("iphone69", Path(directory), allow_simulator=True)
            state = json.loads((session / "live-session.json").read_text())
            skipped = screenshots.live_start("iphone69", Path(directory) / "skip", allow_simulator=True,
                                             reset_progress=False)
            skipped_state = json.loads((skipped / "live-session.json").read_text())
        launch = next(command for command in calls if command[2:3] == ["launch"])
        self.assertEqual(launch, ["xcrun", "simctl", "launch", "SIM", screenshots.BUNDLE_ID])
        self.assertEqual(state["launchArguments"], [])
        self.assertEqual(state["pid"], 42)
        # Watch progress is cleared once, before the app launches, and the session records it.
        reset.assert_called_once_with({"k": "v"})
        self.assertLess(calls.index(["reset"]), calls.index(launch))
        self.assertEqual((state["watchProgressReset"], state["watchProgressItemsCleared"]), (True, 3))
        self.assertFalse(skipped_state["watchProgressReset"])
        self.assertNotIn("watchProgressItemsCleared", skipped_state)

    def test_review_progress_reset_clears_only_touched_items_and_logs_out(self) -> None:
        config = {"LABSTREAM_LIVE_AUTH_SERVER": "https://review.invalid",
                  "LABSTREAM_LIVE_AUTH_USERNAME": "reviewer", "LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret"}
        calls: list[tuple[str, str, str | None]] = []
        def fake_request(server, method, path, *, token=None, query=None, body=None):
            calls.append((method, path, token))
            if path == "/Users/AuthenticateByName":
                self.assertEqual(body, {"Username": "reviewer", "Pw": "s3cret"})
                return {"AccessToken": "tok", "User": {"Id": "user"}}
            if path == "/Items":
                return {"Items": [
                    {"Id": "resumed", "UserData": {"PlaybackPositionTicks": 5}},
                    {"Id": "watched", "UserData": {"Played": True, "PlayCount": 1, "IsFavorite": True}},
                    {"Id": "untouched", "UserData": {"PlaybackPositionTicks": 0, "Played": False}},
                    {"UserData": {"Played": True}},
                ]}
            return None
        with mock.patch.object(screenshots, "_review_request", side_effect=fake_request):
            self.assertEqual(screenshots.reset_review_progress(config), 3)
        self.assertEqual([call[:2] for call in calls], [
            ("POST", "/Users/AuthenticateByName"), ("GET", "/Items"),
            ("DELETE", "/UserPlayedItems/resumed"), ("DELETE", "/UserPlayedItems/watched"),
            ("DELETE", "/UserFavoriteItems/watched"), ("POST", "/Sessions/Logout")])
        self.assertTrue(all(token == "tok" for _, _, token in calls[1:]))

    def test_review_progress_reset_keeps_named_titles_watched(self) -> None:
        config = {"LABSTREAM_LIVE_AUTH_SERVER": "https://review.invalid",
                  "LABSTREAM_LIVE_AUTH_USERNAME": "reviewer", "LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret",
                  "LABSTREAM_LIVE_WATCHED_TITLES": " Sample Series , Other "}
        calls: list[tuple[str, str]] = []
        def fake_request(server, method, path, *, token=None, query=None, body=None):
            calls.append((method, path))
            if path == "/Users/AuthenticateByName":
                return {"AccessToken": "tok", "User": {"Id": "user"}}
            if path == "/Items":
                return {"Items": [
                    {"Id": "series", "Name": "Sample Series", "UserData": {"Played": False}},
                    {"Id": "episode", "Name": "Subtitles and Chapters", "SeriesName": "Sample Series",
                     "UserData": {"Played": True, "PlayCount": 1}},
                    {"Id": "already", "Name": "Other", "UserData": {"Played": True}},
                    {"Id": "film", "Name": "Spring", "UserData": {"PlaybackPositionTicks": 9}},
                ]}
            return None
        with mock.patch.object(screenshots, "_review_request", side_effect=fake_request):
            self.assertEqual(screenshots.reset_review_progress(config), 2)
        self.assertEqual(calls[2:-1], [("POST", "/UserPlayedItems/series"),
                                       ("DELETE", "/UserPlayedItems/film")])

    def test_review_progress_reset_logs_out_after_a_failure_and_never_echoes_values(self) -> None:
        config = {"LABSTREAM_LIVE_AUTH_SERVER": "https://review.invalid",
                  "LABSTREAM_LIVE_AUTH_USERNAME": "reviewer", "LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret"}
        paths: list[str] = []
        def fake_request(server, method, path, *, token=None, query=None, body=None):
            paths.append(path)
            if path == "/Users/AuthenticateByName":
                return {"AccessToken": "tok", "User": {"Id": "user"}}
            if path == "/Items":
                raise screenshots.ScreenshotError("review server refused GET Items (HTTP 500)")
            return None
        with mock.patch.object(screenshots, "_review_request", side_effect=fake_request):
            with self.assertRaises(screenshots.ScreenshotError) as raised:
                screenshots.reset_review_progress(config)
        self.assertEqual(paths[-1], "/Sessions/Logout")
        for private in ("review.invalid", "reviewer", "s3cret", "tok"):
            self.assertNotIn(private, str(raised.exception))
        with mock.patch.object(screenshots, "_review_request", return_value={}):
            with self.assertRaisesRegex(screenshots.ScreenshotError, "no session"):
                screenshots.reset_review_progress(config)

    def test_live_start_refuses_a_foreign_booted_simulator(self) -> None:
        def fake_run(command, *, output=None):
            if command[0] == "scripts/worktree-sim.sh":
                return "SIM\n"
            return json.dumps({"devices": {"r": [{"udid": "OTHER", "state": "Booted"}]}})
        with mock.patch.object(screenshots, "_run", side_effect=fake_run):
            with self.assertRaisesRegex(screenshots.ScreenshotError, "another simulator is booted"):
                screenshots.live_start("ipad", Path("ignored"), allow_simulator=True)
        with self.assertRaisesRegex(screenshots.ScreenshotError, "--allow-simulator"):
            screenshots.live_start("ipad", Path("ignored"), allow_simulator=False)
        with self.assertRaisesRegex(screenshots.ScreenshotError, "simulator targets"):
            screenshots.live_start("macos", Path("ignored"), allow_simulator=True)

    def test_live_shot_rejects_a_relaunched_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            (session / "live-session.json").write_text(json.dumps(
                {"target": "ipad", "pid": 42, "app": {}, "launchArguments": []}))
            with mock.patch.object(screenshots, "_simulator_udid", return_value="SIM"), \
                    mock.patch.object(screenshots, "_booted_udids", return_value={"SIM"}), \
                    mock.patch.object(screenshots, "_app_pid", return_value=43):
                with self.assertRaisesRegex(screenshots.ScreenshotError, "without arguments"):
                    screenshots.live_shot(session, "home")

    def test_live_config_reads_private_file_and_environment_without_echoing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app-review-live.env"
            path.write_text("# comment\nLABSTREAM_LIVE_AUTH_SERVER=https://review.example.invalid\n"
                            "export LABSTREAM_LIVE_AUTH_USERNAME='demo'\n"
                            "LABSTREAM_LIVE_AUTH_PASSWORD=file-secret\nUNRELATED=x\n")
            config = screenshots.load_live_config(path, {"LABSTREAM_LIVE_AUTH_PASSWORD": "env-secret"})
            self.assertEqual(config["LABSTREAM_LIVE_AUTH_USERNAME"], "demo")
            self.assertEqual(config["LABSTREAM_LIVE_AUTH_PASSWORD"], "env-secret")
            self.assertNotIn("UNRELATED", config)
            path.write_text("LABSTREAM_LIVE_AUTH_SERVER=http://plain.example.invalid\n"
                            "LABSTREAM_LIVE_AUTH_USERNAME=u\nLABSTREAM_LIVE_AUTH_PASSWORD=p\n")
            with self.assertRaisesRegex(screenshots.ScreenshotError, "HTTPS"):
                screenshots.load_live_config(path, {})
            with self.assertRaises(screenshots.ScreenshotError) as missing:
                screenshots.load_live_config(Path(directory) / "absent.env", {"LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret"})
            self.assertIn("blocked", str(missing.exception))
            self.assertNotIn("s3cret", str(missing.exception))

    def test_every_simulator_target_has_a_live_catalog_test(self) -> None:
        self.assertEqual(set(screenshots.LIVE_TESTS), set(screenshots.SIMULATOR_TARGETS))
        for test_id in screenshots.LIVE_TESTS.values():
            target, cls, _ = test_id.split("/")
            self.assertTrue((ROOT / target / f"{cls}.swift").is_file(), test_id)

    def test_dry_run_live_manifest_is_labelled_and_rejected_for_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            (session / "export").mkdir()
            (session / "live-session.json").write_text(json.dumps(
                {"target": "iphone", "pid": 42, "app": {}, "launchArguments": [], "dryRun": True}))
            frame = session / "frame.png"
            frame.write_bytes(b"frame")
            def convert(source, destination, target, pixels):
                destination.write_bytes(b"jpeg")
            with mock.patch.object(screenshots, "_simulator_udid", return_value="SIM"), \
                    mock.patch.object(screenshots, "_booted_udids", return_value={"SIM"}), \
                    mock.patch.object(screenshots, "_app_pid", return_value=42), \
                    mock.patch.object(screenshots, "_stable_frame", return_value=frame), \
                    mock.patch.object(screenshots, "_convert_to_store_jpeg", side_effect=convert), \
                    mock.patch.object(screenshots, "image_properties", return_value=(1206, 2622, False)), \
                    mock.patch.object(screenshots, "_git_dirty", return_value=False):
                screenshots.live_shot(session, "home")
                manifest = json.loads((session / "export" / "manifest.json").read_text())
                self.assertTrue(manifest["dryRun"])
                self.assertIn("dry run", manifest["dryRunNote"])
                self.assertFalse(manifest["releaseEligible"])
                code = screenshots.main(["coverage", str(session / "export"), "--live-only",
                                         "--target", "iphone"])
            self.assertEqual(code, 2)

    def test_live_capture_reads_the_duo_displays_explicitly(self) -> None:
        self.assertEqual(screenshots.LIVE_DISPLAYS, {"duo-outer": "primary", "duo-inner": "primary-1"})

    def test_stable_frame_requires_two_identical_frames(self) -> None:
        frames = iter([b"a", b"b", b"b"])
        def fake_run(command, *, output=None):
            Path(command[-1]).write_bytes(next(frames))
            return ""
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(screenshots, "_run", side_effect=fake_run), \
                mock.patch.object(screenshots.time, "sleep"):
            frame = screenshots._stable_frame("SIM", "primary", Path(directory))
            self.assertEqual(frame.read_bytes(), b"b")
        counter = itertools.count()
        def changing_frame(command, *, output=None):
            Path(command[-1]).write_bytes(str(next(counter)).encode())
            return ""
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(screenshots, "_run", side_effect=changing_frame), \
                mock.patch.object(screenshots.time, "sleep"):
            with self.assertRaisesRegex(screenshots.ScreenshotError, "never settled"):
                screenshots._stable_frame("SIM", None, Path(directory))

    def test_platform_runners_keep_fixture_and_exact_worktree_simulator_contracts(self) -> None:
        for target in screenshots.TARGET_ORDER:
            for index, scene in enumerate(screenshots.fixture_scenes(target)):
                command = screenshots._runner_command(target, scene, Path("evidence"),
                                                      first=index == 0, last=False)
                if target in screenshots.SIMULATOR_TARGETS:
                    self.assertIn("--allow-simulator", command)
                self.assertIn("fixture", " ".join(command))
        vision_runner = (ROOT / "scripts" / "agent-sim-run.sh").read_text()
        self.assertIn("worktree-sim.sh --platform visionos id", vision_runner)
        self.assertIn("DerivedData-agent-visionos", vision_runner)
        mobile_runner = (ROOT / "scripts" / "agent-mobile-run.sh").read_text()
        self.assertIn("iphone69", mobile_runner)
        self.assertIn("--display=$capture_display", mobile_runner.replace('"', ""))

    def test_runners_reject_non_fixture_launch_arguments(self) -> None:
        for runner in ("agent-mobile-run.sh", "agent-tvos-run.sh", "agent-sim-run.sh",
                       "agent-macos-run.sh"):
            text = (ROOT / "scripts" / runner).read_text()
            self.assertIn("Rejected launch argument", text, runner)
            self.assertIn("^--ui-testing-[a-z0-9-]+$", text, runner)

    def test_visible_fixture_catalog_uses_store_safe_merchandising_copy(self) -> None:
        catalog = (ROOT / "Labstream" / "Shared" / "Debug" / "DebugUIFixtureCatalog.swift").read_text()
        self.assertNotIn('title: "Fixture Shelf', catalog)
        self.assertNotIn('title: "Shelf \\(shelf)', catalog)
        self.assertIn('"Recommended For You"', catalog)
        self.assertIn('"Glass Horizon"', catalog)


if __name__ == "__main__":
    unittest.main()
