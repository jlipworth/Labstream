import hashlib
import importlib.util
import json
import pathlib
import plistlib
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "performance-audit-contract.py"
spec = importlib.util.spec_from_file_location("performance_audit_contract", SCRIPT)
contract = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = contract
spec.loader.exec_module(contract)


class PerformanceAuditContractTests(unittest.TestCase):
    def release_settings(self) -> dict[str, str]:
        settings = {key: "same" for key in contract.RELEASE_PARITY_KEYS}
        settings.update({
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "GCC_OPTIMIZATION_LEVEL": "s",
            "ENABLE_NS_ASSERTIONS": "NO",
            "ENABLE_TESTABILITY": "NO",
            "ENABLE_ADDRESS_SANITIZER": "NO",
            "ENABLE_THREAD_SANITIZER": "NO",
            "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER": "NO",
            "OTHER_SWIFT_FLAGS": "",
            "OTHER_CFLAGS": "",
            "OTHER_CPLUSPLUSFLAGS": "",
            "GCC_PREPROCESSOR_DEFINITIONS": "",
        })
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ""
        return settings

    def manifest(self, root: pathlib.Path) -> dict:
        raw = root / "raw" / "artifact-0001.trace"
        summary = root / "summary" / "redacted.json"
        raw.parent.mkdir(exist_ok=True)
        summary.parent.mkdir(exist_ok=True)
        raw.write_bytes(b"trace")
        summary.write_text("{}")

        def pointer(path: pathlib.Path) -> dict:
            return {
                "path": path.relative_to(root).as_posix(),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }

        return {
            "schema_version": 1,
            "tool": {"name": "labstream-performance-audit", "version": "1"},
            "run": {
                "id": "run-0123456789ab",
                "recorded_at": "2026-07-21T00:00:00Z",
                "comparison_id": "comparison-0123456789ab",
                "artifact_role": "control",
                "sample_kind": "measured",
                "sample_index": 1,
                "order_seed": "seed-0123456789abcdef",
            },
            "product": {
                "commit": "a" * 40,
                "sha256": "b" * 64,
                "configuration": "PerformanceAudit",
                "target": "Labstream",
                "platform": "visionos",
                "os_build": "24A123",
                "xcode_build": "17A456",
            },
            "device": {
                "label": "local-device-01",
                "power_source": "external",
                "battery_state": "full",
                "thermal_state": "nominal",
                "free_storage_bytes": 1000000,
                "display_mode": "windowed",
            },
            "state": {
                "install_state": "fresh_install",
                "container_state": "restored_fixture",
                "cache_reset": {"command_id": "app-cache-reset-v1", "result": "success"},
            },
            "scenario": {
                "id": "scenario-0123456789ab",
                "category": "launch",
                "run_kind": "deterministic_fixture",
                "fixture_id": "fixture-0123456789ab",
                "fixture_sha256": "c" * 64,
                "backend_kind": "none",
                "server_version": None,
                "cache_state": "cold",
            },
            "launch_contract": {
                "arguments": [],
                "environment_keys": [],
                "ui_test_fixture": False,
                "live_probe": False,
                "tv_event_swizzle": False,
                "verbose_debug_evidence": False,
            },
            "evidence": {
                "artifacts": [pointer(raw)],
                "redacted_summary": pointer(summary),
                "privacy_review": "pending",
                "retention_deadline": "2026-08-21T00:00:00Z",
                "publishable": False,
            },
        }

    def test_manifest_accepts_versioned_private_local_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            contract.validate_manifest(self.manifest(root), root)

    def test_manifest_rejects_unreviewed_publishable_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = self.manifest(root)
            manifest["evidence"]["publishable"] = True
            with self.assertRaisesRegex(contract.ContractError, "privacy review"):
                contract.validate_manifest(manifest, root)

    def test_manifest_rejects_private_urls_and_absolute_paths_without_echoing_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for value, expected in (
                ("https://private.invalid", "forbidden URL"),
                ("/Users/private/run", "forbidden absolute user path"),
                ("personal-device-name", "opaque local-device-NN"),
            ):
                with self.subTest(value=value):
                    manifest = self.manifest(root)
                    manifest["device"]["label"] = value
                    with self.assertRaisesRegex(contract.ContractError, expected):
                        contract.validate_manifest(manifest, root)

    def test_manifest_rejects_hostname_media_and_account_labels_in_identifier_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            cases = (
                (("run", "id"), "nas.home.internal", "opaque run"),
                (("scenario", "fixture_id"), "SecretMovieTitle", "opaque fixture"),
                (("scenario", "id"), "personal-account-name", "opaque scenario"),
                (("evidence", "artifacts", 0, "path"), "raw/SecretMovieTitle.trace", "opaque raw"),
            )
            for field_path, value, expected in cases:
                with self.subTest(field_path=field_path):
                    manifest = self.manifest(root)
                    cursor = manifest
                    for component in field_path[:-1]:
                        cursor = cursor[component]
                    cursor[field_path[-1]] = value
                    with self.assertRaisesRegex(contract.ContractError, expected):
                        contract.validate_manifest(manifest, root)

    def test_manifest_rejects_hostname_as_live_server_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = self.manifest(root)
            manifest["scenario"].update({
                "run_kind": "live_server",
                "fixture_id": None,
                "fixture_sha256": None,
                "backend_kind": "plex",
                "server_version": "nas.home.internal",
            })
            with self.assertRaisesRegex(contract.ContractError, "version-shaped"):
                contract.validate_manifest(manifest, root)

    def test_manifest_rejects_fixture_and_live_server_identity_mix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = self.manifest(root)
            manifest["scenario"]["server_version"] = "1.2.3"
            with self.assertRaisesRegex(contract.ContractError, "must not claim a live server"):
                contract.validate_manifest(manifest, root)

    def test_manifest_rejects_checksum_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = self.manifest(root)
            (root / "raw" / "artifact-0001.trace").write_bytes(b"changed")
            with self.assertRaisesRegex(contract.ContractError, "does not match"):
                contract.validate_manifest(manifest, root)

    def test_build_setting_comparison_allows_only_audit_condition(self):
        release = self.release_settings()
        audit = dict(release)
        audit["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "PERFORMANCE_AUDIT"
        contract.compare_build_settings(release, audit, "Labstream")

    def test_build_setting_comparison_rejects_compiler_flags_definitions_and_sanitizers(self):
        release = self.release_settings()
        changes = {
            "OTHER_SWIFT_FLAGS": "-D DEBUG -Onone",
            "OTHER_CFLAGS": "-O0",
            "GCC_PREPROCESSOR_DEFINITIONS": "DEBUG=1",
            "ENABLE_ADDRESS_SANITIZER": "YES",
            "ENABLE_NS_ASSERTIONS": "YES",
        }
        for key, value in changes.items():
            with self.subTest(key=key):
                audit = dict(release)
                audit["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "PERFORMANCE_AUDIT"
                audit[key] = value
                with self.assertRaisesRegex(contract.ContractError, key):
                    contract.compare_build_settings(release, audit, "Labstream")

    def test_build_setting_comparison_rejects_unoptimized_release_parity(self):
        release = self.release_settings()
        release["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
        audit = dict(release)
        audit["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "PERFORMANCE_AUDIT"
        with self.assertRaisesRegex(contract.ContractError, "optimized Swift"):
            contract.compare_build_settings(release, audit, "Labstream")

    def make_app(self, root: pathlib.Path, payload: bytes) -> pathlib.Path:
        app = root / "Labstream.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Labstream"}))
        (app / "Labstream").write_bytes(payload)
        return app

    def test_binary_contract_accepts_audit_markers_without_debug_contracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(pathlib.Path(temporary), b"perf.span phase= home.load")
            contract.check_binary(app)

    def test_binary_contract_rejects_each_forbidden_contract_category(self):
        for category, markers in contract.FORBIDDEN_BINARY_MARKERS.items():
            with self.subTest(category=category), tempfile.TemporaryDirectory() as temporary:
                payload = b"perf.span phase= home.load " + markers[0]
                app = self.make_app(pathlib.Path(temporary), payload)
                with self.assertRaisesRegex(contract.ContractError, category):
                    contract.check_binary(app)

    def test_all_shared_app_profile_actions_use_audit_without_debug_launch_inheritance(self):
        project = SCRIPT.parents[1] / "Labstream.xcodeproj"
        contract.check_profile_schemes(project)

    def test_schema_is_versioned_and_closed(self):
        schema = json.loads((SCRIPT.parent / "schemas" / "performance-audit-manifest-v1.schema.json").read_text())
        self.assertEqual(schema["properties"]["schema_version"]["const"], 1)
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["$defs"]["product"]["properties"]["configuration"]["const"],
                         "PerformanceAudit")


if __name__ == "__main__":
    unittest.main()
