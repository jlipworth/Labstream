import json
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-macos-ax-driver.swift"


class PerfMacOSAXDriverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.binary = pathlib.Path(cls.build.name) / "perf-macos-ax-driver"
        subprocess.run(
            ["xcrun", "swiftc", str(SCRIPT), "-o", str(cls.binary)],
            check=True, capture_output=True, text=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def spec(self, **updates):
        document = {
            "schema_version": 1,
            "base_url": "http://127.0.0.1:54321",
            "username": "benchmark-user",
            "password": "benchmark-pass-v1",
            "scenario": "home",
            "timeout_seconds": 1,
        }
        document.update(updates)
        return document

    def run_driver(self, document, *, mode=0o600):
        workload = self.root / "workload.json"
        workload.write_text(json.dumps(document))
        workload.chmod(mode)
        output = self.root / "result.json"
        completed = subprocess.run(
            [str(self.binary), "--pid", str(os.getpid()),
             "--workload-spec", str(workload), "--output", str(output)],
            capture_output=True, text=True,
        )
        payload = json.loads(output.read_text())
        return completed, payload, output

    def test_valid_closed_spec_reaches_pid_preflight_and_writes_closed_result(self):
        completed, payload, output = self.run_driver(self.spec(scenario="search"))
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload, {
            "action_count": 0,
            "completed_stage": "preflight",
            "elapsed_milliseconds": payload["elapsed_milliseconds"],
            "error_code": "process_unavailable",
            "pid": os.getpid(),
            "scenario": "search",
            "schema_version": 1,
            "status": "failure",
            "tool": {"name": "labstream-macos-ax-driver", "version": 1},
        })
        self.assertGreaterEqual(payload["elapsed_milliseconds"], 0)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_spec_rejects_unknown_fields_and_group_readability(self):
        completed, payload, _ = self.run_driver(self.spec(token="not-allowed"))
        self.assertEqual((completed.returncode != 0, payload["error_code"]),
                         (True, "invalid_spec_schema"))

        completed, payload, _ = self.run_driver(self.spec(), mode=0o640)
        self.assertEqual((completed.returncode != 0, payload["error_code"]),
                         (True, "invalid_spec_permissions"))

    def test_spec_rejects_non_loopback_urls_arbitrary_credentials_and_unbounded_waits(self):
        cases = [
            (self.spec(base_url="http://localhost:54321"), "invalid_fixture_url"),
            (self.spec(base_url="https://127.0.0.1:54321"), "invalid_fixture_url"),
            (self.spec(base_url="http://user@127.0.0.1:54321"), "invalid_fixture_url"),
            (self.spec(username="private-user"), "invalid_fixture_credentials"),
            (self.spec(password="private-password"), "invalid_fixture_credentials"),
            (self.spec(timeout_seconds=0), "invalid_spec_schema"),
            (self.spec(timeout_seconds=121), "invalid_spec_schema"),
        ]
        for document, expected in cases:
            with self.subTest(expected=expected, document_key=next(
                    key for key, value in document.items()
                    if value != self.spec().get(key))):
                completed, payload, _ = self.run_driver(document)
                self.assertNotEqual(completed.returncode, 0)
                self.assertEqual(payload["error_code"], expected)
                rendered = json.dumps(payload) + completed.stderr
                self.assertNotIn("private-user", rendered)
                self.assertNotIn("private-password", rendered)

    def test_source_has_no_coordinate_click_or_ui_tree_dump_path(self):
        source = SCRIPT.read_text()
        self.assertNotIn("mouseCursorPosition", source)
        self.assertNotIn("AXPosition", source)
        self.assertNotIn("AXFrame", source)
        self.assertNotIn("print(element", source)
        self.assertIn("AXUIElementCreateApplication(pid)", source)
        self.assertIn("elementAmbiguous", source)
        self.assertIn("postToPid(pid)", source)
        self.assertIn("activate(options: [.activateAllWindows])", source)
        self.assertIn("registrationDeadline", source)
        self.assertIn("error == .cannotComplete || error == .invalidUIElement", source)
        self.assertIn("attribute: .description, values: [\"Emby\"]", source)
        self.assertIn("encodeNil(forKey: .errorCode)", source)


if __name__ == "__main__":
    unittest.main()
