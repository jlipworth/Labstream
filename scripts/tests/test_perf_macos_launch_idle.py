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


NATIVE_SCHEMA = """<schema name="thread-state" documentation="Determines that state of a thread during a given interval of time.">
<col><mnemonic>start</mnemonic><name>Start Time</name><engineering-type>start-time</engineering-type></col>
<col><mnemonic>thread</mnemonic><name>Thread</name><engineering-type>thread</engineering-type></col>
<col><mnemonic>state</mnemonic><name>State</name><engineering-type>thread-state</engineering-type></col>
<col><mnemonic>duration</mnemonic><name>Duration</name><engineering-type>duration</engineering-type></col>
<col><mnemonic>process</mnemonic><name>Process</name><engineering-type>process</engineering-type></col>
<col><mnemonic>core</mnemonic><name>Core</name><engineering-type>core</engineering-type></col>
<col><mnemonic>cputime</mnemonic><name>Running Time</name><engineering-type>duration-on-core</engineering-type></col>
<col><mnemonic>waittime</mnemonic><name>Wait Time</name><engineering-type>duration-waiting</engineering-type></col>
<col><mnemonic>priority</mnemonic><name>Priority</name><engineering-type>sched-priority</engineering-type></col>
<col><mnemonic>note</mnemonic><name>Note</name><engineering-type>narrative</engineering-type></col>
<col><mnemonic>summary</mnemonic><name>Summary</name><engineering-type>narrative</engineering-type></col>
<col><mnemonic>made-runnable-by-thread</mnemonic><name>Made Runnable By</name><engineering-type>thread</engineering-type></col>
<col><mnemonic>preempted-by-thread</mnemonic><name>Preempted By</name><engineering-type>thread</engineering-type></col>
<col><mnemonic>yielded-to-thread</mnemonic><name>Yielded To</name><engineering-type>thread</engineering-type></col>
<col><mnemonic>rebalanced-from-cpu</mnemonic><name>Rebalanced From CPU</name><engineering-type>core</engineering-type></col>
<col><mnemonic>thermal-throttled</mnemonic><name>Thermal Throttled</name><engineering-type>boolean</engineering-type></col>
</schema>"""


def native_toc(pid, duration):
    unit = "second" if duration == 1 else "seconds"
    return f"""<?xml version="1.0"?><trace-toc><run number="1"><info><target>
<process type="attached" return-exit-status="0" name="Labstream" pid="{pid}" termination-reason="exit(0)"/>
</target><summary><duration>{duration}.000000</duration><instruments-version>27.0 (17A456)</instruments-version>
<template-name>System Trace</template-name><time-limit>{duration} {unit}</time-limit></summary></info>
<data><table schema="thread-state" target-pid="SINGLE" documentation="Determines that state of a thread during a given interval of time."/></data>
</run></trace-toc>"""


def native_thread_state(pid):
    return f"""<?xml version="1.0"?><trace-query-result><node xpath="//trace-toc[1]/run[1]/data[1]/table[58]">
{NATIVE_SCHEMA}
<row><start-time id="1" fmt="0">0</start-time><thread id="20" fmt="target"><tid id="21" fmt="1">1</tid><process id="10" fmt="Labstream"><pid id="11" fmt="{pid}">{pid}</pid><device-session id="12" fmt="TODO">TODO</device-session></process></thread><thread-state id="40" fmt="Running">Running</thread-state><duration id="41" fmt="1 us">1000</duration><process ref="10"/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/></row>
<row><start-time id="2" fmt="1 us">1000</start-time><thread ref="20"/><thread-state id="42" fmt="Runnable">Runnable</thread-state><duration id="43" fmt="2 us">2000</duration><process ref="10"/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><sentinel/><thread id="30" fmt="kernel"><tid id="31" fmt="2">2</tid><process id="32" fmt="kernel"><pid id="33" fmt="0">0</pid><device-session ref="12"/></process></thread><sentinel/><sentinel/><sentinel/><sentinel/></row>
</node></trace-query-result>"""


class FakeExecutor:
    def __init__(self, fail_sleep=False, launch_phase="runtime.composition"):
        self.actions = []
        self.next_pid = 100
        self.fail_sleep = fail_sleep
        self.clock = datetime(2026, 7, 22, tzinfo=timezone.utc)
        self.processes = {}
        self.trace_pid = None
        self.trace_duration = None
        self.launch_phase = launch_phase

    def run(self, argv, *, stdout=-1):
        self.actions.append(("run", argv))
        if argv[:2] == ["/bin/rm", "-rf"]:
            import shutil
            shutil.rmtree(argv[2], ignore_errors=True)
        elif argv[:2] == ["/bin/mkdir", "-p"]:
            pathlib.Path(argv[2]).mkdir(parents=True, exist_ok=True)
        elif argv[:3] == ["/usr/bin/xcrun", "xctrace", "export"]:
            output_path = pathlib.Path(argv[argv.index("--output") + 1])
            output_path.write_text(native_toc(self.trace_pid, self.trace_duration)
                                   if "--toc" in argv else native_thread_state(self.trace_pid))
        elif (str(runner.SUMMARY) in argv or str(runner.IDLE_EXTRACTOR) in argv
              or (str(runner.CONTRACT) in argv and "manifest" in argv)):
            subprocess.run(argv, check=True, stdout=stdout, stderr=subprocess.STDOUT)
        elif argv[:4] == ["/usr/bin/log", "show", "--info", "--style"]:
            self.assert_ndjson(argv)
            profile = runner.LAUNCH_PHASE_PROFILES[self.launch_phase]
            stdout.write(
                f"perf.span phase={self.launch_phase} backend=App result=success "
                f"duration_ms=4 {profile['field']}\n".encode()
            )

    def assert_ndjson(self, argv):
        if argv[4] != "ndjson":
            raise AssertionError("unified-log capture must be one JSON event per line")

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
            trace = pathlib.Path(argv[argv.index("--output") + 1])
            trace.mkdir(parents=True)
            (trace / "data").write_bytes(b"trace-data")
            self.trace_pid = int(argv[argv.index("--attach") + 1])
            self.trace_duration = int(argv[argv.index("--time-limit") + 1].removesuffix("s"))
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

    def process_start_identity(self, pid):
        return f"start:{pid}"


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

    @staticmethod
    def cli_args(control, candidate, output):
        return [
            "--control-app", str(control), "--candidate-app", str(candidate),
            "--control-commit", "a" * 40, "--candidate-commit", "b" * 40,
            "--device-label", "local-device-01",
            "--retention-deadline", "2099-01-01T00:00:00Z",
            "--warmups", "0", "--measured", "1", "--duration-seconds", "1",
            "--output", str(output),
        ]

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
            container.mkdir()
            target.mkdir()
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

    def test_launch_attribution_profiles_are_exact_identity_bound_and_idle_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            common = dict(
                containers_root=root / "Containers", control_commit="a" * 40,
                candidate_commit="b" * 40, device_label="local-device-07",
            )
            composition = runner.command_plan(
                apps, "launch", 0, 1, 1, 7, root / "composition.json", **common)
            manager = runner.command_plan(
                apps, "launch", 0, 1, 1, 7, root / "manager.json",
                launch_phase="runtime.download_manager", **common)
            transport_construct = runner.command_plan(
                apps, "launch", 0, 1, 1, 7, root / "transport-construct.json",
                launch_phase="runtime.download_transport_construct", **common)
            transport_submission = runner.command_plan(
                apps, "launch", 0, 1, 1, 7, root / "transport-activation.json",
                launch_phase="runtime.download_transport_submission", **common)

            self.assertEqual(composition["launch_profile"], {
                "phase": "runtime.composition",
                "field": "downloads_capable=1",
                "correctness_field": "downloads_capable",
            })
            self.assertEqual(runner.launch_summary_arguments(manager), [
                "--phase", "runtime.download_manager", "--backend", "App",
                "--field", "background_events=1",
                "--correctness-field", "background_events",
                "--expected-span-count", "1",
            ])
            self.assertEqual(runner.launch_summary_arguments(transport_construct), [
                "--phase", "runtime.download_transport_construct", "--backend", "App",
                "--field", "background_session=1",
                "--correctness-field", "background_session",
                "--expected-span-count", "1",
            ])
            self.assertEqual(runner.launch_summary_arguments(transport_submission), [
                "--phase", "runtime.download_transport_submission", "--backend", "App",
                "--field", "startup_submission=1",
                "--correctness-field", "startup_submission",
                "--expected-span-count", "1",
            ])
            self.assertNotEqual(composition["identities"]["comparison_id"],
                                manager["identities"]["comparison_id"])
            self.assertNotEqual(composition["identities"]["workload_id"],
                                manager["identities"]["workload_id"])
            self.assertNotEqual(transport_construct["identities"]["workload_id"],
                                transport_submission["identities"]["workload_id"])
            self.assertNotEqual(transport_construct["identities"]["comparison_id"],
                                transport_submission["identities"]["comparison_id"])
            with self.assertRaisesRegex(runner.RunnerError, "idle scenario"):
                runner.command_plan(
                    apps, "idle", 0, 1, 1, 7, root / "idle.json",
                    launch_phase="runtime.download_store", **common)

    def test_launch_child_profile_selects_exact_span_for_strict_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(
                apps, "launch", 0, 1, 1, 9, root / "result.json",
                containers_root=root / "Containers",
                control_commit="a" * 40, candidate_commit="b" * 40,
                device_label="local-device-07", launch_phase="runtime.download_store")
            self.prepare_container(plan)

            result = runner.capture(
                plan, apps, FakeExecutor(launch_phase="runtime.download_store"))

            self.assertEqual(result["capture_status"], "success")
            for record in result["records"]:
                summary = json.loads(
                    (pathlib.Path(record["manifest"]).parent / "summary/redacted.json").read_text())
                self.assertEqual(summary["workload"]["phase"], "runtime.download_store")
                self.assertEqual(summary["workload"]["fields"], {"default_store": "1"})

    def test_launch_transport_profiles_select_exact_spans_for_strict_summary(self):
        profiles = (
            ("runtime.download_transport_construct", {"background_session": "1"}),
            ("runtime.download_transport_submission", {"startup_submission": "1"}),
        )
        for phase, expected_fields in profiles:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                        runner.validate_app("candidate", self.make_app(root, "B.app")))
                plan = runner.command_plan(
                    apps, "launch", 0, 1, 1, 9, root / "result.json",
                    containers_root=root / "Containers",
                    control_commit="a" * 40, candidate_commit="b" * 40,
                    device_label="local-device-07", launch_phase=phase)
                self.prepare_container(plan)

                result = runner.capture(plan, apps, FakeExecutor(launch_phase=phase))

                self.assertEqual(result["capture_status"], "success")
                for record in result["records"]:
                    summary = json.loads(
                        (pathlib.Path(record["manifest"]).parent
                         / "summary/redacted.json").read_text())
                    self.assertEqual(summary["workload"]["phase"], phase)
                    self.assertEqual(summary["workload"]["fields"], expected_fields)

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
            self.assertEqual(document["artifact_status"], "planned_typed_idle_per_run_manifests")
            self.assertNotIn("idle_export_compatibility", document)
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

    def test_duration_above_evidence_contract_bound_fails_before_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = self.make_app(temporary, "A.app")
            candidate = self.make_app(temporary, "B.app")
            fake = FakeExecutor()
            arguments = self.cli_args(control, candidate, pathlib.Path(temporary) / "result.json")
            arguments[arguments.index("1", arguments.index("--duration-seconds"))] = "86401"
            arguments.extend(["--scenario", "idle", "--plan"])
            with self.assertRaisesRegex(runner.RunnerError, r"1\.\.\.86400"):
                runner.main(arguments, executor=fake)
            self.assertEqual(fake.actions, [])

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
            self.assertEqual(len(contract_runs), 4)
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
            self.assertEqual(log_show[1][4], "ndjson")
            self.assertEqual(log_show[1][-1], str(app_spawn[2]))
            self.assertIn(("terminate", app_spawn[2]), fake.actions)
            self.assertEqual(result["verdict"]["status"], "insufficient_data")
            self.assertEqual(result["artifact_status"], "typed_idle_per_run_manifests")
            self.assertTrue(str(pathlib.Path(plan["container"])).startswith(str(root)))
            manifest_path = pathlib.Path(record["manifest"])
            manifest = json.loads(manifest_path.read_text())
            self.assertEqual(manifest["scenario"]["category"], "idle")
            self.assertFalse(manifest["evidence"]["publishable"])
            self.assertEqual([pointer["path"] for pointer in manifest["evidence"]["artifacts"]], [
                "raw/artifact-0001.trace.zip", "raw/artifact-0002.xml", "raw/artifact-0003.json",
            ])
            summary = json.loads((manifest_path.parent / "summary/redacted.json").read_text())
            self.assertEqual(summary["metrics"], {"cpu_running_ns": 1000, "wakeups_count": 1})
            self.assertNotIn(str(control), json.dumps(summary))
            self.assertFalse(any(path.name == "artifact.trace" for path in manifest_path.parent.iterdir()))
            export_runs = [a for a in fake.actions if a[0] == "run" and a[1][:3] ==
                           ["/usr/bin/xcrun", "xctrace", "export"]]
            self.assertEqual(len(export_runs), 4)
            self.assertIn("--toc", export_runs[0][1])
            self.assertEqual(export_runs[1][1][export_runs[1][1].index("--xpath") + 1],
                             runner.IDLE_XCTRACE_XPATH)
            extractor_run = next(a for a in fake.actions if a[0] == "run"
                                 and str(runner.IDLE_EXTRACTOR) in a[1])
            manifest_run = next(a for a in fake.actions if a[0] == "run"
                                and str(runner.CONTRACT) in a[1] and "manifest" in a[1])
            self.assertLess(fake.actions.index((
                "wait", trace_spawn[2], runner.IDLE_TRACE_FINALIZATION_TIMEOUT_SECONDS)),
                            fake.actions.index(("terminate", app_spawn[2])))
            self.assertLess(fake.actions.index(("terminate", app_spawn[2])),
                            fake.actions.index(export_runs[0]))
            self.assertLess(fake.actions.index(export_runs[1]), fake.actions.index(extractor_run))
            self.assertLess(fake.actions.index(extractor_run), fake.actions.index(manifest_run))
            self.assertFalse((manifest_path.parent / ".xctrace-toc.xml").exists())
            self.assertFalse((manifest_path.parent / ".xctrace-thread-state.xml").exists())
            for evidence in (manifest_path.read_text(),
                             (manifest_path.parent / "raw/artifact-0002.xml").read_text(),
                             (manifest_path.parent / "raw/artifact-0003.json").read_text(),
                             (manifest_path.parent / "summary/redacted.json").read_text()):
                self.assertNotIn(str(control), evidence)

    def test_idle_collision_starts_no_app_and_preserves_existing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(
                apps, "idle", 0, 1, 1, 4, root / "result.json",
                containers_root=root / "Containers", control_commit="a" * 40,
                candidate_commit="b" * 40)
            plan["samples"] = plan["samples"][:1]
            log_root = root / "result-logs"
            destination = log_root / runner.idle_run_id(plan, plan["samples"][0])
            destination.mkdir(parents=True)
            sentinel = destination / "sentinel"
            sentinel.write_text("keep")
            fake = FakeExecutor()
            result = runner.capture(plan, apps, fake)
            self.assertEqual(result["capture_status"], "failure")
            self.assertIn("already exists", result["records"][0]["failure"]["message"])
            self.assertEqual(sentinel.read_text(), "keep")
            self.assertFalse(any(path.name.startswith(".incomplete-idle-")
                                 for path in log_root.iterdir()))
            self.assertFalse(any(action[0] == "spawn" for action in fake.actions))

    def test_idle_extractor_failure_publishes_no_partial_run(self):
        class FailingExtractor(FakeExecutor):
            def run(self, argv, *, stdout=-1):
                if str(runner.IDLE_EXTRACTOR) in argv:
                    self.actions.append(("run", argv))
                    raise subprocess.CalledProcessError(
                        2, argv, output=b"error: native thread-state export contains an unknown state\n")
                return super().run(argv, stdout=stdout)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(apps, "idle", 0, 1, 1, 4, root / "result.json",
                                       containers_root=root / "Containers")
            plan["samples"] = plan["samples"][:1]
            self.prepare_container(plan)
            fake = FailingExtractor()
            result = runner.capture(plan, apps, fake)
            self.assertEqual(result["capture_status"], "failure")
            self.assertEqual(list((root / "result-logs").iterdir()), [])
            self.assertIn("unknown state", result["records"][0]["failure"]["message"])
            app_pid = next(action[2] for action in fake.actions
                           if action[0] == "spawn" and "xctrace" not in action[1])
            self.assertIn(("terminate", app_pid), fake.actions)

    def test_idle_trace_finalization_timeout_is_bounded_redacted_and_unpublished(self):
        class SlowFinalizer(FakeExecutor):
            def spawn(self, argv, *, stdout=-3):
                process = super().spawn(argv, stdout=stdout)
                if "xctrace" in argv:
                    self.xctrace_process_pid = process.pid
                return process

            def wait(self, process, timeout):
                self.actions.append(("wait", process.pid, timeout))
                if process.pid == self.xctrace_process_pid and process.returncode is None:
                    raise subprocess.TimeoutExpired("xctrace", timeout)
                process.returncode = 0 if process.returncode is None else process.returncode
                return process.returncode

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(apps, "idle", 0, 1, 120, 4, root / "result.json",
                                       containers_root=root / "Containers")
            plan["samples"] = plan["samples"][:1]
            self.prepare_container(plan)
            fake = SlowFinalizer()
            result = runner.capture(plan, apps, fake)
            record = result["records"][0]
            self.assertEqual(record["status"], "failure")
            self.assertEqual(
                record["failure"]["message"],
                "System Trace xctrace did not finalize within 120 seconds")
            trace_wait = ("wait", fake.xctrace_process_pid,
                          runner.IDLE_TRACE_FINALIZATION_TIMEOUT_SECONDS)
            self.assertIn(trace_wait, fake.actions)
            app_pid = next(action[2] for action in fake.actions
                           if action[0] == "spawn" and "xctrace" not in action[1])
            self.assertIn(("terminate", fake.xctrace_process_pid), fake.actions)
            self.assertIn(("terminate", app_pid), fake.actions)
            self.assertFalse(any(action[0] == "run" and action[1][:3] ==
                                 ["/usr/bin/xcrun", "xctrace", "export"]
                                 for action in fake.actions))
            self.assertEqual(list((root / "result-logs").iterdir()), [])

    def test_idle_tool_failure_detail_is_bounded_redacted_and_strict_utf8(self):
        command = [sys.executable, str(runner.IDLE_EXTRACTOR), "--toc-xml", "/private/input.xml"]
        unsafe = subprocess.CalledProcessError(
            2, command,
            output=(b'Traceback: /path/to/user/private.py line 4\n'
                    b'error: failed /path/to/user/private.xml token=abc password=hunter2 '
                    b'Authorization: secret Bearer credential https://user:pass@example.test/x\n'),
        )
        failure = runner.idle_failure_record(unsafe)
        self.assertIn("error: failed <path>", failure["message"])
        for secret in ("/Users", "alice", "abc", "hunter2", "secret", "credential",
                       "user:pass", "example.test", "Traceback"):
            self.assertNotIn(secret, failure["message"])
        self.assertLessEqual(len(failure["message"].encode()), runner.IDLE_FAILURE_DETAIL_MAX_BYTES)

        invalid = subprocess.CalledProcessError(
            2, command, output=b"error: useful prefix then invalid \xff\n")
        invalid_failure = runner.idle_failure_record(invalid)
        self.assertEqual(invalid_failure["message"], "idle extractor failed with exit status 2")

        contract_error = subprocess.CalledProcessError(
            1, [sys.executable, str(runner.CONTRACT), "manifest", "/private/manifest.json"],
            output=b"performance-audit-contract: FAIL: idle normalized XML row is unsupported\n",
        )
        self.assertIn("normalized XML row", runner.idle_failure_record(contract_error)["message"])

        unrelated = subprocess.CalledProcessError(
            7, ["/usr/bin/false"], output=b"error: should not be exposed\n")
        self.assertEqual(runner.idle_failure_record(unrelated)["message"], str(unrelated))

    def test_idle_cleanup_aggregates_and_retries_both_handles(self):
        class CleanupFailures(FakeExecutor):
            def poll(self, process):
                self.actions.append(("poll", process.pid))
                return None

            def terminate(self, pid):
                self.actions.append(("terminate", pid))
                raise RuntimeError(f"cleanup-{pid}")

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(apps, "idle", 0, 1, 1, 4, root / "result.json",
                                       containers_root=root / "Containers")
            plan["samples"] = plan["samples"][:1]
            self.prepare_container(plan)
            fake = CleanupFailures()
            result = runner.capture(plan, apps, fake)
            app_pid = next(action[2] for action in fake.actions
                           if action[0] == "spawn" and "xctrace" not in action[1])
            trace_pid = next(action[2] for action in fake.actions
                             if action[0] == "spawn" and "xctrace" in action[1])
            self.assertEqual(fake.actions.count(("terminate", app_pid)), 2)
            self.assertEqual(fake.actions.count(("terminate", trace_pid)), 2)
            failure = result["records"][0]["failure"]["message"]
            self.assertIn(f"app: RuntimeError: cleanup-{app_pid}", failure)
            self.assertIn(f"trace: RuntimeError: cleanup-{trace_pid}", failure)
            self.assertEqual(list((root / "result-logs").iterdir()), [])

    def test_idle_trace_symlink_is_rejected_without_publication(self):
        class SymlinkTrace(FakeExecutor):
            def spawn(self, argv, *, stdout=-3):
                process = super().spawn(argv, stdout=stdout)
                if "xctrace" in argv:
                    trace = pathlib.Path(argv[argv.index("--output") + 1])
                    (trace / "unsafe").symlink_to(trace / "data")
                return process

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(apps, "idle", 0, 1, 1, 4, root / "result.json",
                                       containers_root=root / "Containers")
            plan["samples"] = plan["samples"][:1]
            self.prepare_container(plan)
            result = runner.capture(plan, apps, SymlinkTrace())
            self.assertEqual(result["capture_status"], "failure")
            self.assertIn("symlink or special", result["records"][0]["failure"]["message"])
            self.assertEqual(list((root / "result-logs").iterdir()), [])

    def test_trace_archive_is_deterministic_for_the_same_safe_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            archives = []
            for ordinal in (1, 2):
                parent = root / str(ordinal)
                trace = parent / "artifact.trace"
                (trace / "nested").mkdir(parents=True)
                (trace / "data").write_bytes(b"same")
                (trace / "nested/value").write_bytes(b"bytes")
                archive = parent / "artifact.trace.zip"
                runner.archive_trace_directory(trace, archive)
                archives.append(archive.read_bytes())
            self.assertEqual(archives[0], archives[1])

    def test_nonintegrated_result_collision_and_symlink_fail_before_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            control = self.make_app(root, "A.app")
            candidate = self.make_app(root, "B.app")
            existing = root / "existing.json"
            existing.write_text("keep")
            for output in (existing, root / "link.json"):
                if output != existing:
                    output.symlink_to(existing)
                fake = FakeExecutor()
                with self.subTest(output=output), self.assertRaisesRegex(
                        runner.RunnerError, "must not already exist"):
                    runner.main(self.cli_args(control, candidate, output), executor=fake)
                self.assertEqual(fake.actions, [])
                self.assertEqual(existing.read_text(), "keep")
            real_parent = root / "real-parent"
            real_parent.mkdir()
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(real_parent, target_is_directory=True)
            fake = FakeExecutor()
            with self.assertRaisesRegex(runner.RunnerError, "not a real directory"):
                runner.main(self.cli_args(control, candidate, linked_parent / "result.json"),
                            executor=fake)
            self.assertEqual(fake.actions, [])

    def test_nonintegrated_result_is_exclusively_published_after_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            control = self.make_app(root, "A.app")
            candidate = self.make_app(root, "B.app")
            output = root / "nested/result.json"
            result = {"schema_version": 1, "capture_status": "success", "records": []}
            with mock.patch.object(runner, "capture", return_value=result) as capture:
                status = runner.main(self.cli_args(control, candidate, output), executor=FakeExecutor())
            self.assertEqual(status, 0)
            capture.assert_called_once()
            self.assertEqual(output.read_bytes(), runner._json_bytes(result))
            self.assertEqual(list(output.parent.glob(f".{output.name}.*.tmp")), [])
            with mock.patch.object(runner, "capture") as second_capture, self.assertRaisesRegex(
                    runner.RunnerError, "must not already exist"):
                runner.main(self.cli_args(control, candidate, output), executor=FakeExecutor())
            second_capture.assert_not_called()

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

    def integrated_fixture(self, root, *, cooldown=3):
        root = pathlib.Path(root).resolve()
        apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                runner.validate_app("candidate", self.make_app(root, "B.app")))
        output = root / "paired.json"
        plan = runner.command_plan(
            apps, "launch", 0, 1, 1, 7, output, containers_root=root / "Containers",
            control_commit="a" * 40, candidate_commit="b" * 40,
            device_label="local-device-07", cooldown_seconds=cooldown)
        calibration_output = root / "calibration.json"
        calibration = runner.calibration_plan_for(plan, calibration_output, 0)
        # Orchestration tests stay fast; the separate plan test proves the fixed 3+20 cardinality.
        calibration["samples"] = calibration["samples"][:2]
        calibration["warmups"] = 2
        calibration["measured"] = 0
        self.prepare_container(plan)
        return apps, plan, calibration, calibration_output, root / "frozen.json"

    @staticmethod
    def fake_frozen(_plan, records):
        return {"test": "frozen", "records": len(records)}

    def test_integrated_plan_has_control_only_3_plus_20_before_3_plus_20_pairs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(
                apps, "launch", 3, 20, 30, 9, root / "paired.json",
                containers_root=root / "Containers", control_commit="a" * 40,
                candidate_commit="b" * 40, cooldown_seconds=10)
            calibration = runner.calibration_plan_for(plan, root / "calibration.json", 1024)
            self.assertEqual(len(calibration["samples"]), 23)
            self.assertEqual(len(plan["samples"]), 46)
            self.assertEqual({sample["role"] for sample in calibration["samples"]}, {"control"})
            self.assertEqual((calibration["warmups"], calibration["measured"]), (3, 20))
            self.assertNotEqual(calibration["identities"]["comparison_id"],
                                plan["identities"]["comparison_id"])
            self.assertEqual(calibration["identities"]["order_seed"],
                             plan["identities"]["order_seed"])
            self.assertEqual(calibration["identities"]["workload_id"],
                             plan["identities"]["workload_id"])

    def test_integrated_plan_rejects_launch_profile_identity_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps = (runner.validate_app("control", self.make_app(root, "A.app")),
                    runner.validate_app("candidate", self.make_app(root, "B.app")))
            plan = runner.command_plan(
                apps, "launch", 3, 20, 30, 9, root / "paired.json",
                containers_root=root / "Containers", control_commit="a" * 40,
                candidate_commit="b" * 40, cooldown_seconds=10,
                launch_phase="runtime.download_manager")
            calibration = runner.calibration_plan_for(plan, root / "calibration.json", 1024)
            calibration["launch_profile"] = {
                "phase": "runtime.download_store",
                **runner.LAUNCH_PHASE_PROFILES["runtime.download_store"],
            }

            with self.assertRaisesRegex(runner.RunnerError, "fixed short-policy schedule"):
                runner.validate_integrated_plan(plan, calibration)

    def test_integrated_capture_cools_at_safe_boundaries_and_completion_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(root)
            fake = FakeExecutor()
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                result = runner.capture_integrated(
                    plan, calibration, apps, fake, calibration_output=calibration_output,
                    frozen_output=frozen, resume=False, max_pair_gap_seconds=120)
                launches = [action for action in fake.actions if action[0] == "spawn"]
                self.assertEqual(len(launches), 4)
                self.assertEqual([action for action in fake.actions if action == ("sleep", 3)],
                                 [("sleep", 3), ("sleep", 3)])
                before = len(launches)
                resumed = runner.capture_integrated(
                    plan, calibration, apps, fake, calibration_output=calibration_output,
                    frozen_output=frozen, resume=True, max_pair_gap_seconds=120)
            self.assertEqual(result, resumed)
            self.assertEqual(len([action for action in fake.actions if action[0] == "spawn"]), before)
            self.assertEqual(len(result["records"]), 2)
            self.assertTrue((root / "paired.json").is_file())

    def test_freeze_failure_blocks_every_candidate_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(root)
            calibration["samples"] = calibration["samples"][:1]
            fake = FakeExecutor()
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact",
                                   side_effect=runner.RunnerError("freeze rejected")):
                with self.assertRaisesRegex(runner.RunnerError, "freeze rejected"):
                    runner.capture_integrated(
                        plan, calibration, apps, fake, calibration_output=calibration_output,
                        frozen_output=frozen, resume=False, max_pair_gap_seconds=120)
            launched_paths = [action[1][0] for action in fake.actions if action[0] == "spawn"]
            self.assertEqual(launched_paths, [str(apps[0].executable)])
            self.assertFalse(frozen.exists())

    def test_interrupted_pair_resume_discards_half_pair_and_retries_both_arms(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(
                root, cooldown=0)
            fake = FakeExecutor()
            real_capture = runner.capture_launch_sample
            interrupted = False

            def crash_candidate(active_plan, sample, app, run_dir, executor, active_path):
                nonlocal interrupted
                if sample["role"] == "candidate" and not interrupted:
                    interrupted = True
                    raise KeyboardInterrupt()
                return real_capture(active_plan, sample, app, run_dir, executor, active_path)

            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}), \
                    mock.patch.object(runner, "capture_launch_sample", side_effect=crash_candidate):
                with self.assertRaises(KeyboardInterrupt):
                    runner.capture_integrated(
                        plan, calibration, apps, fake, calibration_output=calibration_output,
                        frozen_output=frozen, resume=False, max_pair_gap_seconds=120)
            paired_root = root / "paired-logs"
            self.assertEqual(list(paired_root.glob("pair-*")), [])
            self.assertEqual(len(list(paired_root.glob(".pending-pair-*"))), 1)
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                result = runner.capture_integrated(
                    plan, calibration, apps, fake, calibration_output=calibration_output,
                    frozen_output=frozen, resume=True, max_pair_gap_seconds=120)
            self.assertEqual(len(result["records"]), 2)
            self.assertEqual(len(list(paired_root.glob("pair-*"))), 1)
            self.assertEqual(list(paired_root.glob(".pending-pair-*")), [])

    def test_second_warmup_pair_resume_validates_retained_plus_pending_corpus(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(
                root, cooldown=0)
            plan["warmups"] = 2
            plan["measured"] = 0
            plan["samples"] = runner.schedule("launch", 2, 0, plan["seed"])
            fake = FakeExecutor()
            real_capture = runner.capture_launch_sample
            interrupted = False

            def crash_second_pair_arm_two(active_plan, sample, app, run_dir, executor, active_path):
                nonlocal interrupted
                if sample["sample_index"] == 1 and run_dir.name == "arm-2" and not interrupted:
                    interrupted = True
                    raise KeyboardInterrupt()
                return real_capture(active_plan, sample, app, run_dir, executor, active_path)

            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}), \
                    mock.patch.object(runner, "capture_launch_sample",
                                      side_effect=crash_second_pair_arm_two):
                with self.assertRaises(KeyboardInterrupt):
                    runner.capture_integrated(
                        plan, calibration, apps, fake, calibration_output=calibration_output,
                        frozen_output=frozen, resume=False, max_pair_gap_seconds=120)

            paired_root = root.resolve() / "paired-logs"
            self.assertEqual([path.name for path in paired_root.glob("pair-*")], ["pair-0001"])
            self.assertTrue((paired_root / ".pending-pair-0002").is_dir())
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                result = runner.capture_integrated(
                    plan, calibration, apps, fake, calibration_output=calibration_output,
                    frozen_output=frozen, resume=True, max_pair_gap_seconds=120)

            self.assertEqual(len(result["records"]), 4)
            self.assertEqual(sorted(path.name for path in paired_root.glob("pair-*")),
                             ["pair-0001", "pair-0002"])
            self.assertFalse((paired_root / ".pending-pair-0002").exists())

    def test_resume_rejects_tampered_retained_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(
                root, cooldown=0)
            fake = FakeExecutor()
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                runner.capture_integrated(
                    plan, calibration, apps, fake, calibration_output=calibration_output,
                    frozen_output=frozen, resume=False, max_pair_gap_seconds=120)
                manifest = next((root / "calibration-logs").glob("sample-*/manifest.json"))
                manifest.write_text(manifest.read_text() + " ")
                with self.assertRaisesRegex(runner.RunnerError, "checksum drift"):
                    runner.capture_integrated(
                        plan, calibration, apps, fake, calibration_output=calibration_output,
                        frozen_output=frozen, resume=True, max_pair_gap_seconds=120)

    def test_resume_validation_rejects_launch_phase_identity_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(
                root, cooldown=0)
            fake = FakeExecutor()
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                result = runner.capture_integrated(
                    plan, calibration, apps, fake, calibration_output=calibration_output,
                    frozen_output=frozen, resume=False, max_pair_gap_seconds=120)
            drifted = json.loads(json.dumps(plan))
            drifted["launch_profile"] = {
                "phase": "runtime.download_manager",
                **runner.LAUNCH_PHASE_PROFILES["runtime.download_manager"],
            }

            with self.assertRaisesRegex(runner.RunnerError, "identity drift"):
                runner.validate_records(
                    result["records"], plan["samples"],
                    pathlib.Path(plan["output"]).parent / "paired-logs",
                    drifted, apps, paired=True)

    def test_integrated_capture_rejects_symlinked_output_ancestor_before_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, _calibration_output, _frozen = self.integrated_fixture(root)
            outside = root / "outside"
            outside.mkdir()
            linked = root / "linked"
            linked.symlink_to(outside, target_is_directory=True)
            plan["output"] = str(linked / "paired.json")
            calibration_output = linked / "calibration.json"
            calibration["output"] = str(calibration_output)
            with mock.patch.object(runner, "validate_integrated_plan"):
                with self.assertRaisesRegex(runner.RunnerError, "unsafe directory ancestor"):
                    runner.capture_integrated(
                        plan, calibration, apps, FakeExecutor(),
                        calibration_output=calibration_output,
                        frozen_output=linked / "frozen.json", resume=False,
                        max_pair_gap_seconds=120)
            self.assertEqual(list(outside.iterdir()), [])

    def test_integrated_capture_rejects_cross_pair_timestamp_regression_before_publication(self):
        class RegressingClockExecutor(FakeExecutor):
            def __init__(self):
                super().__init__()
                self.now_calls = 0

            def now(self):
                if self.now_calls == 4:
                    self.clock = datetime(2026, 7, 22, tzinfo=timezone.utc)
                self.now_calls += 1
                return super().now()

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(
                root, cooldown=0)
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                with self.assertRaisesRegex(runner.RunnerError, "retained evidence chronologically"):
                    runner.capture_integrated(
                        plan, calibration, apps, RegressingClockExecutor(),
                        calibration_output=calibration_output, frozen_output=frozen,
                        resume=False, max_pair_gap_seconds=120)
            self.assertEqual(list((root / "paired-logs").glob("pair-*")), [])

    def test_every_arm_must_match_frozen_covariates_not_only_its_pair(self):
        class DriftingPairExecutor(FakeExecutor):
            def __init__(self):
                super().__init__()
                self.storage_reads = 0

            def disk_free(self, path):
                self.storage_reads += 1
                # Two calibration arms and the immediate pre-pair check are stable. Both pair
                # arms then drift together, so pair-mutual equality alone would incorrectly pass.
                return 1_000_000_000 if self.storage_reads <= 3 else 1_000_000_010

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            apps, plan, calibration, calibration_output, frozen = self.integrated_fixture(
                root, cooldown=0)
            with mock.patch.object(runner, "validate_integrated_plan"), \
                    mock.patch.object(runner, "calibration_artifact", side_effect=self.fake_frozen), \
                    mock.patch.object(runner.compare, "load_frozen", return_value={"ok": True}):
                with self.assertRaisesRegex(runner.RunnerError, "captured arm covariates"):
                    runner.capture_integrated(
                        plan, calibration, apps, DriftingPairExecutor(),
                        calibration_output=calibration_output, frozen_output=frozen,
                        resume=False, max_pair_gap_seconds=120)
            self.assertEqual(list((root / "paired-logs").glob("pair-*")), [])

    def test_bound_pid_recovery_signals_only_matching_start_identity(self):
        class RecoveryExecutor(FakeExecutor):
            def __init__(self, app, matching=True):
                super().__init__()
                self.app = app
                self.matching = matching
                self.alive = True

            def output(self, argv):
                if argv[:3] == ["/bin/ps", "-axo", "pid=,comm="] and self.alive:
                    return f"777 {self.app.executable}\n"
                return super().output(argv)

            def process_start_identity(self, pid):
                return "start:777" if self.matching else "different"

            def terminate(self, pid):
                self.actions.append(("terminate", pid))
                self.alive = False

            def wait(self, process, timeout):
                process.returncode = -15
                return -15

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            app = runner.validate_app("control", self.make_app(root, "A.app"))
            checkpoint = root / "active.json"
            runner.write_private_json_atomic(checkpoint, {
                "schema_version": 1, "status": "active", "pid": 777, "role": "control",
                "executable": str(app.executable), "bundle_id": app.bundle_id,
                "start_identity": "start:777"})
            matching = RecoveryExecutor(app)
            runner.cleanup_checkpointed_active_app(checkpoint, (app, app), matching)
            self.assertIn(("terminate", 777), matching.actions)
            self.assertEqual(runner.read_private_json(checkpoint), runner.cleared_active_app())

            runner.write_private_json_atomic(checkpoint, {
                "schema_version": 1, "status": "active", "pid": 777, "role": "control",
                "executable": str(app.executable), "bundle_id": app.bundle_id,
                "start_identity": "start:777"})
            reused = RecoveryExecutor(app, matching=False)
            runner.cleanup_checkpointed_active_app(checkpoint, (app, app), reused)
            self.assertNotIn(("terminate", 777), reused.actions)


if __name__ == "__main__":
    unittest.main()
