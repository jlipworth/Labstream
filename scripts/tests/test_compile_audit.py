import importlib.util
import csv
import pathlib
import subprocess
import sys
import tempfile
import unittest
import plistlib
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "compile-audit.py"
spec = importlib.util.spec_from_file_location("compile_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = audit
spec.loader.exec_module(audit)


class CompileAuditTests(unittest.TestCase):
    def test_plan_is_opt_in_and_covers_all_lanes(self):
        result = subprocess.run([sys.executable, SCRIPT], text=True, capture_output=True, check=True)
        self.assertIn("repetitions: 5", result.stdout)
        self.assertIn("control: <required with --run>", result.stdout)
        self.assertIn("candidate: <required with --run>", result.stdout)
        self.assertIn("pmskit: cold, no_op, incremental_PlaybackFailurePolicy, checked restoration, test_coverage", result.stdout)
        self.assertIn("visionos: clean, no_op", result.stdout)
        self.assertIn("mobile: clean, no_op", result.stdout)
        self.assertIn("mac: clean, no_op", result.stdout)
        self.assertIn(
            "incremental_ProgressSliver "
            "[Labstream/UI/ProgressSliver.swift | Labstream/Shared/UI/ProgressSliver.swift]",
            result.stdout,
        )
        self.assertIn(
            "incremental_PlaybackController "
            "[Labstream/Player/PlaybackController.swift | "
            "Labstream/Shared/Player/PlaybackController.swift]",
            result.stdout,
        )

    def test_run_requires_explicit_commits_and_at_least_five_repetitions(self):
        missing = subprocess.run([sys.executable, SCRIPT, "--run"], text=True, capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("--control and --candidate are required", missing.stderr)
        too_few = subprocess.run([sys.executable, SCRIPT, "--repetitions", "4"], text=True, capture_output=True)
        self.assertNotEqual(too_few.returncode, 0)
        self.assertIn("must be at least 5", too_few.stderr)

    def test_pair_order_alternates_and_seed_selects_first_order(self):
        self.assertEqual(audit.variant_order(1, 0), ("control", "candidate"))
        self.assertEqual(audit.variant_order(2, 0), ("candidate", "control"))
        self.assertEqual(audit.variant_order(1, 1), ("candidate", "control"))
        self.assertEqual(audit.variant_order(2, 1), ("control", "candidate"))

    def test_commands_use_fixed_architecture_and_isolated_paths(self):
        lane = audit.LANES[0]
        command = audit.command_for_xcode(pathlib.Path("/source"), pathlib.Path("/dd"), lane)
        self.assertIn("ARCHS=arm64", command)
        self.assertIn("/dd", command)
        pms = audit.command_for_pms(pathlib.Path("/source"), pathlib.Path("/scratch"), "test_coverage")
        self.assertIn("--enable-code-coverage", pms)
        self.assertEqual(pms[pms.index("--skip") + 1], "Live.*ProbeTests")
        self.assertEqual(pms[pms.index("--arch") + 1], "arm64")

    def test_live_probe_credentials_are_removed_from_measured_environment(self):
        with mock.patch.dict(audit.os.environ, {
            "PLEX_LIVE_TOKEN": "secret", "EMBY_LIVE_SERVER": "private",
            "JELLYFIN_ACCESS_TOKEN": "secret", "PATH": "/usr/bin",
        }, clear=True):
            environment = audit.isolated_environment()
        self.assertEqual(environment, {"PATH": "/usr/bin"})

    def test_pms_incremental_command_reuses_build_scratch_without_coverage(self):
        command = audit.command_for_pms(pathlib.Path("/source"), pathlib.Path("/scratch"), "incremental")
        self.assertEqual(command[0], "swift")
        self.assertEqual(command[1], "build")
        self.assertNotIn("--enable-code-coverage", command)
        self.assertEqual(command[command.index("--scratch-path") + 1], "/scratch")

    def test_warning_normalization_redacts_paths_urls_and_values(self):
        warning = audit.normalize_warning(
            'file.swift: warning: at /Users/person/private https://private.invalid "secret"'
        )
        self.assertNotIn("person", warning)
        self.assertNotIn("private.invalid", warning)
        self.assertNotIn("secret", warning)

    def test_typecheck_warning_parser_accepts_swift_warning_order(self):
        match = audit.TYPECHECK_RE.search("warning: function took 451ms to type-check (limit: 300ms)")
        self.assertEqual(match.group("kind"), "function")
        self.assertEqual(match.group("ms"), "451")

    def test_typecheck_warning_parser_accepts_swift_declaration_kinds(self):
        warnings = {
            "instance method 'render()' took 812ms to type-check": ("instance method", "812"),
            "getter for property 'body' took 301.5ms to type-check": ("getter", "301.5"),
            "initializer 'init(value:)' took 777ms to type-check": ("initializer", "777"),
            "closure took 499ms to type-check": ("closure", "499"),
        }
        for warning, expected in warnings.items():
            with self.subTest(warning=warning):
                match = audit.TYPECHECK_RE.search(warning)
                self.assertIsNotNone(match)
                self.assertEqual((match.group("kind"), match.group("ms")), expected)

    def test_machine_label_omits_hostname(self):
        label = audit.machine_label({"hardware_model": "Mac16,1", "macos_version": "99.0"})
        self.assertEqual(label, "Mac16,1 / macOS 99.0")
        self.assertNotIn(".local", label)

    def test_paired_deltas_match_repetitions_not_execution_order(self):
        def row(variant, repetition, seconds):
            return {
                "variant": variant, "group": "app", "lane": "mac", "scenario": "clean",
                "repetition": repetition, "result": 0, "seconds": seconds,
                "peak_rss_bytes": 10, "product_bytes": 20, "mach_o_bytes": 15,
                "compiled_file_count": 2, "link_count": 1, "warning_count": 0,
                "max_typecheck_ms": 0,
            }
        rows = [row("control", 1, 10), row("candidate", 1, 12),
                row("candidate", 2, 8), row("control", 2, 10)]
        deltas = audit.paired_deltas(rows)
        self.assertEqual([item["delta_seconds"] for item in deltas], [2, -2])
        self.assertEqual([item["delta_percent_seconds"] for item in deltas], [20, -20])

    def test_invalid_dependent_measurement_is_excluded_from_pair(self):
        invalid = audit.skipped_measurement(
            variant="candidate", commit="b", pair_order=2, group="app", lane="mac",
            scenario="no_op", repetition=1, reason="clean failed")
        control = {
            "variant": "control", "group": "app", "lane": "mac", "scenario": "no_op",
            "repetition": 1, "result": 0, "valid": True, "restoration_result": "",
            "restoration_source_match": "", "seconds": 10, "peak_rss_bytes": 10,
            "product_bytes": 20, "mach_o_bytes": 15, "compiled_file_count": 0,
            "link_count": 0, "warning_count": 0, "max_typecheck_ms": 0,
        }
        self.assertEqual(audit.paired_deltas([control, invalid]), [])

    def test_failed_restoration_is_not_usable_for_summary_or_pairing(self):
        row = {
            "result": 0, "valid": True, "restoration_result": 65,
            "restoration_source_match": True,
        }
        self.assertFalse(audit.measurement_is_usable(row))

    def test_incremental_pair_is_measured_before_either_settle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            sources = {variant: root / variant for variant in ("control", "candidate")}
            for source in sources.values():
                path = source / audit.PMS_EDIT_FILE
                path.parent.mkdir(parents=True)
                path.write_text("source\n")
            events = []

            def fake_measure(_command, **kwargs):
                events.append(f"measure:{kwargs['scenario']}:{kwargs['variant']}")
                return {
                    "result": 0, "valid": True, "restoration_result": "",
                    "restoration_source_match": "",
                }

            def fake_settle(*_args, **_kwargs):
                events.append("settle")
                return 0

            with mock.patch.object(audit, "LANES", ()), \
                 mock.patch.object(audit, "measure", side_effect=fake_measure), \
                 mock.patch.object(audit, "settle_restoration", side_effect=fake_settle):
                audit.run_repetition(
                    output=root, commits={"control": "a", "candidate": "b"},
                    sources=sources, repetition=1, seed=0, rows=[],
                    edit_paths={
                        variant: {edit.name: edit.paths[-1] for edit in audit.APP_EDITS}
                        for variant in sources
                    },
                )

            first = events.index("measure:incremental_PlaybackFailurePolicy:control")
            second = events.index("measure:incremental_PlaybackFailurePolicy:candidate")
            self.assertEqual(second, first + 1)
            self.assertNotIn("settle", events[first:second + 1])

    def test_edit_paths_resolve_per_snapshot_for_old_and_new_topology(self):
        existing = {
            ("old-commit", audit.PMS_EDIT_FILE),
            ("old-commit", "Labstream/UI/ProgressSliver.swift"),
            ("old-commit", "Labstream/Player/PlaybackController.swift"),
            ("new-commit", audit.PMS_EDIT_FILE),
            ("new-commit", "Labstream/Shared/UI/ProgressSliver.swift"),
            ("new-commit", "Labstream/Shared/Player/PlaybackController.swift"),
        }
        with mock.patch.object(
            audit, "path_exists_at_commit", side_effect=lambda commit, path: (commit, path) in existing
        ):
            resolved = audit.resolve_snapshot_edit_paths(
                {"control": "old-commit", "candidate": "new-commit"}
            )
        self.assertEqual(
            resolved["control"]["ProgressSliver"], "Labstream/UI/ProgressSliver.swift"
        )
        self.assertEqual(
            resolved["candidate"]["ProgressSliver"], "Labstream/Shared/UI/ProgressSliver.swift"
        )
        self.assertEqual(
            resolved["control"]["PlaybackController"], "Labstream/Player/PlaybackController.swift"
        )
        self.assertEqual(
            resolved["candidate"]["PlaybackController"],
            "Labstream/Shared/Player/PlaybackController.swift",
        )

    def test_missing_and_ambiguous_edit_topologies_are_rejected(self):
        edit = audit.RepresentativeEdit("Moved", ("old.swift", "new.swift"))
        with mock.patch.object(audit, "APP_EDITS", (edit,)), \
             mock.patch.object(audit, "path_exists_at_commit", return_value=False):
            with self.assertRaisesRegex(
                ValueError, r"candidate:Moved:missing \(old.swift, new.swift\)"
            ):
                audit.resolve_snapshot_edit_paths({"candidate": "commit"})
        with mock.patch.object(audit, "APP_EDITS", (edit,)), \
             mock.patch.object(audit, "path_exists_at_commit", return_value=True):
            with self.assertRaisesRegex(
                ValueError, r"candidate:Moved:ambiguous \(old.swift, new.swift\)"
            ):
                audit.resolve_snapshot_edit_paths({"candidate": "commit"})

    def test_exported_snapshot_must_exactly_match_resolved_topology(self):
        edit = audit.RepresentativeEdit("Moved", ("old.swift", "new.swift"))
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary) / "control"
            source.mkdir()
            (source / "old.swift").write_text("old\n")
            mapping = {"control": {"Moved": "old.swift"}}
            with mock.patch.object(audit, "APP_EDITS", (edit,)):
                audit.verify_exported_edit_paths({"control": source}, mapping)
                (source / "new.swift").write_text("ambiguous\n")
                with self.assertRaisesRegex(RuntimeError, "exported representative edit topology mismatch"):
                    audit.verify_exported_edit_paths({"control": source}, mapping)

    def test_per_snapshot_mapped_edits_restore_the_selected_file_byte_exactly(self):
        edit = audit.RepresentativeEdit("Moved", ("old.swift", "new.swift"))
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            sources = {variant: root / variant for variant in ("control", "candidate")}
            mapping = {
                "control": {"Moved": "old.swift"},
                "candidate": {"Moved": "new.swift"},
            }
            originals = {}
            for variant, source in sources.items():
                pms = source / audit.PMS_EDIT_FILE
                pms.parent.mkdir(parents=True)
                pms.write_bytes(b"pms\n")
                selected = source / mapping[variant]["Moved"]
                selected.parent.mkdir(parents=True, exist_ok=True)
                selected.write_bytes(f"{variant}\n".encode())
                originals[variant] = selected.read_bytes()
            observed = []

            def fake_measure(_command, **kwargs):
                if kwargs["group"] == "app" and kwargs["scenario"] == "incremental_Moved":
                    selected = sources[kwargs["variant"]] / mapping[kwargs["variant"]]["Moved"]
                    self.assertTrue(
                        selected.read_bytes().endswith(b"// compile-audit representative edit\n")
                    )
                    observed.append(kwargs["variant"])
                return {
                    "result": 0, "valid": True, "restoration_result": "",
                    "restoration_source_match": "",
                }

            with mock.patch.object(audit, "APP_EDITS", (edit,)), \
                 mock.patch.object(
                     audit, "LANES", (audit.Lane("test", "Test", "generic/platform=test"),)
                 ), \
                 mock.patch.object(audit, "measure", side_effect=fake_measure), \
                 mock.patch.object(audit, "settle_restoration", return_value=0):
                audit.run_repetition(
                    output=root, commits={"control": "a", "candidate": "b"},
                    sources=sources, repetition=1, seed=0, rows=[], edit_paths=mapping,
                )

            self.assertEqual(observed, ["control", "candidate"])
            for variant, source in sources.items():
                self.assertEqual(
                    (source / mapping[variant]["Moved"]).read_bytes(), originals[variant]
                )

    def test_integrity_manifest_covers_results_but_excludes_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary)
            (output / "summary.md").write_text("summary\n")
            (output / "raw.log").write_text("private\n")
            workspace = output / "workspace"
            workspace.mkdir()
            (workspace / "large-build-product").write_text("discardable\n")
            audit.write_integrity_manifest(output)
            manifest = (output / "manifest.sha256").read_text()
            self.assertIn("summary.md", manifest)
            self.assertIn("raw.log", manifest)
            self.assertNotIn("large-build-product", manifest)

    def test_csv_preserves_restoration_failure_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "measurements.csv"
            audit.write_csv(path, [{"scenario": "incremental", "result": 0,
                                    "restoration_result": 65,
                                    "restoration_source_match": True,
                                    "restoration_log": "settle.log"}])
            with path.open(newline="") as file:
                row = next(csv.DictReader(file))
            self.assertEqual(row["restoration_result"], "65")
            self.assertEqual(row["restoration_log"], "settle.log")

    def test_csv_can_record_an_empty_invalidated_pair_set(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "paired-deltas.csv"
            audit.write_csv(path, [], ("group", "delta_seconds"))
            self.assertEqual(path.read_text(), "group,delta_seconds\n")

    def test_source_restoration_check_is_byte_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "source.swift"
            path.write_bytes(b"original\n")
            self.assertTrue(audit.source_matches_restoration(path, b"original\n"))
            self.assertFalse(audit.source_matches_restoration(path, b"different\n"))

    def test_product_sizes_support_mac_debug_and_simulator_directories(self):
        for lane, build_directory, executable_path in (
            ("mac", "Debug", "Contents/MacOS/Labstream"),
            ("visionos", "Debug-xrsimulator", "Labstream"),
        ):
            with self.subTest(lane=lane), tempfile.TemporaryDirectory() as temporary:
                app = pathlib.Path(temporary) / "Build/Products" / build_directory / "Labstream.app"
                plist_path = app / ("Contents/Info.plist" if lane == "mac" else "Info.plist")
                plist_path.parent.mkdir(parents=True)
                plist_path.write_bytes(plistlib.dumps({"CFBundleExecutable": "Labstream"}))
                binary = app / executable_path
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(b"mach-o")
                app_bytes, mach_o_bytes = audit.product_sizes(pathlib.Path(temporary), lane)
                self.assertGreater(app_bytes, mach_o_bytes)
                self.assertEqual(mach_o_bytes, 6)


if __name__ == "__main__":
    unittest.main()
