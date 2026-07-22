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
    def __init__(self, pid):
        self.pid = pid
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
        }[self.last_scenario]
        return (f'{{"eventMessage":"perf.span phase={span[0]} backend=Emby '
                f'result=success duration_ms=10 {span[1]}"}}\n')

    def run(self, argv, *, stdout=-1):
        self.actions.append(("run", argv))
        if argv[:3] == ["/usr/bin/xcrun", "swiftc", str(runner.DRIVER)]:
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
                    "search": "search_loaded", "artwork": "artwork_requested",
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
        if argv[:2] == ["/bin/ps", "-axo"]:
            return ""
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

    def poll(self, process):
        return process.returncode

    def terminate(self, pid):
        self.actions.append(("terminate", pid))
        self.processes[pid].returncode = -15

    def kill(self, pid):
        self.actions.append(("kill", pid))
        self.processes[pid].returncode = -9

    def wait(self, process, timeout):
        return process.returncode

    def now(self):
        value = self.clock.isoformat(timespec="milliseconds")
        self.clock += timedelta(seconds=1)
        return value

    def disk_free(self, path):
        return 10_000_000_000


class BrowseRunnerTests(unittest.TestCase):
    def make_app(self, root, name, bundle="com.jlipworth.Labstream.perf.browse", service=None):
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
                self.assertEqual(sample["commands"]["app_arguments"], [])
                self.assertEqual(sample["commands"]["app_environment"], {})
                self.assertEqual(sample["commands"]["driver"][1:3],
                                 ["--pid", "{exact_pid}"])
            self.assertEqual(document["driver"]["preflight_compile"][:2],
                             ["/usr/bin/xcrun", "swiftc"])

    def test_validation_requires_dedicated_matching_keychain_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = self.make_app(temporary, "Control.app", service="com.visionplay.app")
            candidate = self.make_app(temporary, "Candidate.app", service="com.visionplay.app")
            with self.assertRaisesRegex(runner.RunnerError, "dedicated performance"):
                runner.validate_inputs(control, candidate)

    def test_keychain_reset_targets_only_closed_accounts_and_verifies_absence(self):
        fake = FakeExecutor([0, 44] * len(runner.AUTH_ACCOUNTS))
        service = "com.jlipworth.Labstream.perf.browse"
        runner.reset_performance_keychain(service, fake)
        self.assertEqual(len(fake.actions), 2 * len(runner.AUTH_ACCOUNTS))
        for account, delete, find in zip(runner.AUTH_ACCOUNTS,
                                         fake.actions[::2], fake.actions[1::2]):
            self.assertEqual(delete, ["/usr/bin/security", "delete-generic-password",
                                      "-s", service, "-a", account])
            self.assertEqual(find, ["/usr/bin/security", "find-generic-password",
                                    "-s", service, "-a", account])
        self.assertNotIn("clientIdentifier", " ".join(" ".join(row) for row in fake.actions))

    def test_keychain_reset_fails_closed_for_unproved_absence(self):
        with self.assertRaisesRegex(runner.RunnerError, "could not prove"):
            runner.reset_performance_keychain("com.jlipworth.Labstream.perf.browse",
                                              FakeExecutor([44, 0]))
        with self.assertRaisesRegex(runner.RunnerError, "non-performance"):
            runner.reset_performance_keychain("com.visionplay.app", FakeExecutor())

    def test_private_spec_is_exclusive_and_mode_0600(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "spec.json"
            runner.write_private_json(path, {"schema_version": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                runner.write_private_json(path, {"schema_version": 1})

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

    def test_driver_result_rejects_nonterminal_stage_for_every_scenario(self):
        expected = {
            "home": "home_loaded", "catalog": "catalog_loaded",
            "search": "search_loaded", "artwork": "artwork_requested",
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

        with self.assertRaisesRegex(runner.RunnerError, "multiple terminal"):
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
            self.assertNotIn("clientIdentifier", " ".join(" ".join(row) for row in keychain_deletes))
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
                    raise RuntimeError("driver failed")
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
            self.assertIn("driver failed", result["records"][0]["error"])
            fixture_pid = next(action[2] for action in fake.actions
                               if action[0] == "spawn" and str(runner.FIXTURE) in action[1])
            app_pids = [pid for pid in fake.processes if pid != fixture_pid]
            self.assertTrue(all(fake.processes[pid].returncode is not None for pid in app_pids))
            deletes = [action for action in fake.actions if isinstance(action, list)
                       and action[:2] == ["/usr/bin/security", "delete-generic-password"]]
            self.assertEqual(len(deletes), 2 * len(runner.AUTH_ACCOUNTS))

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

    def test_catalog_and_search_publish_contract_valid_exact_phase_summaries(self):
        for scenario, phase in (("catalog", "library_grid.complete"), ("search", "search.load")):
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
                ledger = {
                    "schema_version": 1, "fixture_id": "fixture-123456789abc",
                    "fixture_sha256": "a" * 64, "total": 4,
                    "by_route": {route: 1 for route in ("authenticate", "views", "items")},
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

    def test_artwork_capture_is_explicitly_rejected_before_processes(self):
        fake = CaptureExecutor()
        with self.assertRaisesRegex(runner.RunnerError, "pre-manifest"):
            runner.capture({"scenario": "artwork"}, (), fake)
        self.assertEqual(fake.actions, [])


if __name__ == "__main__":
    unittest.main()
