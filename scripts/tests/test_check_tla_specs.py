import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-tla-specs.sh"
SPECS = REPO / "specs"


def header(config: Path, key: str) -> str | None:
    for line in config.read_text(encoding="utf-8").splitlines():
        match = re.match(rf"^\\\*\s*{key}:\s*(.*\S)\s*$", line)
        if match:
            return match.group(1)
    return None


class TlaSpecRunnerTests(unittest.TestCase):
    """Config selection and the no-Java failure. Neither needs a JDK."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "Model.tla").write_text("---- MODULE Model ----\n====\n", encoding="utf-8")
        self.config("Small", "\\* SPEC: Model\n\\* EXPECT: pass\n")
        self.config("Deep-Large", "\\* SPEC: Model\n\\* EXPECT: pass\n\\* TIER: deep\n")

    def config(self, name: str, text: str) -> Path:
        path = self.root / f"{name}.cfg"
        path.write_text(text + "SPECIFICATION Spec\n", encoding="utf-8")
        return path

    def run_script(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        clean = {key: value for key, value in os.environ.items() if not key.startswith("TLC_")}
        return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True,
                              env={**clean, **env})

    def listed(self, *args: str, **env: str) -> list[str]:
        result = self.run_script("--list", *args, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [Path(line).name for line in result.stdout.splitlines()]

    def test_deep_configs_are_skipped_by_default(self):
        self.assertEqual(self.listed(str(self.root)), ["Small.cfg"])

    def test_deep_flag_and_environment_include_them(self):
        both = ["Deep-Large.cfg", "Small.cfg"]
        self.assertEqual(self.listed("--deep", str(self.root)), both)
        self.assertEqual(self.listed(str(self.root), TLC_TIER="deep"), both)

    def test_deep_only_selects_just_the_deep_configs(self):
        self.assertEqual(self.listed("--deep-only", str(self.root)), ["Deep-Large.cfg"])
        self.assertEqual(self.listed(str(self.root), TLC_TIER="deep-only"), ["Deep-Large.cfg"])

    def test_a_named_config_runs_whatever_its_tier(self):
        self.assertEqual(self.listed(str(self.root / "Deep-Large.cfg")), ["Deep-Large.cfg"])

    def test_naming_the_module_applies_the_tier(self):
        self.assertEqual(self.listed(str(self.root / "Model.tla")), ["Small.cfg"])

    def test_unknown_tier_values_are_errors(self):
        self.config("Odd", "\\* SPEC: Model\n\\* TIER: nightly\n")
        result = self.run_script("--list", str(self.root))
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized TIER header: nightly", result.stderr)
        result = self.run_script("--list", str(self.root / "Small.cfg"), TLC_TIER="nightly")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown tier", result.stderr)

    def test_missing_java_fails_with_a_clear_message(self):
        result = self.run_script(str(self.root / "Small.cfg"), JAVA=str(self.root / "no-java"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("TLC needs a JDK", result.stderr)
        self.assertIn("no spec was checked", result.stderr)
        self.assertNotIn("all checks passed", result.stdout)

    def test_a_java_that_does_not_run_fails_the_same_way(self):
        fake = self.root / "java"
        fake.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        fake.chmod(0o755)
        result = self.run_script(str(self.root / "Small.cfg"), JAVA=str(fake))
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not run", result.stderr)
        self.assertNotIn("all checks passed", result.stdout)


class RepositorySpecConventionTests(unittest.TestCase):
    """The conventions DownloadsBase.tla asks every config to follow."""

    def configs(self) -> list[Path]:
        configs = sorted(SPECS.rglob("*.cfg"))
        self.assertTrue(configs)
        return configs

    def test_every_config_declares_a_module_and_an_expectation(self):
        for config in self.configs():
            spec = header(config, "SPEC")
            self.assertIsNotNone(spec, f"{config.name}: no `\\* SPEC:` header")
            self.assertTrue((config.parent / f"{spec}.tla").is_file(), f"{config.name}: no {spec}.tla")
            expect = header(config, "EXPECT")
            self.assertIsNotNone(expect, f"{config.name}: no `\\* EXPECT:` header")
            self.assertRegex(expect, r"^(pass|violation [A-Za-z0-9_]+)$", config.name)
            self.assertIn(header(config, "TIER") or "default", {"default", "deep"}, config.name)

    def test_expectation_matches_the_kind_in_the_name(self):
        for config in self.configs():
            expect = header(config, "EXPECT")
            kinds = set(config.stem.split("-"))
            if kinds & {"Faithful", "Mutant", "Finding"}:
                self.assertTrue(expect.startswith("violation "), config.name)
            elif kinds & {"Current", "Liveness", "Proposed"}:
                self.assertEqual(expect, "pass", config.name)

    def test_liveness_configs_do_not_use_symmetry(self):
        for config in self.configs():
            text = config.read_text(encoding="utf-8")
            if "Liveness" in config.stem or re.search(r"^SPECIFICATION\s+FairSpec", text, re.M):
                self.assertNotRegex(text, r"(?m)^SYMMETRY", f"{config.name}: SYMMETRY is unsound for liveness")

    def test_every_faithful_or_mutant_config_has_a_passing_counterpart_module(self):
        modules = {header(config, "SPEC") for config in self.configs()
                   if set(config.stem.split("-")) & {"Faithful", "Mutant"}}
        passing = {header(config, "SPEC") for config in self.configs() if header(config, "EXPECT") == "pass"}
        self.assertLessEqual(modules, passing)


class TlaPipelineTests(unittest.TestCase):
    def test_macos_pipeline_keeps_the_local_backend_trust_boundary(self):
        result = subprocess.run(
            ["python3", str(REPO / "scripts" / "validate-macos-pipeline.py"),
             str(REPO / ".woodpecker" / "tla.yml"), "--default-branch", "main"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        pipeline = (REPO / ".woodpecker" / "tla.yml").read_text(encoding="utf-8")
        self.assertNotIn("pull_request", pipeline.split("when:", 1)[1])
        self.assertIn("./scripts/check-tla-specs.sh", pipeline)
        self.assertIn("scripts/check-tla-drift.py", pipeline)
        hygiene = (REPO / ".woodpecker" / "hygiene.yml").read_text(encoding="utf-8")
        self.assertIn("validate-macos-pipeline.py .woodpecker/tla.yml", hygiene)

    def test_pull_requests_run_the_drift_guard_without_the_local_backend(self):
        pipeline = (REPO / ".woodpecker" / "tla-drift.yml").read_text(encoding="utf-8")
        self.assertIn("event: pull_request", pipeline)
        self.assertNotIn("backend: local", pipeline)
        self.assertIn("scripts/check-tla-drift.py origin/main...HEAD", pipeline)


if __name__ == "__main__":
    unittest.main()
