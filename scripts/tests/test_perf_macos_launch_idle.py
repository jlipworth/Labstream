import contextlib
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-macos-launch-idle.py"
spec = importlib.util.spec_from_file_location("perf_macos_launch_idle", SCRIPT)
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
COMPARE = SCRIPT.parent / "perf-compare.py"
compare_spec = importlib.util.spec_from_file_location("perf_compare_for_macos_runner", COMPARE)
compare = importlib.util.module_from_spec(compare_spec)
sys.modules[compare_spec.name] = compare
compare_spec.loader.exec_module(compare)


class Process:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None


class FakeExecutor:
    def __init__(self, fail_sleep=False):
        self.actions = []
        self.next_pid = 100
        self.fail_sleep = fail_sleep
        self.clock = datetime(2026, 7, 22, tzinfo=timezone.utc)
        self.processes = {}

    def run(self, argv, *, stdout=-1):
        self.actions.append(("run", argv))
        if argv[:2] == ["/bin/rm", "-rf"]:
            import shutil
            shutil.rmtree(argv[2], ignore_errors=True)
        elif argv[:2] == ["/bin/mkdir", "-p"]:
            pathlib.Path(argv[2]).mkdir(parents=True, exist_ok=True)
        elif str(runner.SUMMARY) in argv or (str(runner.CONTRACT) in argv and "manifest" in argv):
            subprocess.run(argv, check=True, stdout=stdout, stderr=subprocess.STDOUT)
        elif argv[:4] == ["/usr/bin/log", "show", "--info", "--style"]:
            stdout.write(b"perf.span phase=runtime.composition backend=App result=success "
                         b"duration_ms=4 downloads_capable=1\n")

    def output(self, argv):
        self.actions.append(("output", argv))
        if "xctrace" in argv:
            return "System Trace\n"
        if argv[:2] == ["/usr/bin/sw_vers", "-buildVersion"]:
            return "25A123\n"
        if argv[:2] == ["/usr/bin/xcodebuild", "-version"]:
            return "Xcode 27.0\nBuild version 17A456\n"
        if argv[:3] == ["/usr/bin/pmset", "-g", "batt"]:
            return "Now drawing from 'AC Power'\n -InternalBattery-0 100%; charged\n"
        if argv[:3] == ["/usr/bin/pmset", "-g", "therm"]:
            return ("Note: No thermal warning level has been recorded\n"
                    "Note: No performance warning level has been recorded\n")
        return ""

    def disk_free(self, path):
        self.actions.append(("disk_free", str(path)))
        return 1_000_000_000

    def spawn(self, argv, *, stdout=-3):
        self.next_pid += 1
        self.actions.append(("spawn", argv, self.next_pid))
        if "xctrace" in argv:
            pathlib.Path(argv[argv.index("--output") + 1]).mkdir(parents=True)
        process = Process(self.next_pid)
        self.processes[process.pid] = process
        return process

    def sleep(self, seconds):
        self.actions.append(("sleep", seconds))
        if self.fail_sleep:
            raise RuntimeError("clock failed")

    def terminate(self, pid):
        self.actions.append(("terminate", pid))
        self.processes[pid].returncode = -15

    def kill(self, pid):
        self.actions.append(("kill", pid))
        self.processes[pid].returncode = -9

    def poll(self, process):
        self.actions.append(("poll", process.pid))
        return process.returncode

    def wait(self, process, timeout):
        self.actions.append(("wait", process.pid, timeout))
        process.returncode = 0 if process.returncode is None else process.returncode
        return process.returncode

    def now(self):
        value = self.clock.isoformat(timespec="milliseconds")
        self.clock += timedelta(seconds=1)
        self.actions.append(("now", value))
        return value


class RunnerTests(unittest.TestCase):
    def make_app(self, root, name, bundle="com.jlipworth.Labstream.perf.audit"):
        app = pathlib.Path(root) / name
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "Labstream",
        }))
        binary = macos / "Labstream"
        binary.write_bytes(b"binary")
        binary.chmod(0o755)
        return app

    def prepare_container(self, plan):
        container = pathlib.Path(plan["container"])
        (container / "Data").mkdir(parents=True, mode=0o700)
        (container / "Data").chmod(0o700)
        (container / ".com.apple.containermanagerd.metadata.plist").write_bytes(b"fixture")

    def test_canonical_empty_index_bytes_and_digest_are_frozen(self):
        self.assertEqual(runner.CANONICAL_INDEX, b'{"schemaVersion":4,"rows":[]}\n')
        self.assertEqual(
            runner.CANONICAL_INDEX_SHA256,
            "109c196b8a013bc4ca80a3de58b26981571817011021e92eb0dbcd35827906e1",
        )

    def test_log_time_bounds_use_supported_epoch_seconds_with_outward_rounding(self):
        self.assertEqual(runner.log_time_bound("2026-07-22T16:08:32.164Z"), "@1784736512")
        self.assertEqual(runner.log_time_bound("2026-07-22T16:08:37.382Z", end=True),
                         "@1784736518")

    def test_seed_preserves_system_data_root_and_clears_only_children(self):
        with tempfile.TemporaryDirectory() as temporary:
            container = pathlib.Path(temporary) / "com.jlipworth.Labstream.perf.audit"
            data = container / "Data"
            data.mkdir(parents=True, mode=0o700)
            data.chmod(0o700)
            (container / ".com.apple.containermanagerd.metadata.plist").write_bytes(b"fixture")
            (data / "stale").mkdir()
            (data / "stale/value").write_text("old")
            before = data.stat()

            runner.seed_container(container, FakeExecutor())

            after = data.stat()
            self.assertEqual((after.st_dev, after.st_ino), (before.st_dev, before.st_ino))
            self.assertEqual(after.st_mode & 0o777, 0o700)
            self.assertFalse((data / "stale").exists())
            self.assertEqual((container / runner.INDEX_RELATIVE).read_bytes(),
                             runner.CANONICAL_INDEX)

    def test_seed_rejects_symlinked_data_root_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            container = root / "com.jlipworth.Labstream.perf.audit"
            target = root / "outside"
            container.mkdir(); target.mkdir()
            (container / ".com.apple.containermanagerd.metadata.plist").write_bytes(b"fixture")
            (target / "sentinel").write_text("keep")
            (container / "Data").symlink_to(target, target_is_directory=True)

            with self.assertRaises(runner.RunnerError):
                runner.seed_container(container, FakeExecutor())

            self.assertEqual((target / "sentinel").read_text(), "keep")

    def test_bundle_digest_tracks_entry_boundaries_and_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(temporary, "A.app")
            resource = app / "Contents/Resources/value"
            resource.parent.mkdir()
            resource.write_bytes(b"payload")
            initial = runner.bundle_sha256(app)
            resource.chmod(0o700)
            self.assertNotEqual(runner.bundle_sha256(app), initial)
            resource.chmod(0o600)
            resource.rename(resource.with_name("renamed"))
            self.assertNotEqual(runner.bundle_sha256(app), initial)

    def test_default_schedules_are_adjacent_balanced_pairs(self):
        launch = runner.schedule("launch", 3, 20, 7)
        idle = runner.schedule("idle", 1, 5, 7)
        self.assertEqual(len(launch), 46)
        self.assertEqual(len(idle), 12)
        for rows in (launch, idle):
            for offset in range(0, len(rows), 2):
                pair = rows[offset:offset + 2]
                self.assertEqual({r["role"] for r in pair}, {"control", "candidate"})
                self.assertEqual(pair[0]["sample_index"], pair[1]["sample_index"])
                self.assertEqual([r["pair_order"] for r in pair], [1, 2])
                order_seed = runner.opaque("seed", 7, length=16)
                expected = ("control" if __import__("hashlib").sha256(
                    f'{order_seed}:{pair[0]["sample_kind"]}:{pair[0]["sample_index"]}'.encode()
                ).digest()[0] & 1 == 0 else "candidate")
                self.assertEqual(pair[0]["role"], expected)
            self.assertEqual(sorted({r["sample_index"] for r in rows if r["sample_kind"] == "measured"}),
                             list(range(20 if rows is launch else 5)))
        self.assertEqual(launch, runner.schedule("launch", 3, 20, 7))

    def test_app_validation_rejects_production_mismatch_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            prod = self.make_app(temporary, "Prod.app", "com.jlipworth.Labstream")
            with self.assertRaisesRegex(runner.RunnerError, "com.jlipworth.Labstream.perf"):
                runner.validate_app("control", prod)
            control = self.make_app(temporary, "A.app")
            other = self.make_app(temporary, "B.app", "com.jlipworth.Labstream.perf.other")
            with self.assertRaisesRegex(runner.RunnerError, "same dedicated"):
                runner.validate_pair(control, other)
            link = pathlib.Path(temporary) / "Link.app"
            link.symlink_to(control)
            with self.assertRaisesRegex(runner.RunnerError, "non-symlink"):
                runner.validate_app("control", link)

    def test_preflight_rejects_an_existing_exact_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            apps = (runner.validate_app("control", self.make_app(temporary, "A.app")),
                    runner.validate_app("candidate", self.make_app(temporary, "B.app")))
            fake = FakeExecutor()
            fake.output = lambda argv: f"{apps[1].executable}\n"
            with self.assertRaisesRegex(runner.RunnerError, "already running"):
                runner.preflight_no_existing_app(apps, fake)

    def test_preflight_rejects_same_bundle_from_another_app_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            other = self.make_app(root, "PreviouslyStaged.app")
            fake = FakeExecutor()
            fake.output = lambda argv: f"{other}/Contents/MacOS/Labstream\n"
            with self.assertRaisesRegex(runner.RunnerError, "bundle identifier"):
                runner.preflight_no_existing_app(apps, fake)

    def test_bundle_suffix_is_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(temporary, "A.app",
                                "com.jlipworth.Labstream.perf." + "a" * 49)
            with self.assertRaisesRegex(runner.RunnerError, "lowercase-label"):
                runner.validate_app("control", app)

    def test_missing_system_trace_template_fails_before_container_reset(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            containers = root / "Containers"
            plan = runner.command_plan(apps, "idle", 0, 1, 1, 0, root / "result.json",
                                       containers_root=containers)
            fake = FakeExecutor()
            fake.output = lambda argv: ""  # no existing process and no required template
            with self.assertRaisesRegex(runner.RunnerError, "no capture started"):
                runner.capture(plan, apps, fake)
            self.assertFalse(any(a[0] == "run" and a[1][:2] == ["/bin/rm", "-rf"]
                                 for a in fake.actions))

    def test_cleanup_bounds_term_and_kill_timeouts(self):
        class Stuck(FakeExecutor):
            def wait(self, process, timeout):
                self.actions.append(("wait", process.pid, timeout))
                raise subprocess.TimeoutExpired("wait", timeout)

        fake = Stuck()
        process = Process(777)
        fake.processes[777] = process
        error = runner.stop_and_prove_gone(process, fake)
        self.assertIn("both TERM and KILL", error)
        self.assertIn(("terminate", 777), fake.actions)
        self.assertIn(("kill", 777), fake.actions)

    def test_plan_mode_is_json_and_executes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = self.make_app(temporary, "A.app")
            candidate = self.make_app(temporary, "B.app")
            fake = FakeExecutor()
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = runner.main([
                    "--control-app", str(control), "--candidate-app", str(candidate),
                    "--control-commit", "a" * 40, "--candidate-commit", "b" * 40,
                    "--device-label", "local-device-01",
                    "--retention-deadline", "2099-01-01T00:00:00Z",
                    "--scenario", "idle", "--plan",
                ], executor=fake)
            document = json.loads(stdout.getvalue())
            self.assertEqual(result, 0)
            self.assertEqual(fake.actions, [])
            self.assertEqual(document["mode"], "plan")
            self.assertEqual(document["artifact_status"], "pre_manifest_raw_capture")
            self.assertEqual((document["warmups"], document["measured"],
                              document["duration_seconds"]), (1, 5, 120))
            self.assertEqual(document["settle_seconds"], 10)
            self.assertEqual(document["container"],
                             str(pathlib.Path.home() / "Library/Containers/com.jlipworth.Labstream.perf.audit"))
            self.assertEqual(document["samples"][0]["commands"]["reset"], {
                "operation": "fd_anchored_clear_children",
                "path": str(pathlib.Path(document["container"]) / "Data"),
                "preserve_root": True,
            })
            self.assertTrue(all(s["commands"]["app_arguments"] == [] for s in document["samples"]))
            self.assertTrue(all(s["commands"]["app_environment"] == {} for s in document["samples"]))
            self.assertTrue(all(s["commands"]["log"][-1] == "{exact_pid}" for s in document["samples"]))
            self.assertTrue(all("System Trace" in s["commands"]["idle_trace"]
                                for s in document["samples"]))

    def test_capture_checks_binaries_seeds_externally_and_uses_exact_pids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            control = runner.validate_app("control", self.make_app(root, "A.app"))
            candidate = runner.validate_app("candidate", self.make_app(root, "B.app"))
            output = root / "result.json"
            containers = root / "Containers"
            plan = runner.command_plan((control, candidate), "idle", 0, 1, 1, 2, output,
                                       containers_root=containers)
            fake = FakeExecutor()
            self.prepare_container(plan)
            result = runner.capture(plan, (control, candidate), fake)
            contract_runs = [a for a in fake.actions if a[0] == "run" and
                             "performance-audit-contract.py" in " ".join(a[1])]
            self.assertEqual(len(contract_runs), 2)
            index = pathlib.Path(plan["container"]) / runner.INDEX_RELATIVE
            self.assertEqual(index.read_bytes(), runner.CANONICAL_INDEX)
            record = result["records"][0]
            self.assertEqual(record["status"], "success")
            app_spawn = next(a for a in fake.actions if a[0] == "spawn")
            self.assertLess(next(i for i, a in enumerate(fake.actions) if a[0] == "now"),
                            fake.actions.index(app_spawn))
            trace_spawn = next(a for a in fake.actions if a[0] == "spawn" and "xctrace" in a[1])
            self.assertEqual(trace_spawn[1][trace_spawn[1].index("--attach") + 1], str(app_spawn[2]))
            trace_action_index = fake.actions.index(trace_spawn)
            self.assertIn(("sleep", 10), fake.actions[:trace_action_index])
            log_show = next(a for a in fake.actions if a[0] == "run" and a[1][:4] ==
                            ["/usr/bin/log", "show", "--info", "--style"])
            self.assertEqual(log_show[1][-1], str(app_spawn[2]))
            self.assertIn(("terminate", app_spawn[2]), fake.actions)
            self.assertEqual(result["verdict"]["status"], "insufficient_data")
            self.assertEqual(result["artifact_status"], "pre_manifest_raw_capture")
            self.assertTrue(str(pathlib.Path(plan["container"])).startswith(str(root)))

    def test_capture_retains_failure_record_and_terminates_both_pids(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(apps, "launch", 0, 1, 1, 0, root / "result.json",
                                       containers_root=root / "Containers")
            fake = FakeExecutor(fail_sleep=True)
            self.prepare_container(plan)
            result = runner.capture(plan, apps, fake)
            self.assertEqual([r["status"] for r in result["records"]], ["failure", "failure"])
            self.assertTrue(all(r["failure"]["type"] == "RuntimeError" for r in result["records"]))
            spawned = [a[2] for a in fake.actions if a[0] == "spawn" and "xctrace" not in a[1]]
            terminated = [a[1] for a in fake.actions if a[0] == "terminate"]
            self.assertEqual(sorted(spawned), sorted(terminated))
            self.assertTrue(str(pathlib.Path(plan["container"])).startswith(str(root)))

    def test_launch_capture_emits_contract_valid_manifest_and_strict_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(apps, "launch", 0, 1, 1, 9, root / "result.json",
                                       containers_root=root / "Containers",
                                       control_commit="a" * 40, candidate_commit="b" * 40,
                                       device_label="local-device-07")
            self.assertEqual(plan["artifact_status"], "planned_admissible_per_run_manifests")
            self.prepare_container(plan)
            result = runner.capture(plan, apps, FakeExecutor())
            loaded = {"control": [], "candidate": []}
            for record in result["records"]:
                self.assertEqual(record["status"], "success")
                manifest_path = pathlib.Path(record["manifest"])
                manifest = json.loads(manifest_path.read_text())
                self.assertEqual(manifest["scenario"]["backend_kind"], "none")
                self.assertEqual(manifest["product"]["commit"],
                                 ("a" if record["role"] == "control" else "b") * 40)
                summary = json.loads((manifest_path.parent / "summary/redacted.json").read_text())
                self.assertEqual(summary["workload"]["phase"], "runtime.composition")
                self.assertEqual(summary["rows"][0]["backend"], "App")
                raw = (manifest_path.parent / "raw/artifact-0001.log").read_text()
                self.assertEqual(raw.count("perf.capture "), 1)
                sample = compare.load_sample(manifest_path, record["role"])
                self.assertEqual(sample.index, 0)
                loaded[record["role"]].append(sample)
            covariates = compare._validate_pairing(loaded["control"], loaded["candidate"],
                                                   max_storage_drift=0,
                                                   max_pair_gap_seconds=120)
            self.assertEqual(covariates[("measured", 0)]["thermal_state"], "nominal")


if __name__ == "__main__":
    unittest.main()
