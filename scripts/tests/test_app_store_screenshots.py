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


class MacLiveLaneTests(unittest.TestCase):
    """The macOS live lane: isolated host app, Accessibility driver, window-only capture."""

    CONFIG = {"LABSTREAM_LIVE_AUTH_SERVER": "https://review.invalid",
              "LABSTREAM_LIVE_AUTH_USERNAME": "reviewer", "LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret"}

    def _session(self, directory: str, **extra) -> Path:
        session = Path(directory)
        (session / "export").mkdir(exist_ok=True)
        (session / "live-session.json").write_text(json.dumps(
            {"target": "macos", "pid": 42, "app": {}, "launchArguments": [],
             "executable": "/staged/Labstream.app/Contents/MacOS/Labstream", **extra}))
        return session

    def test_start_launches_the_staged_isolated_app_without_arguments(self) -> None:
        calls: list[list[str]] = []
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Labstream.app"
            app.mkdir()
            def fake_run(command, *, output=None):
                calls.append(command)
                return f"bundle:   org.example.dev\napp:      {app}\n"
            with mock.patch.object(screenshots, "_run", side_effect=fake_run), \
                    mock.patch.object(screenshots, "_mac_app_pid", return_value=42) as app_pid, \
                    mock.patch.object(screenshots, "_mac_driver", return_value={}) as driver, \
                    mock.patch.object(screenshots, "_mac_app_version", return_value={"buildNumber": "7"}), \
                    mock.patch.object(screenshots, "load_live_config", return_value=self.CONFIG), \
                    mock.patch.object(screenshots, "reset_review_progress",
                                      side_effect=lambda config: calls.append(["reset"]) or 2):
                # No simulator lease assertion is needed for the host target.
                session = screenshots.live_start("macos", Path(directory) / "out", allow_simulator=False,
                                                 dry_run=True)
            state = json.loads((session / "live-session.json").read_text())
        launch = ["scripts/deploy-macos-to-host.sh", "--no-build", "--launch"]
        self.assertEqual(calls, [["reset"], launch])
        self.assertNotIn("--use-production-bundle-id", launch)
        app_pid.assert_called_with(str(app / "Contents" / "MacOS" / "Labstream"))
        self.assertEqual(driver.call_args.args[:2], (42, "preflight"))
        self.assertTrue(session.name.endswith("-live-macos"))
        self.assertEqual((state["target"], state["pid"], state["launchArguments"]), ("macos", 42, []))
        self.assertEqual(state["app"], {"buildNumber": "7"})
        self.assertEqual((state["dryRun"], state["watchProgressReset"], state["watchProgressItemsCleared"]),
                         (True, True, 2))

    def test_start_fails_closed_and_quits_when_a_host_permission_is_missing(self) -> None:
        for code, wording in (("accessibility_not_trusted", "blocked: Accessibility permission"),
                              ("screen_recording_not_permitted", "blocked: Screen & System Audio Recording")):
            with tempfile.TemporaryDirectory() as directory:
                app = Path(directory) / "Labstream.app"
                app.mkdir()
                blocked = screenshots.MacDriverError(screenshots.MAC_BLOCKED[code], code, {})
                with mock.patch.object(screenshots, "_run", return_value=f"app: {app}\n"), \
                        mock.patch.object(screenshots, "_mac_app_pid", return_value=42), \
                        mock.patch.object(screenshots, "_mac_driver", side_effect=blocked), \
                        mock.patch.object(screenshots, "_mac_quit") as quit_app:
                    with self.assertRaisesRegex(screenshots.ScreenshotError, wording) as raised:
                        screenshots.live_start("macos", Path(directory) / "out", allow_simulator=False,
                                               reset_progress=False)
                self.assertIn("the app that runs this command", str(raised.exception))
                quit_app.assert_called_once_with(42)
                self.assertFalse((Path(directory) / "out").exists())

    def test_start_is_blocked_without_a_staged_app(self) -> None:
        failure = screenshots.ScreenshotError("command failed (1): deploy")
        with mock.patch.object(screenshots, "_run", side_effect=failure):
            with self.assertRaisesRegex(screenshots.ScreenshotError, "blocked: no staged isolated Mac app"):
                screenshots.live_start("macos", Path("ignored"), allow_simulator=False,
                                       reset_progress=False)

    def test_driver_commands_and_errors_never_carry_values(self) -> None:
        command = screenshots._mac_driver_command(42, "set-value", "--label", "Password",
                                                  "--env", "LABSTREAM_LIVE_AUTH_PASSWORD", timeout=20)
        self.assertEqual(command[1:], ["live", "set-value", "--pid", "42", "--timeout", "20",
                                       "--label", "Password", "--env", "LABSTREAM_LIVE_AUTH_PASSWORD"])
        def completed(code, payload):
            return mock.Mock(returncode=code, stdout=json.dumps(payload) + "\n", stderr="")
        with mock.patch.object(screenshots, "_mac_driver_binary"), \
                mock.patch.object(screenshots.subprocess, "run") as run:
            run.return_value = completed(0, {"status": "passed", "matches": 1})
            self.assertEqual(screenshots._mac_driver(
                42, "count", "--label", "Play", env={"LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret"})["matches"], 1)
            self.assertEqual(run.call_args.kwargs["env"]["LABSTREAM_LIVE_AUTH_PASSWORD"], "s3cret")
            self.assertNotIn("s3cret", run.call_args.args[0])
            run.return_value = completed(1, {"status": "failed", "errorCode": "target_not_found"})
            with self.assertRaises(screenshots.MacDriverError) as failed:
                screenshots._mac_driver(42, "set-value", "--env", "LABSTREAM_LIVE_AUTH_PASSWORD",
                                        step="enter the password", env={"LABSTREAM_LIVE_AUTH_PASSWORD": "s3cret"})
            self.assertEqual(str(failed.exception),
                             "macOS live step failed: enter the password (target_not_found)")
            self.assertEqual(failed.exception.code, "target_not_found")
            run.return_value = completed(2, {"status": "blocked", "errorCode": "accessibility_not_trusted"})
            with self.assertRaisesRegex(screenshots.ScreenshotError, "blocked: Accessibility permission"):
                screenshots._mac_driver(42, "press", "--label", "Play")
            run.return_value = mock.Mock(returncode=1, stdout="", stderr="crash")
            with self.assertRaisesRegex(screenshots.ScreenshotError, r"window \(driver_failed\)"):
                screenshots._mac_driver(42, "window")

    def test_app_pid_matches_only_the_exact_staged_executable(self) -> None:
        listing = (" 10 /staged/Labstream.app/Contents/MacOS/Labstream-helper\n"
                   " 11 /Applications/Labstream.app/Contents/MacOS/Labstream\n"
                   " 12 /staged/Labstream.app/Contents/MacOS/Labstream -NSDocumentRevisionsDebugMode YES\n")
        with mock.patch.object(screenshots, "_run", return_value=listing):
            self.assertEqual(screenshots._mac_app_pid("/staged/Labstream.app/Contents/MacOS/Labstream"), 12)
            self.assertIsNone(screenshots._mac_app_pid("/other/Labstream.app/Contents/MacOS/Labstream"))

    def _size_window(self, *, window, resize_results, aerospace="/opt/bin/aerospace"):
        """Run _mac_size_window with scripted driver results; return (driver calls, floating calls)."""
        calls: list[tuple[str, ...]] = []
        results = iter(resize_results)
        def driver(pid, operation, *arguments, **kwargs):
            calls.append((operation, *arguments))
            if operation == "window":
                return window
            outcome = next(results)
            if outcome is not None:
                raise screenshots.MacDriverError("failed", outcome, {})
            return {}
        with mock.patch.object(screenshots, "_mac_driver", side_effect=driver), \
                mock.patch.object(screenshots.shutil, "which", return_value=aerospace), \
                mock.patch.object(screenshots.subprocess, "run") as run:
            try:
                screenshots._mac_size_window(42, screenshots.load_specs())
            finally:
                self.floating = [call.args[0] for call in run.call_args_list]
        return calls

    def test_window_is_sized_in_points_from_the_display_scale(self) -> None:
        window = {"scale": 2, "width": 900, "height": 700, "windowID": 77}
        calls = self._size_window(window=window, resize_results=[None])
        self.assertEqual(calls[-1], ("resize", "--width", "1280", "--height", "800"))
        self.assertEqual(self.floating, [])
        # Already the right size: nothing is moved.
        sized = {"scale": 2, "width": 1280.0, "height": 800.0, "windowID": 77}
        self.assertEqual(self._size_window(window=sized, resize_results=[]), [("window",)])
        # A 1x display needs the full 2560 x 1600 points.
        calls = self._size_window(window={**window, "scale": 1}, resize_results=[None])
        self.assertEqual(calls[-1], ("resize", "--width", "2560", "--height", "1600"))
        with self.assertRaisesRegex(screenshots.ScreenshotError, "blocked: display scale 3"):
            self._size_window(window={**window, "scale": 3}, resize_results=[])

    def test_tiled_window_is_floated_only_through_aerospace_and_otherwise_blocks(self) -> None:
        window = {"scale": 2, "width": 1276, "height": 1405, "windowID": 77}
        calls = self._size_window(window=window, resize_results=["window_size_mismatch", None])
        self.assertEqual([call[0] for call in calls], ["window", "resize", "resize"])
        self.assertEqual(self.floating, [["/opt/bin/aerospace", "layout", "floating", "--window-id", "77"]])
        with self.assertRaisesRegex(screenshots.ScreenshotError, "blocked: the Labstream window did not keep"):
            self._size_window(window=window, resize_results=["window_size_mismatch"], aerospace=None)
        self.assertEqual(self.floating, [])
        with self.assertRaisesRegex(screenshots.ScreenshotError, "blocked: the Labstream window did not keep"):
            self._size_window(window=window,
                              resize_results=["window_size_mismatch", "window_size_mismatch"])
        # Any other failure is reported as itself, without touching the window manager.
        with self.assertRaises(screenshots.MacDriverError):
            self._size_window(window=window, resize_results=["window_unavailable"])
        self.assertEqual(self.floating, [])

    def test_stable_frame_captures_the_window_only_until_two_frames_match(self) -> None:
        frames = iter([b"a", b"b", b"b"])
        commands: list[tuple[str, ...]] = []
        def driver(pid, operation, *arguments, **kwargs):
            commands.append((operation, *arguments))
            Path(arguments[1]).write_bytes(next(frames))
            return {}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(screenshots, "_mac_driver", side_effect=driver), \
                mock.patch.object(screenshots.time, "sleep"):
            frame = screenshots._mac_stable_frame(42, Path(directory))
            self.assertEqual(frame.read_bytes(), b"b")
        self.assertTrue(all(command[0] == "capture" and command[-2:] == ("--matte", "101014")
                            for command in commands))
        counter = itertools.count()
        def changing(pid, operation, *arguments, **kwargs):
            Path(arguments[1]).write_bytes(str(next(counter)).encode())
            return {}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(screenshots, "_mac_driver", side_effect=changing), \
                mock.patch.object(screenshots.time, "sleep"):
            with self.assertRaisesRegex(screenshots.ScreenshotError, "never settled"):
                screenshots._mac_stable_frame(42, Path(directory))

    def test_shot_rejects_a_relaunched_or_background_app(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = self._session(directory)
            with mock.patch.object(screenshots, "_mac_app_pid", return_value=43):
                with self.assertRaisesRegex(screenshots.ScreenshotError, "without arguments"):
                    screenshots.live_shot(session, "home")
            with mock.patch.object(screenshots, "_mac_app_pid", return_value=42), \
                    mock.patch.object(screenshots, "_mac_driver", return_value={"frontmost": False}), \
                    mock.patch.object(screenshots, "_mac_stable_frame") as capture:
                with self.assertRaisesRegex(screenshots.ScreenshotError, "blocked: Labstream could not be made"):
                    screenshots.live_shot(session, "home")
                capture.assert_not_called()

    def test_shot_exports_a_validated_live_entry_and_checks_the_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = self._session(directory, dryRun=True)
            frame = session / "frame.png"
            frame.write_bytes(b"frame")
            def convert(source, destination, target, pixels):
                destination.write_bytes(b"jpeg")
            with mock.patch.object(screenshots, "_mac_app_pid", return_value=42), \
                    mock.patch.object(screenshots, "_mac_driver", return_value={"frontmost": True}), \
                    mock.patch.object(screenshots, "_mac_size_window") as size, \
                    mock.patch.object(screenshots, "_mac_stable_frame", return_value=frame), \
                    mock.patch.object(screenshots, "_convert_to_store_jpeg", side_effect=convert), \
                    mock.patch.object(screenshots, "_git_dirty", return_value=False):
                with mock.patch.object(screenshots, "image_properties", return_value=(2560, 1600, False)):
                    destination = screenshots.live_shot(session, "library")
                    manifest = json.loads((session / "export" / "manifest.json").read_text())
                with mock.patch.object(screenshots, "image_properties", return_value=(2552, 2810, False)):
                    with self.assertRaisesRegex(screenshots.ScreenshotError, "not an accepted size"):
                        screenshots.live_shot(session, "home")
            size.assert_called_with(42, mock.ANY)
        self.assertEqual(destination.name, "macos-02-library-2560x1600.jpg")
        entry = manifest["screenshots"][0]
        self.assertEqual((entry["target"], entry["mode"], entry["launchArguments"]), ("macos", "live", []))
        self.assertTrue(manifest["dryRun"] and manifest["launchedWithoutArguments"])

    def _drive(self, directory: str, *, signed_out: bool):
        events: list[tuple[str, ...]] = []
        environments: list[dict[str, str]] = []
        def driver(pid, operation, *arguments, timeout=15, step=None, env=None):
            events.append((operation, *arguments))
            environments.append(env or {})
            return {}
        def count(pid, *query):
            if "performance.login.backend-picker" in query:
                return 1 if signed_out else 0
            if "performance.library-visibility.done" in query:
                return 1 if signed_out else 0
            if query[-2:] == ("--label", "Spring"):
                return 0  # posters are labelled "Spring, 2019"
            if query[-2:] == ("--label", "Resume"):
                return 0
            return 1
        session = self._session(directory)
        with mock.patch.object(screenshots, "_mac_app_pid", return_value=42), \
                mock.patch.object(screenshots, "_mac_driver", side_effect=driver), \
                mock.patch.object(screenshots, "_mac_count", side_effect=count), \
                mock.patch.object(screenshots, "_mac_size_window",
                                  side_effect=lambda pid, specs: events.append(("size",))), \
                mock.patch.object(screenshots, "live_shot",
                                  side_effect=lambda session, scene: events.append(("shot", scene))), \
                mock.patch.object(screenshots, "load_live_config", return_value=self.CONFIG), \
                mock.patch.object(screenshots.time, "sleep"):
            scenes = screenshots.live_drive_macos(session)
        return scenes, events, environments

    def test_drive_signs_in_by_environment_and_shoots_each_scene_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scenes, events, environments = self._drive(directory, signed_out=True)
        self.assertEqual(scenes, ["home", "library", "detail", "playback"])
        fills = [event for event in events if event[0] == "set-value"]
        self.assertEqual([fill[-1] for fill in fills], list(screenshots.LIVE_SECRET_KEYS))
        # Values reach the driver only through its environment, one variable per field.
        self.assertEqual([env for env in environments if env],
                         [{key: self.CONFIG[key]} for key in screenshots.LIVE_SECRET_KEYS])
        for value in self.CONFIG.values():
            self.assertFalse(any(value in argument for event in events for argument in event))
        self.assertIn(("press", "--identifier", "performance.library-visibility.done"), events)
        # The window is sized before the first scene, and each sidebar scene focuses the sidebar.
        order = [event for event in events if event[0] in {"size", "shot", "focus", "select-row"}]
        self.assertEqual(order[0], ("size",))
        self.assertEqual([event[0] for event in order[1:7]],
                         ["select-row", "focus", "shot", "select-row", "focus", "shot"])
        self.assertIn(("select-row", "--identifier", "performance.mac.sidebar.library", "--label", "Movies"),
                      events)
        self.assertIn(("press", "--role", "AXButton", "--label-prefix", "Spring, "), events)
        # Playback is paused and skipped past the opening before its shot.
        pause = events.index(("press", "--identifier", "playback.playPause", "--label", "Pause"))
        paused = events.index(("wait", "--identifier", "playback.playPause", "--label", "Play"))
        skips = [index for index, event in enumerate(events) if event[-1] == "playback.skip.30"]
        self.assertEqual(len(skips), screenshots.MAC_PLAYBACK_SKIPS)
        self.assertLess(pause, skips[0])
        self.assertLess(skips[-1], paused)
        self.assertLess(paused, events.index(("shot", "playback")))
        self.assertLess(events.index(("shot", "detail")), pause)

    def test_drive_skips_sign_in_when_already_signed_in(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            scenes, events, environments = self._drive(directory, signed_out=False)
        self.assertEqual(scenes, ["home", "library", "detail", "playback"])
        self.assertFalse([event for event in events if event[0] == "set-value"])
        self.assertFalse([env for env in environments if env])

    def test_drive_rejects_a_relaunched_process_before_touching_the_app(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = self._session(directory)
            with mock.patch.object(screenshots, "_mac_app_pid", return_value=None), \
                    mock.patch.object(screenshots, "load_live_config", return_value=self.CONFIG), \
                    mock.patch.object(screenshots, "_mac_driver") as driver:
                with self.assertRaisesRegex(screenshots.ScreenshotError, "start a new session"):
                    screenshots.live_drive_macos(session)
                driver.assert_not_called()

    def test_finish_quits_only_the_process_the_session_launched(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = self._session(directory)
            (session / "frames").mkdir()
            with mock.patch.object(screenshots, "_mac_quit") as quit_app:
                with mock.patch.object(screenshots, "_mac_app_pid", return_value=42):
                    self.assertEqual(screenshots.live_finish(session), session / "export")
                quit_app.assert_called_once_with(42)
                with mock.patch.object(screenshots, "_mac_app_pid", return_value=99):
                    screenshots.live_finish(session)
                quit_app.assert_called_once()
            self.assertFalse((session / "frames").exists())
        # Without Accessibility the driver cannot ask the app to quit; it is still not left behind.
        with mock.patch.object(screenshots, "_mac_driver",
                               side_effect=screenshots.ScreenshotError("blocked")), \
                mock.patch.object(screenshots.subprocess, "run") as run:
            screenshots._mac_quit(42)
        self.assertEqual(run.call_args.args[0], ["/bin/kill", "42"])

    def test_command_line_routes_macos_sessions_to_the_accessibility_drive(self) -> None:
        arguments = screenshots.parser().parse_args(["live", "start", "--target", "macos"])
        self.assertEqual((arguments.target, arguments.allow_simulator), ("macos", False))
        with tempfile.TemporaryDirectory() as directory:
            session = self._session(directory)
            with mock.patch.object(screenshots, "live_drive_macos", return_value=["home"]) as drive, \
                    mock.patch.object(screenshots, "live_drive") as simulator_drive:
                self.assertEqual(screenshots.main(["live", "drive", str(session)]), 0)
                self.assertEqual(drive.call_args.args[0], session.resolve())
                self.assertEqual(screenshots.main(
                    ["live", "drive", str(session), "--xctestrun", "x.xctestrun"]), 2)
                self.assertEqual(screenshots.main(["live", "drive", str(session), "--landscape"]), 2)
                drive.assert_called_once()
                # Simulator sessions still need their .xctestrun.
                (session / "live-session.json").write_text(json.dumps({"target": "ipad", "pid": 1}))
                self.assertEqual(screenshots.main(["live", "drive", str(session)]), 2)
                simulator_drive.assert_not_called()

    def test_driver_live_mode_is_semantic_and_window_scoped(self) -> None:
        source = (ROOT / "scripts" / "agent-macos-ax-driver.swift").read_text()
        # No synthetic mouse or keyboard events and no pointer moves: the lane must not act on
        # the person's desktop outside the app's own Accessibility tree.
        for forbidden in ("CGEvent", "CGWarpMouseCursorPosition", "CGDisplayCreateImage"):
            self.assertNotIn(forbidden, source)
        for required in ("CGPreflightScreenCaptureAccess", "screen_recording_not_permitted",
                         "window_size_mismatch", '"-x", "-o", "-l\\(windowID)"', "kAXWindowsAttribute"):
            self.assertIn(required, source)


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
        self.assertEqual(manifest["catalogRelease"], "open-films-v6")
        self.assertRegex(manifest["sourceManifestSha256"], r"^[0-9a-f]{64}$")
        self.assertIn("not a fresh live-server", manifest["scope"])
        self.assertIn("not yet produced", manifest["storefrontGate"])
        self.assertEqual(
            [film["title"] for film in manifest["openFilms"]],
            ["Spring", "Wing It!", "Big Buck Bunny", "Sintel", "Tears of Steel", "Coffee Run"])
        paths = set()
        for film in manifest["openFilms"]:
            self.assertIn(film["license"]["spdx"], {"CC-BY-3.0", "CC-BY-4.0"})
            self.assertTrue(film["license"]["commercialReuseExplicitlyPermitted"])
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
        self.assertEqual(len(paths), 18)

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
