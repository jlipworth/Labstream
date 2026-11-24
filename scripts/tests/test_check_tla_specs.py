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


class TlaSpecLayoutTests(unittest.TestCase):
    """specs/<area>/<module>/ folders with shared modules in <area>/base/. No JDK needed."""

    FAKE_JAVA = """#!/bin/sh
# Stands in for java: records each call, passes SANY, and prints a TLC liveness violation.
printf '%s|%s\\n' "$PWD" "$*" >> "$FAKE_JAVA_LOG"
case "$*" in
  *tlc2.TLC*)
    echo "Error: Temporal properties were violated."
    echo "10 states generated, 7 distinct states found, 0 states left on queue."
    exit 13 ;;
esac
exit 0
"""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.area = self.root / "specs" / "area"
        self.write("base/Shared.tla", "---- MODULE Shared ----\n====\n")
        self.write("base/Shared-Check.cfg", "\\* SPEC: Shared\n\\* EXPECT: pass\n")
        self.write("alpha/Alpha.tla", "---- MODULE Alpha ----\nEXTENDS Shared\n====\n")
        self.write("alpha/AlphaHelper.tla", "---- MODULE AlphaHelper ----\n====\n")
        self.write("alpha/Current-One.cfg", "\\* SPEC: Alpha\n\\* EXPECT: pass\n")
        self.write("alpha/Deep-One.cfg", "\\* SPEC: Alpha\n\\* EXPECT: pass\n\\* TIER: deep\n")
        self.write("alpha/AlphaHelper-Current-One.cfg", "\\* SPEC: AlphaHelper\n\\* EXPECT: pass\n")
        self.write("alpha/Projection-Alpha.cfg", "\\* SPEC: Shared\n\\* EXPECT: pass\n")
        self.write("beta/Beta.tla", "---- MODULE Beta ----\n====\n")
        self.write("beta/Current-One.cfg", "\\* SPEC: Beta\n\\* EXPECT: pass\n")

    def write(self, relative: str, text: str) -> Path:
        path = self.area / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_script(self, *args: str, cwd: Path | None = None, **env: str) -> subprocess.CompletedProcess:
        clean = {key: value for key, value in os.environ.items() if not key.startswith("TLC_")}
        return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True,
                              cwd=cwd, env={**clean, **env})

    def listed(self, *args: str, cwd: Path | None = None) -> list[str]:
        result = self.run_script("--list", *args, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [Path(line).relative_to(self.area).as_posix() for line in result.stdout.splitlines()]

    def test_a_directory_is_searched_recursively(self):
        self.assertEqual(sorted(self.listed(str(self.root / "specs"))), [
            "alpha/AlphaHelper-Current-One.cfg", "alpha/Current-One.cfg", "alpha/Projection-Alpha.cfg",
            "base/Shared-Check.cfg", "beta/Current-One.cfg"])

    def test_a_module_folder_selects_only_its_configs(self):
        self.assertEqual(self.listed(str(self.area / "beta")), ["beta/Current-One.cfg"])
        self.assertEqual(self.listed("--deep-only", str(self.area / "alpha")), ["alpha/Deep-One.cfg"])

    def test_a_relative_path_works(self):
        self.assertEqual(self.listed("area/beta", cwd=self.root / "specs"), ["beta/Current-One.cfg"])
        self.assertEqual(self.listed("Current-One.cfg", cwd=self.area / "alpha"), ["alpha/Current-One.cfg"])

    def test_same_named_configs_in_two_folders_both_run(self):
        self.assertEqual(self.listed(str(self.area / "alpha" / "Current-One.cfg"),
                                     str(self.area / "beta" / "Current-One.cfg")),
                         ["alpha/Current-One.cfg", "beta/Current-One.cfg"])

    def test_naming_a_module_selects_the_configs_that_declare_it(self):
        self.assertEqual(self.listed(str(self.area / "alpha" / "Alpha.tla")), ["alpha/Current-One.cfg"])
        self.assertEqual(self.listed(str(self.area / "alpha" / "AlphaHelper.tla")),
                         ["alpha/AlphaHelper-Current-One.cfg"])

    def test_naming_a_shared_module_finds_its_configs_in_every_folder(self):
        self.assertEqual(self.listed(str(self.area / "base" / "Shared.tla")),
                         ["alpha/Projection-Alpha.cfg", "base/Shared-Check.cfg"])

    def test_a_missing_path_is_an_error(self):
        result = self.run_script("--list", str(self.area / "gamma"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("no such spec, config or directory", result.stderr)

    def fake_run(self, *args: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        fake = self.root / "java"
        fake.write_text(self.FAKE_JAVA, encoding="utf-8")
        fake.chmod(0o755)
        jar = self.root / "cache" / "tla2tools-v1.7.4.jar"
        jar.parent.mkdir()
        jar.write_bytes(b"")
        log = self.root / "java.log"
        # An empty file's SHA-256 never matches the pin, so stop the download instead.
        script = self.root / "check.sh"
        script.write_text(SCRIPT.read_text(encoding="utf-8").replace(
            'if [[ -f "$JAR" && "$(sha256_of "$JAR")" == "$TLA_JAR_SHA256" ]]; then',
            'if [[ -f "$JAR" ]]; then'), encoding="utf-8")
        clean = {key: value for key, value in os.environ.items() if not key.startswith("TLC_")}
        result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True,
                                env={**clean, "JAVA": str(fake), "FAKE_JAVA_LOG": str(log),
                                     "TLA_CACHE_DIR": str(jar.parent)})
        return result, log.read_text(encoding="utf-8").splitlines()

    def test_runs_use_the_folder_and_the_shared_library_path(self):
        _, calls = self.fake_run(str(self.area / "alpha" / "Projection-Alpha.cfg"))
        base = self.area / "base"
        sany = [call for call in calls if "tla2sany.SANY" in call]
        self.assertEqual(len(sany), 1)
        self.assertTrue(sany[0].startswith(f"{base}|"), sany[0])
        self.assertNotIn("TLA-Library", sany[0])
        tlc = [call for call in calls if "tlc2.TLC" in call]
        self.assertEqual(len(tlc), 1)
        self.assertTrue(tlc[0].startswith(f"{self.area / 'alpha'}|"), tlc[0])
        self.assertIn(f"-DTLA-Library={base}", tlc[0])
        self.assertTrue(tlc[0].endswith("-config Projection-Alpha.cfg Shared.tla"), tlc[0])

    def test_a_module_folder_parses_with_the_shared_library_path(self):
        _, calls = self.fake_run(str(self.area / "alpha" / "Current-One.cfg"))
        sany = [call for call in calls if "tla2sany.SANY" in call]
        self.assertEqual(len(sany), 1)
        self.assertIn(f"-DTLA-Library={self.area / 'base'}", sany[0])
        self.assertTrue(sany[0].endswith("Alpha.tla"), sany[0])

    def test_a_temporal_violation_names_the_single_property(self):
        cfg = self.write("alpha/Finding-One.cfg",
                         "\\* SPEC: Alpha\n\\* EXPECT: violation TEMPORAL\nSPECIFICATION FairSpec\n"
                         "INVARIANT TypeOK\nPROPERTY Settles \\* the liveness property\nCHECK_DEADLOCK FALSE\n")
        result, _ = self.fake_run(str(cfg))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[expect: violation TEMPORAL; got: TEMPORAL (Settles); 7 distinct;", result.stdout)

    def test_a_temporal_violation_lists_several_candidates(self):
        cfg = self.write("alpha/Finding-Two.cfg",
                         "\\* SPEC: Alpha\n\\* EXPECT: violation TEMPORAL\nSPECIFICATION FairSpec\n"
                         "PROPERTIES\n    Settles\n    Served\nCONSTANTS\n    Rows = {r1}\n")
        result, _ = self.fake_run(str(cfg))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("got: TEMPORAL (one of: Settles, Served);", result.stdout)

    def test_a_temporal_violation_fails_a_config_that_expects_a_pass(self):
        result, _ = self.fake_run(str(self.area / "beta" / "Current-One.cfg"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL  tlc", result.stdout)


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
            # The module sits beside the config, or is shared from the area's base folder.
            homes = [config.parent, config.parent.parent / "base"]
            self.assertTrue(any((home / f"{spec}.tla").is_file() for home in homes),
                            f"{config.relative_to(SPECS)}: no {spec}.tla")
            expect = header(config, "EXPECT")
            self.assertIsNotNone(expect, f"{config.name}: no `\\* EXPECT:` header")
            self.assertRegex(expect, r"^(pass|violation [A-Za-z0-9_]+)$", config.name)
            self.assertIn(header(config, "TIER") or "default", {"default", "deep"}, config.name)

    def test_layout_is_one_folder_per_module(self):
        loose = [path.name for path in (SPECS / "downloads").iterdir() if path.is_file()]
        self.assertEqual(loose, [], "specs/downloads/ holds module folders only")
        for folder in sorted(path for path in (SPECS / "downloads").iterdir() if path.is_dir()):
            self.assertTrue(list(folder.glob("*.tla")), f"{folder.name}: no module")
            self.assertTrue(list(folder.glob("*.cfg")), f"{folder.name}: no config")

    def test_a_config_name_starts_with_its_kind_or_a_helper_module(self):
        kinds = {"Current", "Liveness", "Faithful", "Mutant", "Finding", "Proposed", "Deep", "Projection"}
        for config in self.configs():
            first = config.stem.split("-")[0]
            if first in kinds or config.name == "Reducer-Conformance.cfg":
                continue
            # A helper module's configs carry its name: wake/WakeLaunchGate-Current-Gate.cfg.
            self.assertEqual(f"Downloads{first}", header(config, "SPEC"), config.relative_to(SPECS))
            self.assertIn(config.stem.split("-")[1], kinds, config.relative_to(SPECS))

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
