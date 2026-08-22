import contextlib
import importlib.util
import io
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-macos-emby-browse.py"
spec = importlib.util.spec_from_file_location("perf_macos_emby_browse", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
COMPARE = SCRIPT.parent / "perf-compare.py"
compare_spec = importlib.util.spec_from_file_location("perf_compare_for_browse_runner", COMPARE)
compare = importlib.util.module_from_spec(compare_spec)
sys.modules[compare_spec.name] = compare
compare_spec.loader.exec_module(compare)


class FakeExecutor:
    def __init__(self, statuses=None):
        self.statuses = list(statuses or [])
        self.actions = []

    def run_status(self, argv):
        self.actions.append(argv)
        return self.statuses.pop(0) if self.statuses else 44


class Process:
    def __init__(self, pid, executable=None):
        self.pid = pid
        self.executable = executable
        self.returncode = None


class CaptureExecutor(FakeExecutor):
    def __init__(self):
        super().__init__()
        self.next_pid = 100
        self.processes = {}
        self.clock = datetime(2026, 7, 22, tzinfo=timezone.utc)
        self.last_scenario = "home"

    def span_line(self):
        span = {
            "home": ("home.load", "view_count=2 rail_count=3 item_count=4 degraded=0"),
            "catalog": ("library_grid.complete",
                        "item_count=26 total_count=26 page_count=1 collapse_mode=sparse"),
            "search": ("search.load", "group_count=1 item_count=1"),
            "artwork": (
                "artwork.load",
                "attempts=1 bytes=100 status=200 width=100 height=150 "
                "pixel_width=200 pixel_height=300 delivery=network_decode "
                "scoped=1 milestone=library_first_poster",
            ),
        }[self.last_scenario]
        return (f'{{"eventMessage":"perf.span phase={span[0]} backend=Emby '
                f'result=success duration_ms=10 {span[1]}"}}\n')

    def run(self, argv, *, stdout=-1):
        self.actions.append(("run", argv))
        if argv[:3] == ["/usr/bin/open", "-n", "-a"]:
            app = pathlib.Path(argv[3])
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
            self.next_pid += 1
            self.processes[self.next_pid] = Process(self.next_pid, executable)
        elif argv[:3] == ["/usr/bin/xcrun", "swiftc", str(runner.DRIVER)]:
            output = pathlib.Path(argv[argv.index("-o") + 1])
            output.write_bytes(b"compiled-driver")
        elif argv and pathlib.Path(argv[0]).name == ".perf-macos-ax-driver":
            pid = int(argv[argv.index("--pid") + 1])
            spec_path = pathlib.Path(argv[argv.index("--workload-spec") + 1])
            document = json.loads(spec_path.read_text())
            self.last_scenario = document["scenario"]
            output = pathlib.Path(argv[argv.index("--output") + 1])
            output.write_text(json.dumps({
                "schema_version": 1,
                "tool": {"name": "labstream-macos-ax-driver", "version": 1},
                "pid": pid, "scenario": document["scenario"], "status": "success",
                "completed_stage": {
                    "home": "home_loaded", "catalog": "catalog_loaded",
                    "search": "search_loaded", "artwork": "artwork_loaded",
                }[document["scenario"]], "action_count": 6,
                "elapsed_milliseconds": 50, "error_code": None,
            }))
            output.chmod(0o600)
        elif str(runner.SUMMARY) in argv or (str(runner.CONTRACT) in argv and "manifest" in argv):
            subprocess.run(argv, check=True, stdout=stdout, stderr=subprocess.STDOUT)
        elif argv[:4] == ["/usr/bin/log", "show", "--info", "--style"]:
            stdout.write(self.span_line().encode())

    def output(self, argv):
        self.actions.append(("output", argv))
        if argv == ["/bin/ps", "-axo", "comm="]:
            return "".join(
                f"{process.executable}\n" for process in self.processes.values()
                if process.executable is not None and process.returncode is None
            )
        if argv == ["/bin/ps", "-axo", "pid=,comm="]:
            return "".join(
                f"{process.pid:6d} {process.executable}\n" for process in self.processes.values()
                if process.executable is not None and process.returncode is None
            )
        if len(argv) == 5 and argv[:2] == ["/bin/ps", "-p"] and argv[3:] == ["-o", "lstart="]:
            return "Wed Jul 22 12:00:00 2026\n"
        if argv[:4] == ["/usr/bin/log", "show", "--info", "--style"]:
            return self.span_line()
        if argv[:2] == ["/usr/bin/sw_vers", "-buildVersion"]:
            return "25A123\n"
        if argv[:2] == ["/usr/bin/xcodebuild", "-version"]:
            return "Xcode 27.0\nBuild version 17A456\n"
        if argv[:3] == ["/usr/bin/pmset", "-g", "batt"]:
            return "Now drawing from 'AC Power'\n100%; charged\n"
        if argv[:3] == ["/usr/bin/pmset", "-g", "therm"]:
            return ("No thermal warning level has been recorded\n"
                    "No performance warning level has been recorded\n")
        return ""

    def spawn(self, argv, *, stdout=-3):
        self.next_pid += 1
        process = Process(self.next_pid)
        self.processes[process.pid] = process
        self.actions.append(("spawn", argv, process.pid))
        if str(runner.FIXTURE) in argv:
            ready = pathlib.Path(argv[argv.index("--ready-file") + 1])
            ready.write_text(json.dumps({
                "schema_version": 1, "base_url": "http://127.0.0.1:54321",
                "fixture_id": "fixture-123456789abc", "fixture_sha256": "a" * 64,
                "user_id": "fixture-user",
            }))
        return process

    def sleep(self, seconds):
        self.actions.append(("sleep", seconds))

    def process_start_identity(self, _pid):
        return "1721649600:123456"

    def poll(self, process):
        return self.processes.get(process.pid, process).returncode

    def terminate(self, pid):
        self.actions.append(("terminate", pid))
        self.processes[pid].returncode = -15

    def kill(self, pid):
        self.actions.append(("kill", pid))
        self.processes[pid].returncode = -9

    def wait(self, process, timeout):
        return self.processes.get(process.pid, process).returncode

    def now(self):
        value = self.clock.isoformat(timespec="milliseconds")
        self.clock += timedelta(seconds=1)
        return value

    def disk_free(self, path):
        return 10_000_000_000


class BrowseRunnerTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.home_path = pathlib.Path(self.home.name).resolve()
        (self.home_path / "Library/Containers").mkdir(parents=True)
        self.home_patch = mock.patch.object(pathlib.Path, "home", return_value=self.home_path)
        self.home_patch.start()

    def tearDown(self):
        self.home_patch.stop()
        self.home.cleanup()

    def make_app(self, root, name, bundle="org.labstream.Labstream.perf.browse", service=None):
        app = pathlib.Path(root) / name
        binary = app / "Contents/MacOS/Labstream"
        binary.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle,
            "CFBundleExecutable": "Labstream",
            "LabstreamKeychainService": bundle if service is None else service,
        }))
        binary.write_bytes(b"binary")
        binary.chmod(0o755)
        return app

    def integrated_fixture(self, root, *, cooldown=0, scenario="home"):
        root = pathlib.Path(root)
        apps, service = runner.validate_inputs(
            self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
        paired = runner.plan_for(
            apps, service, scenario, 0, 1, 3, root / "paired.json",
            "a" * 40, "b" * 40, "local-device-01", "2099-01-01T00:00:00Z",
            cooldown)
        calibration = runner.calibration_plan_for(paired, root / "calibration.json")
        container = root / "Containers" / service
        (container / "Data").mkdir(parents=True)
        (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
        paired["container"] = calibration["container"] = str(container)
        ready = {"fixture_id": "fixture-123456789abc", "fixture_sha256": "a" * 64}
        routes = {
            "home": ("authenticate", "views", "resume", "next_up", "latest"),
            "artwork": ("authenticate", "views", "items", "image"),
        }[scenario]
        ledger = {
            "schema_version": 1, **ready, "total": 6,
            "by_route": {route: 1 for route in routes},
            "by_status": {"200": 6}, "delayed": 0, "faulted": 0, "in_flight": 0,
            "max_in_flight": 2, "declared_response_bytes": {},
            "committed_response_bytes": {}, "write_failures": 0,
            "client_disconnects": 0,
        }

        def fixture_request(_url, _path, *, method="GET"):
            return {"reset": True} if method == "POST" else ledger

        return apps, paired, calibration, fixture_request

    def resumable_fixture(self, root, *, cooldown=0, measured=1, scenario="home"):
        apps, paired, calibration, fixture_request = self.integrated_fixture(
            root, cooldown=cooldown, scenario=scenario)
        if measured != 1:
            commands = paired["samples"][0]["commands"]
            paired["measured"] = measured
            paired["samples"] = runner.base.schedule(scenario, 0, measured, paired["seed"])
            for sample in paired["samples"]:
                sample["commands"] = commands
        calibration["samples"] = calibration["samples"][:2]
        calibration["warmups"] = 0
        calibration["measured"] = 2
        return apps, paired, calibration, fixture_request

    @staticmethod
    def fake_freeze(_plan, _records, destination):
        destination.write_bytes(b'{"test":"frozen"}\n')
        return runner.hashlib.sha256(destination.read_bytes()).hexdigest()

    def test_resumable_crash_retries_whole_pair_without_recompile_or_half_pair(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.resumable_fixture(root)
            first = CaptureExecutor()
            real_launch = runner.launch_app

            def crash_candidate(app, executor, bound_callback=None):
                if app.role == "candidate":
                    raise KeyboardInterrupt("simulated process loss")
                return real_launch(app, executor, bound_callback)

            patches = (mock.patch.object(runner, "request_fixture", side_effect=fixture_request),
                       mock.patch.object(runner, "freeze_calibration", side_effect=self.fake_freeze))
            with patches[0], patches[1], mock.patch.object(
                    runner, "launch_app", side_effect=crash_candidate):
                with self.assertRaises(KeyboardInterrupt):
                    runner.capture(
                        paired, apps, first, calibration_plan=calibration,
                        calibration_output=root / "calibration.json",
                        frozen_mde_output=root / "frozen.json", fixture_port=54321)
            paired_raw = root / "paired-raw"
            self.assertEqual(list(paired_raw.glob("pair-*")), [])
            self.assertTrue(list(paired_raw.glob(".pending-pair-*")))

            second = CaptureExecutor()
            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}), \
                    mock.patch.object(runner, "frozen_artifact_for",
                                      return_value={"test": "frozen"}):
                result = runner.capture(
                    paired, apps, second, calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen.json", resume=True, fixture_port=54321)
            self.assertEqual(result["capture_status"], "success")
            self.assertEqual(len(list(paired_raw.glob("pair-*"))), 1)
            self.assertEqual(list(paired_raw.glob(".pending-pair-*")), [])
            self.assertFalse(any(action[0] == "run" and action[1][:2] ==
                                 ["/usr/bin/xcrun", "swiftc"] for action in second.actions))
            run_ids = [json.loads(pathlib.Path(record["manifest"]).read_text())["run"]["id"]
                       for record in result["records"]]
            self.assertEqual(len(run_ids), len(set(run_ids)))

    def test_artwork_calibration_freeze_and_resume_preserve_scoped_workload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.resumable_fixture(
                root, scenario="artwork")
            first = CaptureExecutor()
            real_launch = runner.launch_app

            def crash_candidate(app, executor, bound_callback=None):
                if app.role == "candidate":
                    raise KeyboardInterrupt("simulated artwork process loss")
                return real_launch(app, executor, bound_callback)

            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner, "freeze_calibration", side_effect=self.fake_freeze), \
                    mock.patch.object(runner, "launch_app", side_effect=crash_candidate):
                with self.assertRaises(KeyboardInterrupt):
                    runner.capture(
                        paired, apps, first, calibration_plan=calibration,
                        calibration_output=root / "calibration.json",
                        frozen_mde_output=root / "frozen.json", fixture_port=54321)

            second = CaptureExecutor()
            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}), \
                    mock.patch.object(runner, "frozen_artifact_for",
                                      return_value={"test": "frozen"}):
                result = runner.capture(
                    paired, apps, second, calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen.json", resume=True, fixture_port=54321)

            self.assertEqual(result["capture_status"], "success")
            self.assertEqual(result["scenario"], "artwork")
            record = result["records"][0]
            sample = compare.load_sample(pathlib.Path(record["manifest"]), record["role"])
            self.assertEqual(sample.workload["fields"], {
                "milestone": "library_first_poster", "scoped": "1",
            })
            self.assertEqual(list((root / "paired-raw").glob(".pending-pair-*")), [])

    def test_resume_fails_closed_on_retained_driver_and_plan_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.resumable_fixture(root)
            fake = CaptureExecutor()
            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner, "freeze_calibration", side_effect=self.fake_freeze), \
                    mock.patch.object(runner, "launch_app", side_effect=KeyboardInterrupt()):
                with self.assertRaises(KeyboardInterrupt):
                    runner.capture(
                        paired, apps, fake, calibration_plan=calibration,
                        calibration_output=root / "calibration.json",
                        frozen_mde_output=root / "frozen.json", fixture_port=54321)
            driver = root / "paired-raw/.perf-macos-ax-driver"
            driver.write_bytes(b"tampered")
            driver.chmod(0o700)
            with self.assertRaisesRegex(runner.RunnerError, "driver checksum drift"):
                runner.capture(
                    paired, apps, CaptureExecutor(), calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen.json", resume=True, fixture_port=54321)

            # Restore the pinned binary, then prove an invocation-setting change is also rejected.
            driver.write_bytes(b"compiled-driver")
            driver.chmod(0o700)
            paired["cooldown_seconds"] = 9
            calibration["cooldown_seconds"] = 9
            with self.assertRaisesRegex(runner.RunnerError, "plan identity drift"):
                runner.capture(
                    paired, apps, CaptureExecutor(), calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen.json", resume=True, fixture_port=54321)

    def test_resume_safely_cleans_checkpointed_exact_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, _paired, _calibration, _fixture_request = self.resumable_fixture(root)
            fake = CaptureExecutor()
            app = apps[0]
            fake.next_pid += 1
            pid = fake.next_pid
            fake.processes[pid] = Process(pid, app.executable)
            checkpoint = root / "active.json"
            runner.write_private_json_atomic(checkpoint, {
                "schema_version": 1, "status": "active", "pid": pid,
                "role": app.role, "executable": str(app.executable),
                "bundle_id": app.bundle_id,
                "start_identity": "1721649600:123456",
            })
            runner.cleanup_checkpointed_active_app(checkpoint, apps, fake)
            self.assertEqual(runner.read_private_json(checkpoint), runner.cleared_active_app())
            self.assertEqual(fake.processes[pid].returncode, -15)

            fake.next_pid += 1
            launching_pid = fake.next_pid
            fake.processes[launching_pid] = Process(launching_pid, app.executable)
            runner.write_private_json_atomic(checkpoint, runner.launching_active_app(app))
            with self.assertRaisesRegex(runner.RunnerError, "operator cleanup"):
                runner.cleanup_checkpointed_active_app(checkpoint, apps, fake)
            self.assertEqual(runner.read_private_json(checkpoint), runner.launching_active_app(app))
            self.assertIsNone(fake.processes[launching_pid].returncode)

    def test_launching_reconciliation_detects_final_boundary_arrival_without_signaling(self):
        class LateArrival(CaptureExecutor):
            def __init__(self, executable):
                super().__init__()
                self.executable = executable
                self.discovery_sleeps = 0

            def sleep(self, seconds):
                super().sleep(seconds)
                if seconds == 0.05:
                    self.discovery_sleeps += 1
                if self.discovery_sleeps == 120:
                    self.next_pid += 1
                    self.processes[self.next_pid] = Process(self.next_pid, self.executable)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, _paired, _calibration, _fixture_request = self.resumable_fixture(root)
            app = apps[0]
            fake = LateArrival(app.executable)
            checkpoint = root / "active.json"
            runner.write_private_json_atomic(checkpoint, runner.launching_active_app(app))
            with self.assertRaisesRegex(runner.RunnerError, "operator cleanup"):
                runner.cleanup_checkpointed_active_app(checkpoint, apps, fake)
            self.assertEqual(fake.discovery_sleeps, 120)
            self.assertTrue(fake.processes)
            self.assertTrue(all(process.returncode is None for process in fake.processes.values()))

    def test_resumable_cooldown_is_only_between_samples_and_whole_pairs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.resumable_fixture(
                root, cooldown=3.0, measured=2)
            fake = CaptureExecutor()
            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner, "freeze_calibration", side_effect=self.fake_freeze):
                result = runner.capture(
                    paired, apps, fake, calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen.json", fixture_port=54321)
            self.assertEqual(result["capture_status"], "success")
            self.assertEqual(sum(action == ("sleep", 3.0) for action in fake.actions), 3)
            meaningful = [action for action in fake.actions if action == ("sleep", 3.0)
                          or (action[0] == "run" and action[1][:3] ==
                              ["/usr/bin/open", "-n", "-a"])]
            # The final four launches are two pairs. There is one cooldown between launch 2/3,
            # and never between launch 1/2 or 3/4.
            tail = meaningful[-5:]
            self.assertEqual(tail[2], ("sleep", 3.0))
            output = root / "paired.json"
            runner.write_durable_json_exclusive(output, result)
            validation_patches = (
                mock.patch.object(runner, "frozen_artifact_for",
                                  return_value={"test": "frozen"}),
                mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}),
                mock.patch.object(runner.compare, "_validate_frozen", return_value=5.0),
            )
            with validation_patches[0], validation_patches[1], validation_patches[2]:
                runner.validate_published_resume_output(
                    output, paired, calibration, apps, root / "calibration.json",
                    root / "frozen.json", 54321)
            manifest = pathlib.Path(result["records"][0]["manifest"])
            manifest.write_text(manifest.read_text() + "\n")
            with validation_patches[0], validation_patches[1], validation_patches[2], \
                    self.assertRaisesRegex(runner.RunnerError, "checksum drift"):
                runner.validate_published_resume_output(
                    output, paired, calibration, apps, root / "calibration.json",
                    root / "frozen.json", 54321)

    def test_integrated_calibration_freezes_durably_before_candidate_and_reuses_processes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.integrated_fixture(
                root, cooldown=2.5)
            fake = CaptureExecutor()
            validated_at = []
            real_load_frozen = runner.compare.load_frozen

            def observe_validation(path, digest):
                self.assertTrue(path.is_file())
                candidate = str(apps[1].path)
                self.assertFalse(any(
                    action[0] == "run" and action[1][:3] == ["/usr/bin/open", "-n", "-a"]
                    and action[1][3] == candidate
                    for action in fake.actions if isinstance(action, tuple)))
                validated_at.append(len(fake.actions))
                return real_load_frozen(path, digest)

            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner.compare, "load_frozen",
                                      side_effect=observe_validation):
                result = runner.capture(
                    paired, apps, fake, calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen-mde.json")

            self.assertEqual(result["capture_status"], "success")
            self.assertEqual(len(validated_at), 1)
            frozen = real_load_frozen(
                root / "frozen-mde.json", result["calibration"]["frozen_mde_sha256"])
            self.assertEqual(len(frozen["control"]["evidence_manifests"]), 23)
            self.assertNotEqual(frozen["control"]["comparison_id"],
                                paired["identities"]["comparison_id"])
            self.assertEqual(frozen["control"]["order_seed"],
                             paired["identities"]["order_seed"])
            self.assertEqual(frozen["workload"]["id"], paired["identities"]["workload_id"])
            compile_runs = [action for action in fake.actions if action[0] == "run"
                            and action[1][:2] == ["/usr/bin/xcrun", "swiftc"]]
            fixture_spawns = [action for action in fake.actions if action[0] == "spawn"
                              and str(runner.FIXTURE) in action[1]]
            self.assertEqual((len(compile_runs), len(fixture_spawns)), (1, 1))
            # Cooling occurs only between calibration samples and between complete pairs;
            # neither the calibration/pair boundary nor the two arms of one pair are cooled.
            self.assertEqual(sum(action == ("sleep", 2.5) for action in fake.actions), 23)
            calibration_manifests = [
                compare.load_sample(pathlib.Path(record["manifest"]), "control")
                for record in json.loads((root / "calibration.json").read_text())["records"]]
            paired_sample = compare.load_sample(
                pathlib.Path(result["records"][0]["manifest"]), result["records"][0]["role"])
            hashes = {json.dumps(sample.manifest["automation"], sort_keys=True)
                      for sample in [*calibration_manifests, paired_sample]}
            self.assertEqual(len(hashes), 1)
            paired_control = [compare.load_sample(pathlib.Path(record["manifest"]), "control")
                              for record in result["records"] if record["role"] == "control"]
            self.assertGreater(compare._validate_frozen(
                frozen, paired_control, paired_control[0].workload, "short"), 0)

    def test_freeze_failure_blocks_every_candidate_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.integrated_fixture(root)
            fake = CaptureExecutor()
            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner.compare, "freeze_control",
                                      side_effect=runner.compare.CompareError("freeze rejected")):
                with self.assertRaisesRegex(runner.RunnerError, "freeze rejected"):
                    runner.capture(
                        paired, apps, fake, calibration_plan=calibration,
                        calibration_output=root / "calibration.json",
                        frozen_mde_output=root / "frozen-mde.json")
            candidate = str(apps[1].path)
            self.assertFalse(any(
                action[0] == "run" and action[1][:3] == ["/usr/bin/open", "-n", "-a"]
                and action[1][3] == candidate
                for action in fake.actions if isinstance(action, tuple)))
            self.assertTrue((root / "calibration.json").is_file())
            self.assertFalse((root / "frozen-mde.json").exists())

    def test_post_publication_freeze_validation_failure_leaves_fail_closed_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.integrated_fixture(root)
            fake = CaptureExecutor()
            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner.compare, "load_frozen",
                                      side_effect=runner.compare.CompareError("reload rejected")):
                with self.assertRaisesRegex(runner.RunnerError, "reload rejected"):
                    runner.capture(
                        paired, apps, fake, calibration_plan=calibration,
                        calibration_output=root / "calibration.json",
                        frozen_mde_output=root / "frozen-mde.json")
            # Once atomically published, evidence is never pathname-unlinked on an error: doing so
            # could delete a racing replacement. The failed run reports no checksum and requires
            # explicit operator cleanup before a retry.
            self.assertTrue((root / "frozen-mde.json").is_file())
            self.assertEqual(list(root.glob(".frozen-mde.json.*.tmp")), [])

    def test_exclusive_publication_never_deletes_a_racing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = pathlib.Path(temporary) / "frozen.json"
            real_link = runner.os.link

            def collide(source, target, *, follow_symlinks=False):
                pathlib.Path(target).write_text("sentinel")
                return real_link(source, target, follow_symlinks=follow_symlinks)

            with mock.patch.object(runner.os, "link", side_effect=collide):
                with self.assertRaises(FileExistsError):
                    runner.write_durable_json_exclusive(destination, {"not": "published"})
            self.assertEqual(destination.read_text(), "sentinel")

    def test_calibration_covariates_require_stable_supported_environment(self):
        device = {
            "power_source": "external", "battery_state": "charged",
            "thermal_state": "nominal", "free_storage_bytes": 10_000,
        }
        samples = [mock.Mock(manifest={"device": {**device, "free_storage_bytes": value}})
                   for value in (10_000, 9_900)]
        runner.validate_calibration_covariates(samples, 100)
        samples[1].manifest["device"]["thermal_state"] = "serious"
        with self.assertRaisesRegex(runner.RunnerError, "thermal"):
            runner.validate_calibration_covariates(samples, 100)
        samples[1].manifest["device"]["thermal_state"] = "nominal"
        with self.assertRaisesRegex(runner.RunnerError, "storage"):
            runner.validate_calibration_covariates(samples, 99)

    def test_paired_failure_preserves_valid_frozen_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, paired, calibration, fixture_request = self.integrated_fixture(root)
            fake = CaptureExecutor()
            real_launch = runner.launch_app

            def fail_after_freeze(app, executor, bound_callback=None):
                if (root / "frozen-mde.json").exists():
                    raise runner.RunnerError("paired launch rejected")
                return real_launch(app, executor, bound_callback)

            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request), \
                    mock.patch.object(runner, "launch_app", side_effect=fail_after_freeze):
                result = runner.capture(
                    paired, apps, fake, calibration_plan=calibration,
                    calibration_output=root / "calibration.json",
                    frozen_mde_output=root / "frozen-mde.json")
            self.assertEqual(result["capture_status"], "failure")
            self.assertIn("paired launch rejected", result["records"][0]["error"])
            digest = result["calibration"]["frozen_mde_sha256"]
            self.assertEqual(runner.compare.load_frozen(root / "frozen-mde.json", digest)
                             ["control"]["commit"], "a" * 40)

    def test_integrated_outputs_reject_existing_aliases_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            existing = root / "existing.json"
            existing.write_text("do not replace")
            with self.assertRaisesRegex(runner.RunnerError, "already exists"):
                runner.validate_integrated_outputs([
                    existing, root / "calibration.json", root / "frozen.json"])
            alias = root / "alias.json"
            alias.symlink_to(existing)
            with self.assertRaisesRegex(runner.RunnerError, "distinct|already exists"):
                runner.validate_integrated_outputs([
                    root / "paired.json", alias, root / "frozen.json"])
            with self.assertRaisesRegex(runner.RunnerError, "outside raw evidence"):
                runner.validate_integrated_outputs([
                    root / "paired.json", root / "calibration.json",
                    root / "paired-raw/frozen.json"])

    def test_plan_is_side_effect_free_adjacent_and_contains_no_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = self.make_app(temporary, "Control.app")
            candidate = self.make_app(temporary, "Candidate.app")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                status = runner.main([
                    "--control-app", str(control), "--candidate-app", str(candidate),
                    "--control-commit", "a" * 40, "--candidate-commit", "b" * 40,
                    "--scenario", "catalog", "--warmups", "1", "--measured", "2",
                    "--output", str(pathlib.Path(temporary) / "result.json"), "--plan",
                ])
            document = json.loads(stdout.getvalue())
            self.assertEqual(status, 0)
            self.assertEqual(document["mode"], "plan")
            self.assertEqual(document["artifact_status"], "planned_admissible_per_run_manifests")
            self.assertNotIn(runner.FIXTURE_USERNAME, stdout.getvalue())
            self.assertNotIn(runner.FIXTURE_PASSWORD, stdout.getvalue())
            self.assertEqual(len(document["samples"]), 6)
            for offset in range(0, 6, 2):
                pair = document["samples"][offset:offset + 2]
                self.assertEqual({row["role"] for row in pair}, {"control", "candidate"})
                self.assertEqual([row["pair_order"] for row in pair], [1, 2])
                self.assertEqual(pair[0]["sample_index"], pair[1]["sample_index"])
            for sample in document["samples"]:
                self.assertEqual(sample["commands"]["launch"][:3],
                                 ["/usr/bin/open", "-n", "-a"])
                self.assertEqual(sample["commands"]["app_arguments"], [])
                self.assertEqual(sample["commands"]["app_environment"], {})
                self.assertEqual(sample["commands"]["driver"][1:3],
                                 ["--pid", "{exact_pid}"])
            self.assertEqual(document["driver"]["preflight_compile"][:2],
                             ["/usr/bin/xcrun", "swiftc"])

    def test_validation_requires_dedicated_matching_keychain_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = self.make_app(temporary, "Control.app", service="org.labstream.Labstream")
            candidate = self.make_app(temporary, "Candidate.app", service="org.labstream.Labstream")
            with self.assertRaisesRegex(runner.RunnerError, "dedicated performance"):
                runner.validate_inputs(control, candidate)

    def test_launchservices_launch_binds_only_new_exact_executable_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = runner.base.validate_app("control", self.make_app(temporary, "Control.app"))
            fake = CaptureExecutor()
            process = runner.launch_app(app, fake)
            self.assertEqual(process.executable, app.executable)
            self.assertEqual(fake.processes[process.pid].executable, app.executable)
            opens = [action for action in fake.actions
                     if action[:1] == ("run",) and action[1][:3]
                     == ["/usr/bin/open", "-n", "-a"]]
            self.assertEqual(opens, [("run", ["/usr/bin/open", "-n", "-a", str(app.path)])])
            self.assertFalse(any(action[0] == "spawn" and action[1] == [str(app.executable)]
                                 for action in fake.actions if isinstance(action, tuple)))

    def test_launch_binding_checkpoint_failure_cleans_discovered_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = runner.base.validate_app("control", self.make_app(temporary, "Control.app"))
            fake = CaptureExecutor()
            with self.assertRaisesRegex(RuntimeError, "checkpoint failed"):
                runner.launch_app(
                    app, fake,
                    lambda _process: (_ for _ in ()).throw(RuntimeError("checkpoint failed")))
            self.assertTrue(fake.processes)
            self.assertTrue(all(process.returncode is not None
                                for process in fake.processes.values()))

    def test_launchservices_launch_rejects_and_cleans_ambiguous_exact_pids(self):
        class Ambiguous(CaptureExecutor):
            def run(self, argv, *, stdout=-1):
                super().run(argv, stdout=stdout)
                if argv[:3] == ["/usr/bin/open", "-n", "-a"]:
                    first = self.processes[self.next_pid]
                    self.next_pid += 1
                    self.processes[self.next_pid] = Process(self.next_pid, first.executable)

        with tempfile.TemporaryDirectory() as temporary:
            app = runner.base.validate_app("control", self.make_app(temporary, "Control.app"))
            fake = Ambiguous()
            with self.assertRaisesRegex(runner.RunnerError, "ambiguous exact app PIDs"):
                runner.launch_app(app, fake)
            self.assertTrue(all(process.returncode is not None
                                for process in fake.processes.values()))

    def test_launchservices_launch_fails_closed_on_discovery_timeout(self):
        class Missing(CaptureExecutor):
            def run(self, argv, *, stdout=-1):
                if argv[:3] == ["/usr/bin/open", "-n", "-a"]:
                    self.actions.append(("run", argv))
                    return
                super().run(argv, stdout=stdout)

        with tempfile.TemporaryDirectory() as temporary:
            app = runner.base.validate_app("control", self.make_app(temporary, "Control.app"))
            fake = Missing()
            with self.assertRaisesRegex(runner.RunnerError, "discovery deadline exceeded"):
                runner.launch_app(app, fake)
            self.assertEqual(sum(action == ("sleep", 0.05) for action in fake.actions), 120)

    def test_launchservices_timeout_cleans_late_exact_child(self):
        class Late(CaptureExecutor):
            def __init__(self):
                super().__init__()
                self.discovery_sleeps = 0
                self.app = None

            def run(self, argv, *, stdout=-1):
                if argv[:3] == ["/usr/bin/open", "-n", "-a"]:
                    self.actions.append(("run", argv))
                    self.app = pathlib.Path(argv[3])
                    return
                super().run(argv, stdout=stdout)

            def sleep(self, seconds):
                super().sleep(seconds)
                if seconds == 0.05:
                    self.discovery_sleeps += 1
                if self.discovery_sleeps == 120:
                    info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
                    executable = self.app / "Contents/MacOS" / info["CFBundleExecutable"]
                    self.next_pid += 1
                    self.processes[self.next_pid] = Process(self.next_pid, executable)

        with tempfile.TemporaryDirectory() as temporary:
            app = runner.base.validate_app("control", self.make_app(temporary, "Control.app"))
            fake = Late()
            with self.assertRaisesRegex(runner.RunnerError, "discovery deadline exceeded"):
                runner.launch_app(app, fake)
            self.assertTrue(fake.processes)
            self.assertTrue(all(process.returncode is not None
                                for process in fake.processes.values()))

    def test_launchservices_launch_rejects_preexisting_bundle_collision(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = runner.base.validate_app("control", self.make_app(temporary, "Control.app"))
            fake = CaptureExecutor()
            fake.next_pid += 1
            fake.processes[fake.next_pid] = Process(fake.next_pid, app.executable)
            with self.assertRaisesRegex(runner.RunnerError, "already running"):
                runner.launch_app(app, fake)
            self.assertFalse(any(action[:1] == ("run",) and action[1][:1] == ["/usr/bin/open"]
                                 for action in fake.actions if isinstance(action, tuple)))

    def test_detached_process_poll_and_wait_are_exact_and_bounded(self):
        class PollingExecutor(runner.Executor):
            def __init__(self, snapshots):
                self.snapshots = list(snapshots)
                self.sleeps = []

            def output(self, argv):
                self.assert_argv = argv
                return self.snapshots.pop(0)

            def sleep(self, seconds):
                self.sleeps.append(seconds)

        executable = pathlib.Path("/tmp/Exact.app/Contents/MacOS/Labstream")
        process = runner.DetachedAppProcess(321, executable)
        fake = PollingExecutor([
            f"   321 {executable}\n",
            "   321 /tmp/Other.app/Contents/MacOS/Labstream\n",
        ])
        self.assertEqual(fake.wait(process, 1), 0)
        self.assertEqual(fake.sleeps, [0.1])
        self.assertEqual(fake.assert_argv, ["/bin/ps", "-axo", "pid=,comm="])
        self.assertEqual(process.returncode, 0)

        live = runner.DetachedAppProcess(654, executable)
        timed_out = PollingExecutor([f"654 {executable}\n"] * 10)
        with self.assertRaises(subprocess.TimeoutExpired):
            timed_out.wait(live, 1)
        self.assertEqual(len(timed_out.sleeps), 10)

    def test_detached_cleanup_never_signals_a_reused_pid(self):
        class ReusedExecutor(runner.Executor):
            def __init__(self):
                self.snapshots = [
                    "321 /tmp/Exact.app/Contents/MacOS/Labstream\n",
                    "321 /tmp/Other.app/Contents/MacOS/Other\n",
                ]
                self.signals = []

            def output(self, argv):
                return self.snapshots.pop(0)

            def terminate(self, pid):
                self.signals.append(("term", pid))

            def kill(self, pid):
                self.signals.append(("kill", pid))

        executable = pathlib.Path("/tmp/Exact.app/Contents/MacOS/Labstream")
        process = runner.DetachedAppProcess(321, executable)
        fake = ReusedExecutor()
        self.assertIsNone(runner.stop_app_and_prove_gone(process, fake))
        self.assertEqual(fake.signals, [])
        self.assertEqual(process.returncode, 0)

    def test_keychain_reset_targets_only_closed_accounts_and_verifies_absence(self):
        fake = FakeExecutor([0, 44] * len(runner.AUTH_ACCOUNTS))
        service = "org.labstream.Labstream.perf.browse"
        runner.reset_performance_keychain(service, fake)
        self.assertEqual(len(fake.actions), 2 * len(runner.AUTH_ACCOUNTS))
        for account, delete, find in zip(runner.AUTH_ACCOUNTS,
                                         fake.actions[::2], fake.actions[1::2]):
            self.assertEqual(delete, ["/usr/bin/security", "delete-generic-password",
                                      "-s", service, "-a", account])
            self.assertEqual(find, ["/usr/bin/security", "find-generic-password",
                                    "-s", service, "-a", account])
        self.assertIn("clientIdentifier", " ".join(" ".join(row) for row in fake.actions))

    def test_keychain_reset_fails_closed_for_unproved_absence(self):
        with self.assertRaisesRegex(runner.RunnerError, "could not prove"):
            runner.reset_performance_keychain("org.labstream.Labstream.perf.browse",
                                              FakeExecutor([44, 0]))
        with self.assertRaisesRegex(runner.RunnerError, "non-performance"):
            runner.reset_performance_keychain("org.labstream.Labstream", FakeExecutor())

    def test_private_spec_is_exclusive_and_mode_0600(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "spec.json"
            runner.write_private_json(path, {"schema_version": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                runner.write_private_json(path, {"schema_version": 1})

    def test_browse_preference_seed_is_closed_private_and_fixture_scoped(self):
        with tempfile.TemporaryDirectory() as temporary:
            service = "org.labstream.Labstream.perf.browse"
            container = pathlib.Path(temporary) / service
            (container / "Data/Library").mkdir(parents=True)
            digest = runner.seed_browse_preferences(container, service)
            path = container / f"Data/Library/Preferences/{service}.plist"
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(plistlib.loads(path.read_bytes()), {
                runner.VISIBILITY_PROMPT_KEY: True,
            })
            self.assertEqual(len(digest), 64)
            with self.assertRaisesRegex(runner.RunnerError, "incomplete or unsafe"):
                runner.seed_browse_preferences(container, service)

    def test_driver_result_must_prove_exact_pid_scenario_and_success(self):
        valid = {
            "schema_version": 1,
            "tool": {"name": "labstream-macos-ax-driver", "version": 1},
            "pid": 123, "scenario": "search", "status": "success",
            "completed_stage": "search_loaded", "action_count": 7,
            "elapsed_milliseconds": 100, "error_code": None,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "driver.json"
            path.write_text(json.dumps(valid))
            path.chmod(0o600)
            self.assertEqual(runner.validate_driver_result(path, pid=123, scenario="search"), valid)
            valid["pid"] = 124
            path.write_text(json.dumps(valid))
            with self.assertRaisesRegex(runner.RunnerError, "exact-PID"):
                runner.validate_driver_result(path, pid=123, scenario="search")

    def test_success_selector_preserves_binding_and_excludes_cancelled_attempt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "full.log"
            selected = root / "selected.log"
            source.write_text(
                "perf.capture run_id=run-123456789abc workload_id=workload-123456789abc "
                "launch_nonce=nonce-1234567890abcdef\n"
                '{"eventMessage":"perf.span phase=home.load backend=Emby result=cancelled '
                'duration_ms=3"}\n'
                '{"eventMessage":"perf.span phase=home.load backend=Emby result=success '
                'duration_ms=10 view_count=2 rail_count=3 item_count=4 degraded=0"}\n'
            )
            runner.write_success_selector_artifact(source, selected, "home.load")
            payload = selected.read_text()
            self.assertIn("perf.capture", payload)
            self.assertIn("result=success", payload)
            self.assertNotIn("result=cancelled", payload)
            self.assertEqual(selected.stat().st_mode & 0o777, 0o600)

    def test_catalog_selector_excludes_superseded_attempt_but_rejects_other_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "full.log"
            selected = root / "selected.log"
            prefix = ("perf.capture run_id=run-123456789abc "
                      "workload_id=workload-123456789abc "
                      "launch_nonce=nonce-1234567890abcdef\n")
            success = ('{"eventMessage":"perf.span phase=library_grid.complete backend=Emby '
                       'result=success duration_ms=10 collapse_mode=collapsed item_count=26 '
                       'page_count=1 publication_count=2 total_count=26"}\n')
            source.write_text(
                prefix
                + '{"eventMessage":"perf.span phase=library_grid.complete backend=Emby '
                  'result=superseded duration_ms=3"}\n'
                + success
            )
            runner.write_success_selector_artifact(source, selected, "library_grid.complete")
            self.assertNotIn("result=superseded", selected.read_text())

            rejected = root / "rejected.log"
            source.write_text(
                prefix
                + '{"eventMessage":"perf.span phase=library_grid.complete backend=Emby '
                  'result=stale duration_ms=3"}\n'
                + success
            )
            with self.assertRaisesRegex(runner.RunnerError, "non-success target"):
                runner.write_success_selector_artifact(
                    source, rejected, "library_grid.complete")

    def test_artwork_selector_retains_only_one_scoped_milestone_and_rejects_target_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "full.log"
            selected = root / "selected.log"
            prefix = ("perf.capture run_id=run-123456789abc "
                      "workload_id=workload-123456789abc "
                      "launch_nonce=nonce-1234567890abcdef\n")
            fields = ("attempts=1 bytes=100 status=200 width=100 height=150 "
                      "pixel_width=200 pixel_height=300 delivery=network_decode ")
            unrelated = (
                '{"eventMessage":"perf.span phase=artwork.load backend=Emby result=success '
                f'duration_ms=8 {fields}scoped=0 milestone=library_first_poster"}}\n')
            target = (
                '{"eventMessage":"perf.span phase=artwork.load backend=Emby result=success '
                f'duration_ms=9 {fields}scoped=1 milestone=library_first_poster"}}\n')
            selector = {"scoped": "1", "milestone": "library_first_poster"}
            source.write_text(prefix + unrelated + target)
            runner.write_success_selector_artifact(
                source, selected, "artwork.load", selector)
            self.assertNotIn("scoped=0", selected.read_text())
            self.assertIn("scoped=1", selected.read_text())

            source.write_text(
                prefix
                + ('{"eventMessage":"perf.span phase=artwork.load backend=Emby result=failure '
                   f'duration_ms=3 {fields}scoped=1 milestone=library_first_poster"}}\n')
                + target
            )
            with self.assertRaisesRegex(runner.RunnerError, "non-success target"):
                runner.write_success_selector_artifact(
                    source, root / "failure.log", "artwork.load", selector)

            source.write_text(prefix + target + target)
            with self.assertRaisesRegex(runner.RunnerError, "one capture binding and one successful"):
                runner.write_success_selector_artifact(
                    source, root / "duplicate.log", "artwork.load", selector)

            source.write_text(prefix + target.replace(" scoped=1", " scoped=1 scoped=1"))
            with self.assertRaisesRegex(runner.RunnerError, "malformed performance span"):
                runner.write_success_selector_artifact(
                    source, root / "malformed.log", "artwork.load", selector)

    def test_artwork_scope_is_selector_only_not_a_global_correctness_requirement(self):
        ordinary = (
            "perf.span phase=artwork.load backend=Emby result=success duration_ms=8 "
            "attempts=1 bytes=100 status=200 width=100 height=150 "
            "pixel_width=200 pixel_height=300 delivery=network_decode"
        )
        span, reason = runner.evidence_schema.parse_span_line_diagnostic(ordinary)
        self.assertIsNone(reason)
        self.assertIsNotNone(span)
        self.assertEqual(
            runner.evidence_schema.REQUIRED_CORRECTNESS_FIELDS[("artwork.load", "Emby")],
            ("attempts", "bytes", "status", "width", "height",
             "pixel_width", "pixel_height", "delivery"),
        )

    def test_driver_result_rejects_nonterminal_stage_for_every_scenario(self):
        expected = {
            "home": "home_loaded", "catalog": "catalog_loaded",
            "search": "search_loaded", "artwork": "artwork_loaded",
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "driver.json"
            for scenario, completed in expected.items():
                with self.subTest(scenario=scenario):
                    value = {
                        "schema_version": 1,
                        "tool": {"name": "labstream-macos-ax-driver", "version": 1},
                        "pid": 123, "scenario": scenario, "status": "success",
                        "completed_stage": completed, "action_count": 7,
                        "elapsed_milliseconds": 100, "error_code": None,
                    }
                    path.write_text(json.dumps(value))
                    path.chmod(0o600)
                    runner.validate_driver_result(path, pid=123, scenario=scenario)
                    value["completed_stage"] = "authenticated"
                    path.write_text(json.dumps(value))
                    with self.assertRaisesRegex(runner.RunnerError, "exact-PID"):
                        runner.validate_driver_result(path, pid=123, scenario=scenario)
    def test_ledger_is_closed_idle_and_bound_to_ready_identity(self):
        ready = {"fixture_id": "fixture-123456789abc", "fixture_sha256": "a" * 64}
        ledger = {
            "schema_version": 1, **ready, "total": 3, "by_route": {"authenticate": 1},
            "by_status": {"200": 3}, "delayed": 0, "faulted": 0, "in_flight": 0,
            "max_in_flight": 2, "declared_response_bytes": {},
            "committed_response_bytes": {}, "write_failures": 0, "client_disconnects": 0,
        }
        runner.validate_ledger(ledger, ready)
        with self.assertRaisesRegex(runner.RunnerError, "missing required"):
            runner.validate_ledger(ledger, ready, "artwork")
        ledger["by_route"].update({"views": 1, "items": 1, "image": 0})
        with self.assertRaisesRegex(runner.RunnerError, "missing required.*image"):
            runner.validate_ledger(ledger, ready, "artwork")
        ledger["by_route"]["image"] = 1
        runner.validate_ledger(ledger, ready, "artwork")
        ledger["in_flight"] = 1
        with self.assertRaisesRegex(runner.RunnerError, "incomplete"):
            runner.validate_ledger(ledger, ready)
        ledger["in_flight"] = 0
        ledger["client_disconnects"] = 1
        with self.assertRaisesRegex(runner.RunnerError, "workload failure"):
            runner.validate_ledger(ledger, ready)

    def test_terminal_span_wait_polls_exact_pid_without_fixed_settle(self):
        class Delayed(CaptureExecutor):
            def __init__(self):
                super().__init__()
                self.poll_count = 0

            def output(self, argv):
                if argv[:4] == ["/usr/bin/log", "show", "--info", "--style"]:
                    self.actions.append(("output", argv))
                    self.poll_count += 1
                    return "" if self.poll_count < 3 else self.span_line()
                return super().output(argv)

        fake = Delayed()
        runner.wait_for_terminal_span(777, "2026-07-22T00:00:00.000Z", "home", fake)
        polls = [action for action in fake.actions if action[0] == "output"]
        self.assertEqual(len(polls), 3)
        self.assertTrue(all(action[1][-1] == "777" for action in polls))
        self.assertEqual([action for action in fake.actions if action[0] == "sleep"],
                         [("sleep", 0.1), ("sleep", 0.1)])

    def test_terminal_span_wait_rejects_multiple_terminals(self):
        class Duplicate(CaptureExecutor):
            def output(self, argv):
                if argv[:4] == ["/usr/bin/log", "show", "--info", "--style"]:
                    return self.span_line() * 2
                return super().output(argv)

        with self.assertRaisesRegex(runner.RunnerError, "multiple successful"):
            runner.wait_for_terminal_span(
                777, "2026-07-22T00:00:00.000Z", "home", Duplicate())

    def test_ledger_requires_an_unchanged_zero_window(self):
        ready = {"fixture_id": "fixture-123456789abc", "fixture_sha256": "a" * 64}
        base_ledger = {
            "schema_version": 1, **ready, "total": 6,
            "by_route": {route: 1 for route in
                         ("authenticate", "views", "resume", "next_up", "latest")},
            "by_status": {"200": 6}, "delayed": 0, "faulted": 0, "in_flight": 0,
            "max_in_flight": 2, "declared_response_bytes": {},
            "committed_response_bytes": {}, "write_failures": 0, "client_disconnects": 0,
        }
        changed = {**base_ledger, "total": 7, "by_status": {"200": 7}}
        fake = CaptureExecutor()
        with mock.patch.object(runner, "request_fixture",
                               side_effect=[base_ledger, changed, changed, changed]):
            result = runner.wait_for_stable_zero_ledger(
                "http://127.0.0.1:54321", ready, "home", fake)
        self.assertEqual(result, changed)
        self.assertEqual([action for action in fake.actions if action[0] == "sleep"],
                         [("sleep", 0.1), ("sleep", 0.1), ("sleep", 0.1)])

    def test_capture_compiles_driver_once_reuses_one_fixture_and_cleans_every_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, service = runner.validate_inputs(
                self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
            plan = runner.plan_for(apps, service, "home", 0, 1, 3, root / "result.json",
                                   "a" * 40, "b" * 40, "local-device-01",
                                   "2099-01-01T00:00:00Z")
            container = root / "Containers" / service
            (container / "Data").mkdir(parents=True)
            (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
            plan["container"] = str(container)
            fake = CaptureExecutor()
            ready = {"fixture_id": "fixture-123456789abc", "fixture_sha256": "a" * 64}
            ledger = {
                "schema_version": 1, **ready, "total": 6,
                "by_route": {route: 1 for route in
                             ("authenticate", "views", "resume", "next_up", "latest")},
                "by_status": {"200": 6}, "delayed": 0, "faulted": 0, "in_flight": 0,
                "max_in_flight": 2, "declared_response_bytes": {},
                "committed_response_bytes": {}, "write_failures": 0,
                "client_disconnects": 0,
            }

            def fixture_request(_url, path, *, method="GET"):
                fake.actions.append(("fixture", method, path))
                if method == "POST":
                    return {"reset": True}
                return ledger

            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request):
                result = runner.capture(plan, apps, fake)

            self.assertEqual(result["capture_status"], "success")
            compile_runs = [action for action in fake.actions
                            if action[0] == "run" and action[1][:2] == ["/usr/bin/xcrun", "swiftc"]]
            self.assertEqual(len(compile_runs), 1)
            fixture_spawns = [action for action in fake.actions
                              if action[0] == "spawn" and str(runner.FIXTURE) in action[1]]
            self.assertEqual(len(fixture_spawns), 1)
            driver_runs = [action for action in fake.actions
                           if action[0] == "run" and action[1]
                           and pathlib.Path(action[1][0]).name == ".perf-macos-ax-driver"]
            self.assertEqual(len(driver_runs), 2)
            self.assertFalse(any("swift" == pathlib.Path(action[1][1]).name
                                 for action in fake.actions if action[0] == "run"
                                 and len(action[1]) > 1 and action[1][0] == "/usr/bin/xcrun"))
            self.assertTrue(all(process.returncode is not None for process in fake.processes.values()))
            keychain_deletes = [action for action in fake.actions if isinstance(action, list)
                                and action[:2] == ["/usr/bin/security", "delete-generic-password"]]
            self.assertEqual(len(keychain_deletes), 4 * len(runner.AUTH_ACCOUNTS))
            self.assertIn("clientIdentifier", " ".join(" ".join(row) for row in keychain_deletes))
            for app_pid in sorted(pid for pid in fake.processes if pid != fixture_spawns[0][2]):
                stop_index = fake.actions.index(("terminate", app_pid))
                self.assertTrue(any(action[:2] == ("fixture", "GET")
                                    for action in fake.actions[stop_index + 1:]
                                    if isinstance(action, tuple)))
            self.assertFalse((root / "result-raw/.perf-macos-ax-driver").exists())
            loaded = {"control": [], "candidate": []}
            for record in result["records"]:
                run_dir = pathlib.Path(record["raw_directory"])
                self.assertFalse((run_dir / ".workload-spec.json").exists())
                manifest = json.loads((run_dir / "manifest.json").read_text())
                self.assertEqual(len(manifest["automation"]["fixture_implementation_sha256"]), 64)
                self.assertEqual(len(manifest["automation"]["workload_spec_sha256"]), 64)
                self.assertEqual(len(manifest["automation"]["client_state_seed_sha256"]), 64)
                self.assertEqual(manifest["scenario"]["backend_kind"], "emby")
                self.assertEqual(json.loads((run_dir / "summary/redacted.json").read_text())
                                 ["workload"]["phase"], "home.load")
                loaded[record["role"]].append(compare.load_sample(
                    pathlib.Path(record["manifest"]), record["role"]))
            covariates = compare._validate_pairing(loaded["control"], loaded["candidate"],
                                                   max_storage_drift=0,
                                                   max_pair_gap_seconds=120)
            self.assertEqual(covariates[("measured", 0)]["thermal_state"], "nominal")

    def test_late_request_after_stable_window_invalidates_sample(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, service = runner.validate_inputs(
                self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
            plan = runner.plan_for(apps, service, "home", 0, 1, 3, root / "result.json",
                                   "a" * 40, "b" * 40, "local-device-01",
                                   "2099-01-01T00:00:00Z")
            container = root / "Containers" / service
            (container / "Data").mkdir(parents=True)
            (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
            plan["container"] = str(container)
            fake = CaptureExecutor()
            ledger = {
                "schema_version": 1, "fixture_id": "fixture-123456789abc",
                "fixture_sha256": "a" * 64, "total": 6,
                "by_route": {route: 1 for route in
                             ("authenticate", "views", "resume", "next_up", "latest")},
                "by_status": {"200": 6}, "delayed": 0, "faulted": 0, "in_flight": 0,
                "max_in_flight": 2, "declared_response_bytes": {},
                "committed_response_bytes": {}, "write_failures": 0,
                "client_disconnects": 0,
            }
            get_count = 0

            def fixture_request(_url, _path, *, method="GET"):
                nonlocal get_count
                if method == "POST":
                    return {"reset": True}
                get_count += 1
                if get_count == 5:
                    return {**ledger, "total": 7, "by_status": {"200": 7}}
                return ledger

            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request):
                result = runner.capture(plan, apps, fake)
            self.assertEqual(result["capture_status"], "failure")
            self.assertIn("changed after", result["records"][0]["error"])
            self.assertFalse((root / "result-raw/sample-0001/manifest.json").exists())

    def test_failed_sample_still_stops_app_and_resets_keychain(self):
        class DriverFailure(CaptureExecutor):
            def run(self, argv, *, stdout=-1):
                if argv and pathlib.Path(argv[0]).name == ".perf-macos-ax-driver":
                    pid = int(argv[argv.index("--pid") + 1])
                    spec_path = pathlib.Path(argv[argv.index("--workload-spec") + 1])
                    output = pathlib.Path(argv[argv.index("--output") + 1])
                    output.write_text(json.dumps({
                        "schema_version": 1,
                        "tool": {"name": "labstream-macos-ax-driver", "version": 1},
                        "pid": pid, "scenario": json.loads(spec_path.read_text())["scenario"],
                        "status": "failure", "completed_stage": "authenticated",
                        "action_count": 5, "elapsed_milliseconds": 123,
                        "error_code": "element_not_found",
                    }))
                    output.chmod(0o600)
                    raise subprocess.CalledProcessError(1, argv)
                return super().run(argv, stdout=stdout)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, service = runner.validate_inputs(
                self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
            plan = runner.plan_for(apps, service, "home", 0, 1, 3, root / "result.json",
                                   "a" * 40, "b" * 40, "local-device-01",
                                   "2099-01-01T00:00:00Z")
            container = root / "Containers" / service
            (container / "Data").mkdir(parents=True)
            (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
            plan["container"] = str(container)
            fake = DriverFailure()
            with mock.patch.object(runner, "request_fixture",
                                   side_effect=lambda _u, _p, method="GET":
                                   {"reset": True} if method == "POST" else {}):
                result = runner.capture(plan, apps, fake)
            self.assertEqual(result["capture_status"], "failure")
            failure = result["records"][0]
            self.assertEqual(failure["driver_failure"], {
                "error_code": "element_not_found",
                "completed_stage": "authenticated",
                "elapsed_milliseconds": 123,
            })
            self.assertIn(
                "AX driver failed: error_code=element_not_found "
                "completed_stage=authenticated elapsed_milliseconds=123",
                failure["error"])
            self.assertNotIn("action_count", failure)
            self.assertEqual(list((root / "result-raw").glob(".pending-*")), [])
            fixture_pid = next(action[2] for action in fake.actions
                               if action[0] == "spawn" and str(runner.FIXTURE) in action[1])
            app_pids = [pid for pid in fake.processes if pid != fixture_pid]
            self.assertTrue(all(fake.processes[pid].returncode is not None for pid in app_pids))
            deletes = [action for action in fake.actions if isinstance(action, list)
                       and action[:2] == ["/usr/bin/security", "delete-generic-password"]]
            self.assertEqual(len(deletes), 2 * len(runner.AUTH_ACCOUNTS))

    def test_malformed_driver_failure_is_redacted_and_pending_evidence_is_removed(self):
        class MalformedDriverFailure(CaptureExecutor):
            def run(self, argv, *, stdout=-1):
                if argv and pathlib.Path(argv[0]).name == ".perf-macos-ax-driver":
                    output = pathlib.Path(argv[argv.index("--output") + 1])
                    output.write_text('{"error_code":"secret-token-value"}')
                    output.chmod(0o600)
                    raise subprocess.CalledProcessError(1, argv)
                return super().run(argv, stdout=stdout)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, service = runner.validate_inputs(
                self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
            plan = runner.plan_for(apps, service, "home", 0, 1, 3, root / "result.json",
                                   "a" * 40, "b" * 40, "local-device-01",
                                   "2099-01-01T00:00:00Z")
            container = root / "Containers" / service
            (container / "Data").mkdir(parents=True)
            (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
            plan["container"] = str(container)
            fake = MalformedDriverFailure()
            with mock.patch.object(runner, "request_fixture",
                                   side_effect=lambda _u, _p, method="GET":
                                   {"reset": True} if method == "POST" else {}):
                result = runner.capture(plan, apps, fake)

            self.assertEqual(result["capture_status"], "failure")
            failure = result["records"][0]
            self.assertNotIn("driver_failure", failure)
            self.assertIn("AX driver failed with malformed private result", failure["error"])
            self.assertNotIn("secret-token-value", json.dumps(result))
            self.assertEqual(list((root / "result-raw").glob(".pending-*")), [])

    def test_post_stop_keychain_reset_failure_invalidates_capture(self):
        class ResetFailure(CaptureExecutor):
            def __init__(self):
                super().__init__()
                self.security_calls = 0

            def run_status(self, argv):
                self.actions.append(argv)
                self.security_calls += 1
                # The first reset is 2 calls per account. Fail the first delete in the
                # post-stop reset; the finally path may retry cleanup, but cannot erase evidence
                # that the required boundary failed.
                return 1 if self.security_calls == 2 * len(runner.AUTH_ACCOUNTS) + 1 else 44

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, service = runner.validate_inputs(
                self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
            plan = runner.plan_for(apps, service, "home", 0, 1, 3, root / "result.json",
                                   "a" * 40, "b" * 40, "local-device-01",
                                   "2099-01-01T00:00:00Z")
            container = root / "Containers" / service
            (container / "Data").mkdir(parents=True)
            (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
            plan["container"] = str(container)
            fake = ResetFailure()
            ledger = {
                "schema_version": 1, "fixture_id": "fixture-123456789abc",
                "fixture_sha256": "a" * 64, "total": 6,
                "by_route": {route: 1 for route in
                             ("authenticate", "views", "resume", "next_up", "latest")},
                "by_status": {"200": 6}, "delayed": 0, "faulted": 0, "in_flight": 0,
                "max_in_flight": 2, "declared_response_bytes": {},
                "committed_response_bytes": {}, "write_failures": 0,
                "client_disconnects": 0,
            }

            def fixture_request(_url, _path, *, method="GET"):
                return {"reset": True} if method == "POST" else ledger

            with mock.patch.object(runner, "request_fixture", side_effect=fixture_request):
                result = runner.capture(plan, apps, fake)
            self.assertEqual(result["capture_status"], "failure")
            self.assertIn("dedicated Keychain reset failed", result["records"][0]["error"])
            self.assertFalse((root / "result-raw/sample-0001/manifest.json").exists())

    def test_catalog_search_and_artwork_publish_contract_valid_exact_phase_summaries(self):
        for scenario, phase in (
                ("catalog", "library_grid.complete"),
                ("search", "search.load"),
                ("artwork", "artwork.load")):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                apps, service = runner.validate_inputs(
                    self.make_app(root, "Control.app"), self.make_app(root, "Candidate.app"))
                plan = runner.plan_for(apps, service, scenario, 0, 1, 3, root / "result.json",
                                       "a" * 40, "b" * 40, "local-device-01",
                                       "2099-01-01T00:00:00Z")
                container = root / "Containers" / service
                (container / "Data").mkdir(parents=True)
                (container / ".com.apple.containermanagerd.metadata.plist").write_text("fixture")
                plan["container"] = str(container)
                fake = CaptureExecutor()
                routes = {"authenticate", "views", "items"}
                if scenario == "artwork":
                    routes.add("image")
                ledger = {
                    "schema_version": 1, "fixture_id": "fixture-123456789abc",
                    "fixture_sha256": "a" * 64, "total": 4,
                    "by_route": {route: 1 for route in routes},
                    "by_status": {"200": 4}, "delayed": 0, "faulted": 0, "in_flight": 0,
                    "max_in_flight": 2, "declared_response_bytes": {},
                    "committed_response_bytes": {}, "write_failures": 0,
                    "client_disconnects": 0,
                }

                def fixture_request(_url, _path, *, method="GET"):
                    return {"reset": True} if method == "POST" else ledger

                with mock.patch.object(runner, "request_fixture", side_effect=fixture_request):
                    result = runner.capture(plan, apps, fake)
                self.assertEqual(result["capture_status"], "success")
                for record in result["records"]:
                    manifest = pathlib.Path(record["manifest"])
                    summary = json.loads((manifest.parent / "summary/redacted.json").read_text())
                    self.assertEqual(summary["workload"]["phase"], phase)
                    self.assertEqual(summary["workload"]["backend"], "Emby")
                    self.assertEqual(summary["workload"]["expected_span_count"], 1)
                    if scenario == "artwork":
                        self.assertEqual(summary["workload"]["fields"], {
                            "milestone": "library_first_poster", "scoped": "1",
                        })


if __name__ == "__main__":
    unittest.main()
