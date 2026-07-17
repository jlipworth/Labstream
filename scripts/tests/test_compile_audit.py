import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
import plistlib

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "compile-audit.py"
spec = importlib.util.spec_from_file_location("compile_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = audit
spec.loader.exec_module(audit)


class CompileAuditTests(unittest.TestCase):
    def test_plan_is_opt_in_and_covers_all_lanes(self):
        result = subprocess.run([sys.executable, SCRIPT], text=True, capture_output=True, check=True)
        self.assertIn("pmskit: cold, no_op, test_coverage", result.stdout)
        self.assertIn("visionos: clean, no_op", result.stdout)
        self.assertIn("mobile: clean, no_op", result.stdout)
        self.assertIn("mac: clean, no_op", result.stdout)

    def test_commands_use_fixed_architecture_and_isolated_paths(self):
        lane = audit.LANES[0]
        command = audit.command_for_xcode(pathlib.Path("/source"), pathlib.Path("/dd"), lane)
        self.assertIn("ARCHS=arm64", command)
        self.assertIn("/dd", command)
        pms = audit.command_for_pms(pathlib.Path("/source"), pathlib.Path("/scratch"), "test_coverage")
        self.assertIn("--enable-code-coverage", pms)
        self.assertEqual(pms[pms.index("--arch") + 1], "arm64")

    def test_warning_normalization_redacts_paths_urls_and_values(self):
        warning = audit.normalize_warning(
            'file.swift: warning: at /path/to/user/private https://private.invalid "secret"'
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
        label = audit.machine_label()
        self.assertIn("macOS", label)
        self.assertNotIn(".local", label)

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
