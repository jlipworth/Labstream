import os
import re
import shutil
import subprocess
import sys
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


CFG_KEYWORDS = set("""CONSTANT CONSTANTS INIT NEXT SPECIFICATION INVARIANT INVARIANTS PROPERTY PROPERTIES
    SYMMETRY CONSTRAINT CONSTRAINTS ACTION_CONSTRAINT ACTION_CONSTRAINTS VIEW CHECK_DEADLOCK POSTCONDITION
    ALIAS""".split())


def cfg_properties(config: Path) -> list[str]:
    """The names a config lists under PROPERTY / PROPERTIES."""
    names, inside = [], False
    for line in config.read_text(encoding="utf-8").splitlines():
        words = line.split("\\*", 1)[0].split()
        if words and words[0] in CFG_KEYWORDS:
            inside = words[0] in {"PROPERTY", "PROPERTIES"}
            words = words[1:]
        if inside:
            names += words
    return names


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

    FAKE_JAVA = r"""#!/bin/sh
# Stands in for java: records each call, passes SANY, and plays TLC from the config it is given.
# Directives are comment lines in the config (the runner's config copies keep them):
#   \* FAKE-OUT: <line>      print this line instead of the default liveness violation
#   \* FAKE-EXIT: <status>   exit status (default 13)
#   \* FAKE-FINISH: no       leave out the state count and the "Finished in" line
#   \* FAKE-VIOLATES: A B    a liveness violation when the PROPERTY list names A or B, else a pass
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_JAVA_LOG"
case "$*" in *tlc2.TLC*) ;; *) exit 0 ;; esac
config=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-config" ]; then config="$argument"; fi
  previous="$argument"
done
cp "$config" "$FAKE_JAVA_LOG.$(basename "$config")"
directive() { sed -n "s/^\\\\\* *$1: *//p" "$config"; }
status="$(directive FAKE-EXIT)"
violates="$(directive FAKE-VIOLATES)"
if [ -n "$(directive FAKE-OUT)" ]; then
  directive FAKE-OUT
elif [ -n "$violates" ]; then
  status=0
  for name in $violates; do
    if grep -v '^\\\*' "$config" | grep -Eq "(^| )$name( |\$)"; then status=13; fi
  done
  if [ "$status" = 13 ]; then echo "Error: Temporal properties were violated."
  else echo "Model checking completed. No error has been found."; fi
else
  echo "Error: Temporal properties were violated."
fi
if [ "$(directive FAKE-FINISH)" != no ]; then
  echo "10 states generated, 7 distinct states found, 0 states left on queue."
  echo "Finished in 00s at (2026-01-01 00:00:00)"
fi
exit "${status:-13}"
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
        jar.parent.mkdir(exist_ok=True)
        jar.write_bytes(b"")
        log = self.root / "java.log"
        log.unlink(missing_ok=True)
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

    # --- A result needs the exit status, the banner and a clean finish to agree (R3 item 4) ---

    def outcome(self, name: str, text: str) -> subprocess.CompletedProcess:
        result, _ = self.fake_run(str(self.write(f"alpha/{name}.cfg", "\\* SPEC: Alpha\n" + text)))
        return result

    def assert_failed(self, result: subprocess.CompletedProcess, why: str):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL  tlc", result.stdout)
        self.assertIn(why, result.stdout)
        self.assertNotIn("all checks passed", result.stdout)

    def test_a_crash_after_the_expected_banner_is_a_failure(self):
        # The reviewer's scenario: the expected banner, then an out-of-memory kill.
        result = self.outcome("Finding-Crash", "\\* EXPECT: violation TEMPORAL\nPROPERTY Settles\n"
                              "\\* FAKE-OUT: Error: Temporal properties were violated.\n"
                              "\\* FAKE-OUT: java.lang.OutOfMemoryError: Java heap space\n"
                              "\\* FAKE-EXIT: 137\n\\* FAKE-FINISH: no\n")
        self.assert_failed(result, "got: TLC crashed (exit 137): java.lang.OutOfMemoryError")

    def test_a_crash_is_a_failure_even_with_a_violation_exit_status(self):
        result = self.outcome("Finding-Crash", "\\* EXPECT: violation Safe\nINVARIANT Safe\n"
                              "\\* FAKE-OUT: Error: Invariant Safe is violated.\n"
                              "\\* FAKE-OUT: Exception in thread \"main\" java.lang.StackOverflowError\n"
                              "\\* FAKE-EXIT: 12\n")
        self.assert_failed(result, "got: TLC crashed (exit 12)")

    def test_a_truncated_run_is_a_failure(self):
        result = self.outcome("Finding-Cut", "\\* EXPECT: violation TEMPORAL\nPROPERTY Settles\n"
                              "\\* FAKE-EXIT: 13\n\\* FAKE-FINISH: no\n")
        self.assert_failed(result, "got: TLC did not finish (exit 13)")

    def test_an_abnormal_exit_status_is_a_failure(self):
        for status in ("255", "1", "75", "150", "0"):
            result = self.outcome("Finding-Odd", "\\* EXPECT: violation TEMPORAL\nPROPERTY Settles\n"
                                  f"\\* FAKE-EXIT: {status}\n")
            self.assert_failed(result, "got: TLC ex")

    def test_the_exit_status_must_match_the_kind_of_banner(self):
        result = self.outcome("Finding-Kind", "\\* EXPECT: violation Safe\nINVARIANT Safe\n"
                              "\\* FAKE-OUT: Error: Invariant Safe is violated.\n\\* FAKE-EXIT: 11\n")
        self.assert_failed(result, "TLC exit 11 does not match its banner (Safe)")

    def test_an_evaluation_error_beside_the_banner_is_a_failure(self):
        result = self.outcome("Finding-Eval", "\\* EXPECT: violation Safe\nINVARIANT Safe\n"
                              "\\* FAKE-OUT: Error: Invariant Safe is violated.\n"
                              "\\* FAKE-OUT: Error: Evaluating invariant Safe failed.\n\\* FAKE-EXIT: 12\n")
        self.assert_failed(result, "TLC reported an error (exit 12): Evaluating invariant Safe failed.")

    def test_two_violation_banners_are_a_failure(self):
        result = self.outcome("Finding-Two", "\\* EXPECT: violation Safe\nINVARIANT Safe\n"
                              "\\* FAKE-OUT: Error: Invariant Safe is violated.\n"
                              "\\* FAKE-OUT: Error: Invariant Other is violated.\n\\* FAKE-EXIT: 12\n")
        self.assert_failed(result, "TLC exit 12 with 2 violation banners")

    def test_named_safety_violations_and_deadlock(self):
        cases = [("Invariant Safe is violated.", "12", "Safe"), ("Action property Safe is violated.", "13", "Safe"),
                 ("Deadlock reached.", "11", "DEADLOCK")]
        for banner, status, name in cases:
            text = f"\\* FAKE-OUT: Error: {banner}\n\\* FAKE-EXIT: {status}\n"
            result = self.outcome("Finding-Named", f"\\* EXPECT: violation {name}\n" + text)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"got: {name};", result.stdout)
            result = self.outcome("Finding-Named", "\\* EXPECT: violation Different\n" + text)
            self.assert_failed(result, f"got: {name};")

    # --- The outcome kind and the property are compared separately (review of PR #505) ---

    def test_a_crash_never_matches_an_expectation_spelled_broken(self):
        # The reviewer's scenario: a simulated JVM out-of-memory kill, exit 137, used to satisfy
        # `EXPECT: violation BROKEN` because a broken run's RESULT was the word BROKEN.
        crash = ("INVARIANT Safe\n\\* FAKE-OUT: java.lang.OutOfMemoryError: Java heap space\n"
                 "\\* FAKE-EXIT: 137\n\\* FAKE-FINISH: no\n")
        for word in ("BROKEN", "broken"):
            result = self.outcome("Finding-Reserved", f"\\* EXPECT: violation {word}\n" + crash)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn(f"EXPECT names the reserved word {word} as a property", result.stderr)
            self.assertNotIn("all checks passed", result.stdout)

    def test_a_clean_run_never_matches_an_expectation_spelled_pass(self):
        # `EXPECT: violation pass` used to accept a run that found no violation at all.
        clean = "INVARIANT Safe\n\\* FAKE-OUT: Model checking completed. No error has been found.\n\\* FAKE-EXIT: 0\n"
        for word in ("pass", "PASS", "violation"):
            result = self.outcome("Finding-Reserved", f"\\* EXPECT: violation {word}\n" + clean)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn(f"EXPECT names the reserved word {word} as a property", result.stderr)
            self.assertNotIn("all checks passed", result.stdout)

    def test_a_named_temporal_property_may_not_be_a_reserved_word(self):
        result = self.outcome("Finding-Reserved", "\\* EXPECT: violation TEMPORAL BROKEN\nPROPERTY BROKEN\n")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("EXPECT names the reserved word BROKEN as a property", result.stderr)

    def test_a_property_named_like_an_outcome_is_compared_by_kind(self):
        # `Broken` is an ordinary TLA+ name. A crash is still not its violation, and its real
        # violation is accepted.
        crash = ("INVARIANT Broken\n\\* FAKE-OUT: java.lang.OutOfMemoryError: Java heap space\n"
                 "\\* FAKE-EXIT: 137\n\\* FAKE-FINISH: no\n")
        self.assert_failed(self.outcome("Finding-Kind", "\\* EXPECT: violation Broken\n" + crash),
                           "got: TLC crashed (exit 137)")
        violated = "INVARIANT Broken\n\\* FAKE-OUT: Error: Invariant Broken is violated.\n\\* FAKE-EXIT: 12\n"
        result = self.outcome("Finding-Kind", "\\* EXPECT: violation Broken\n" + violated)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("got: Broken;", result.stdout)

    def test_a_crash_never_passes_a_pass_expectation(self):
        crash = ("INVARIANT Safe\n\\* FAKE-OUT: java.lang.OutOfMemoryError: Java heap space\n"
                 "\\* FAKE-EXIT: 137\n\\* FAKE-FINISH: no\n")
        self.assert_failed(self.outcome("Current-Crash", "\\* EXPECT: pass\n" + crash),
                           "got: TLC crashed (exit 137)")

    def test_a_pass_needs_status_zero_the_banner_and_a_finish(self):
        good = "\\* EXPECT: pass\n\\* FAKE-OUT: Model checking completed. No error has been found.\n"
        result = self.outcome("Current-Good", good + "\\* FAKE-EXIT: 0\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("all checks passed", result.stdout)
        self.assert_failed(self.outcome("Current-Bad", good + "\\* FAKE-EXIT: 1\n"), "got: TLC exit 1")
        self.assert_failed(self.outcome("Current-Bad", good + "\\* FAKE-EXIT: 0\n\\* FAKE-FINISH: no\n"),
                           "TLC did not finish")
        self.assert_failed(self.outcome("Current-Bad", "\\* EXPECT: pass\n\\* FAKE-OUT: Starting...\n"
                                        "\\* FAKE-EXIT: 0\n"), "TLC exited 0 without a clean")
        self.assert_failed(self.outcome("Current-Bad", good + "\\* FAKE-EXIT: 0\n"
                                        "\\* FAKE-OUT: java.lang.OutOfMemoryError: Java heap space\n"),
                           "TLC crashed (exit 0)")

    # --- Several temporal properties: the expectation names one, and each side is checked ---

    TWO = "SPECIFICATION FairSpec\nINVARIANT TypeOK\nPROPERTIES\n    Settles \\* liveness\n    Served\nCONSTANTS\n    Rows = {r1}\n"

    def split_run(self, expect: str, violates: str):
        cfg = self.write("alpha/Finding-Two.cfg",
                         f"\\* SPEC: Alpha\n\\* EXPECT: {expect}\n\\* FAKE-VIOLATES: {violates}\n" + self.TWO)
        result, calls = self.fake_run(str(cfg))
        return result, [call for call in calls if "tlc2.TLC" in call]

    def test_an_unnamed_temporal_expectation_over_several_properties_fails(self):
        result, tlc = self.split_run("violation TEMPORAL", "Settles")
        self.assert_failed(result, "not run: the config checks several properties (Settles, Served)")
        self.assertIn("EXPECT: violation TEMPORAL <Property>", result.stdout)
        self.assertEqual(tlc, [])

    def test_a_named_temporal_property_is_checked_alone_and_the_others_must_hold(self):
        result, tlc = self.split_run("violation TEMPORAL Settles", "Settles")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[expect: violation TEMPORAL Settles; got: TEMPORAL (Settles); the others hold (Served);",
                      result.stdout)
        self.assertEqual(len(tlc), 2)
        self.assertRegex(tlc[0], r"-config /\S+/only-Settles\.cfg Alpha\.tla$")
        self.assertRegex(tlc[1], r"-config /\S+/without-Settles\.cfg Alpha\.tla$")
        only = (self.root / "java.log.only-Settles.cfg").read_text(encoding="utf-8")
        rest = (self.root / "java.log.without-Settles.cfg").read_text(encoding="utf-8")
        self.assertIn("PROPERTY Settles\n", only)
        self.assertNotIn("Served", only)
        self.assertIn("PROPERTY Served\n", rest)
        self.assertNotIn("    Settles", rest)
        for text in (only, rest):
            self.assertIn("INVARIANT TypeOK\n", text)
            self.assertIn("CONSTANTS\n    Rows = {r1}\n", text)
            self.assertIn("SPECIFICATION FairSpec\n", text)

    def test_naming_the_property_that_holds_fails(self):
        result, tlc = self.split_run("violation TEMPORAL Served", "Settles")
        self.assert_failed(result, "[expect: violation TEMPORAL Served; got: no violation;")
        self.assertEqual(len(tlc), 1)

    def test_a_second_violated_property_fails(self):
        result, _ = self.split_run("violation TEMPORAL Settles", "Settles Served")
        self.assert_failed(result, "got: TEMPORAL (Settles); also violated among the others (Served): TEMPORAL;")

    def test_a_crash_while_checking_the_other_properties_fails(self):
        cfg = self.write("alpha/Finding-Two.cfg", "\\* SPEC: Alpha\n\\* EXPECT: violation TEMPORAL Settles\n"
                         "\\* FAKE-FINISH: no\n\\* FAKE-VIOLATES: Settles\n" + self.TWO)
        result, _ = self.fake_run(str(cfg))
        self.assert_failed(result, "TLC did not finish")

    def test_naming_a_property_the_config_does_not_check_is_an_error(self):
        result, tlc = self.split_run("violation TEMPORAL Missing", "Settles")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("not in the config's PROPERTY list", result.stderr)
        self.assertEqual(tlc, [])

    def test_a_named_single_property_runs_the_config_once(self):
        cfg = self.write("alpha/Finding-One.cfg", "\\* SPEC: Alpha\n\\* EXPECT: violation TEMPORAL Settles\n"
                         "PROPERTY Settles\n")
        result, calls = self.fake_run(str(cfg))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        tlc = [call for call in calls if "tlc2.TLC" in call]
        self.assertEqual(len(tlc), 1)
        self.assertTrue(tlc[0].endswith("-config Finding-One.cfg Alpha.tla"), tlc[0])

    def test_a_temporal_violation_fails_a_config_that_expects_a_pass(self):
        result, _ = self.fake_run(str(self.area / "beta" / "Current-One.cfg"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL  tlc", result.stdout)


def real_java() -> str | None:
    """A JDK the runner would use, when the pinned jar is already cached. Never downloads."""
    if not list((REPO / "build" / "tla").glob("tla2tools-*.jar")):
        return None
    candidates = [os.environ.get("JAVA")]
    brew = shutil.which("brew")
    if brew:
        prefix = subprocess.run([brew, "--prefix", "openjdk"], capture_output=True, text=True).stdout.strip()
        candidates.append(f"{prefix}/bin/java" if prefix else None)
    if sys.platform != "darwin":
        candidates.append(shutil.which("java"))
    for candidate in candidates:
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


@unittest.skipUnless(real_java(), "needs a JDK and the cached tla2tools.jar (run check-tla-specs.sh once)")
class RealTlcOutcomeTests(unittest.TestCase):
    """The runner against the real TLC: its exit statuses and banners, and the property split."""

    MODULE = """---- MODULE Tiny ----
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = (x + 1) % 3
Spec == Init /\\ [][Next]_x /\\ WF_x(Next)
Small == x < 2
Grows == [][x' > x]_x
StaysOne == <>[](x = 1)
StaysTwo == <>[](x = 2)
ReachesTwo == []<>(x = 2)
Step == x = 0 /\\ x' = 1
Halts == Init /\\ [][Step]_x
Broken == x + "one" = 2
====
"""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        (self.root / "Tiny.tla").write_text(self.MODULE, encoding="utf-8")

    def check(self, expect: str, body: str) -> subprocess.CompletedProcess:
        cfg = self.root / "Case.cfg"
        cfg.write_text(f"\\* SPEC: Tiny\n\\* EXPECT: {expect}\n{body}", encoding="utf-8")
        clean = {key: value for key, value in os.environ.items() if not key.startswith("TLC_")}
        return subprocess.run(["bash", str(SCRIPT), str(cfg)], capture_output=True, text=True,
                              env={**clean, "JAVA": real_java(), "TLC_WORKERS": "1", "TLC_HEAP": "512m"})

    def assert_ok(self, expect: str, body: str, got: str):
        result = self.check(expect, body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"got: {got};", result.stdout)

    def assert_failed(self, expect: str, body: str, got: str):
        result = self.check(expect, body)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"got: {got}", result.stdout)
        self.assertNotIn("all checks passed", result.stdout)

    def test_each_kind_of_result_is_recognised(self):
        self.assert_ok("pass", "SPECIFICATION Spec\nPROPERTY ReachesTwo\n", "no violation")
        self.assert_ok("violation Small", "SPECIFICATION Spec\nINVARIANT Small\n", "Small")
        self.assert_ok("violation Grows", "SPECIFICATION Spec\nPROPERTY Grows\n", "Grows")
        self.assert_ok("violation DEADLOCK", "SPECIFICATION Halts\n", "DEADLOCK")
        self.assert_ok("violation TEMPORAL", "SPECIFICATION Spec\nPROPERTY StaysOne\n", "TEMPORAL (StaysOne)")

    def test_a_different_result_fails(self):
        self.assert_failed("violation Small", "SPECIFICATION Spec\nPROPERTY ReachesTwo\n", "no violation;")
        self.assert_failed("violation TEMPORAL", "SPECIFICATION Spec\nINVARIANT Small\n", "Small;")
        self.assert_failed("pass", "SPECIFICATION Spec\nPROPERTY StaysOne\n", "TEMPORAL (StaysOne);")

    def test_tlc_errors_are_never_the_expected_violation(self):
        # An invariant TLC cannot evaluate, and a property the module does not define.
        self.assert_failed("violation Broken", "SPECIFICATION Spec\nINVARIANT Broken\n", "TLC ")
        self.assert_failed("violation TEMPORAL", "SPECIFICATION Spec\nPROPERTY Missing\n", "TLC ")

    def test_several_temporal_properties_are_told_apart(self):
        two = "SPECIFICATION Spec\nPROPERTIES\n    StaysOne\n    ReachesTwo\n"
        self.assert_ok("violation TEMPORAL StaysOne", two, "TEMPORAL (StaysOne); the others hold (ReachesTwo)")
        self.assert_failed("violation TEMPORAL ReachesTwo", two, "no violation;")
        unnamed = self.check("violation TEMPORAL", two)
        self.assertEqual(unnamed.returncode, 1, unnamed.stdout)
        self.assertIn("not run: the config checks several properties (StaysOne, ReachesTwo)", unnamed.stdout)
        both = "SPECIFICATION Spec\nPROPERTY StaysOne StaysTwo ReachesTwo\n"
        self.assert_failed("violation TEMPORAL StaysOne", both,
                           "TEMPORAL (StaysOne); also violated among the others (StaysTwo, ReachesTwo): TEMPORAL;")


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
            self.assertRegex(expect, r"^(pass|violation [A-Za-z0-9_]+|violation TEMPORAL [A-Za-z0-9_]+)$",
                             config.name)
            self.assertIn(header(config, "TIER") or "default", {"default", "deep"}, config.name)

    def test_a_temporal_expectation_over_several_properties_names_one(self):
        # TLC does not name the liveness property that failed, so the config must (the runner
        # then checks that property alone and the others without it).
        for config in self.configs():
            expect = header(config, "EXPECT")
            if not expect.startswith("violation TEMPORAL"):
                continue
            properties = cfg_properties(config)
            named = expect.removeprefix("violation TEMPORAL").strip()
            where = str(config.relative_to(SPECS))
            if named:
                self.assertIn(named, properties, where)
            else:
                self.assertLessEqual(len(properties), 1, f"{where}: write `EXPECT: violation TEMPORAL "
                                     f"<Property>`; the config checks {', '.join(properties)}")

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
            # A helper module's configs carry its name without the area prefix:
            # downloads/wake/WakeLaunchGate-Current-Gate.cfg, playback/base/BaseSmoke-Current-Smoke.cfg.
            area = config.relative_to(SPECS).parts[0].capitalize()
            self.assertEqual(f"{area}{first}", header(config, "SPEC"), config.relative_to(SPECS))
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
        # The range starts at the pull request's own target branch, read at run time.
        self.assertIn('TARGET="$${CI_COMMIT_TARGET_BRANCH:?', pipeline)
        self.assertIn('scripts/check-tla-drift.py "origin/$$TARGET...HEAD"', pipeline)
        self.assertIn('--unshallow origin "+refs/heads/$$TARGET:refs/remotes/origin/$$TARGET"', pipeline)
        commands = [line for line in pipeline.splitlines() if line.lstrip().startswith("- ")]
        self.assertFalse([line for line in commands if "main" in line], "no command may hard-code main")

    def test_woodpecker_pipelines_have_no_unescaped_dollar_signs(self):
        """Woodpecker substitutes variables over the whole file, comments included, before it
        parses the YAML. A lone `$` is replaced by the server (usually with nothing) or, as a
        `${...}` in a comment once did, fails the whole pipeline with "unable to parse variable
        name", so no check reports at all. Shell dollars must be written `$$`."""
        for name in ("tla.yml", "tla-drift.yml"):
            text = (REPO / ".woodpecker" / name).read_text(encoding="utf-8")
            lone = [line for line in text.splitlines() if "$" in line.replace("$$", "")]
            self.assertEqual(lone, [], f".woodpecker/{name} has an unescaped $")

    def test_the_drift_step_compares_against_the_target_branch(self):
        """Run the pipeline's own commands against a PR that targets a release branch."""
        pipeline = (REPO / ".woodpecker" / "tla-drift.yml").read_text(encoding="utf-8")
        commands = [line.strip()[2:] for line in pipeline.split("commands:", 1)[1].splitlines()
                    if line.strip().startswith("- ")]
        # Woodpecker's pre-processing turns every `$$` into `$`; the image setup needs no test.
        steps = [command.replace("$$", "$").replace("python scripts/", f"{sys.executable} {REPO}/scripts/")
                 .replace("check-tla-drift.py ", "check-tla-drift.py --repo . ")
                 for command in commands if not command.startswith(("apt-get", "rm -rf /var/lib/apt"))]
        self.assertEqual(len(steps), 4, steps)
        with tempfile.TemporaryDirectory() as tmp:
            origin, clone = Path(tmp) / "origin", Path(tmp) / "clone"

            def git(*args):
                subprocess.run(["git", *args], cwd=origin, check=True, capture_output=True, text=True)

            def write(relative, text):
                path = origin / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")

            def commit(message):
                git("add", "-A")
                git("-c", "user.email=test@example.invalid", "-c", "user.name=Tooling Test",
                    "-c", "commit.gpgsign=false", "commit", "-q", "-m", message)

            origin.mkdir()
            git("init", "-q", "--initial-branch=main")
            write("Sources/Session.swift", "// session\n")
            write("specs/area/core/Core.tla", "---- MODULE Core ----\n\\* MODELS: Sources/Session.swift\n====\n")
            commit("baseline")
            # The release branch already holds a spec edit that main does not have.
            git("checkout", "-q", "-b", "release")
            write("specs/area/core/Core.tla",
                  "---- MODULE Core ----\n\\* MODELS: Sources/Session.swift\n\\* updated\n====\n")
            commit("release: update the spec")
            git("checkout", "-q", "-b", "pr", "release")
            write("Sources/Session.swift", "// session\n// pr\n")
            commit("pr: change the session, no spec, no trailer")
            subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", "pr", origin.as_uri(), str(clone)],
                           check=True, capture_output=True)

            def run(**env):
                clean = {key: value for key, value in os.environ.items() if key != "CI_COMMIT_TARGET_BRANCH"}
                return subprocess.run(["sh", "-ec", "\n".join(steps)], cwd=clone, capture_output=True,
                                      text=True, env={**clean, **env})

            unset = run()
            self.assertNotEqual(unset.returncode, 0, unset.stdout)
            self.assertIn("no target branch", unset.stderr)
            self.assertNotEqual(run(CI_COMMIT_TARGET_BRANCH="bad..name").returncode, 0)
            release = run(CI_COMMIT_TARGET_BRANCH="release")
            self.assertEqual(release.returncode, 1, release.stdout + release.stderr)
            self.assertIn("Sources/Session.swift changed, but its spec did not", release.stdout)
            self.assertIn("in origin/release...HEAD", release.stderr)
            # Measured from main, as the pipeline used to, the same pull request passes: the
            # release branch's earlier spec edit lands in the range and covers the PR's change.
            main = run(CI_COMMIT_TARGET_BRANCH="main")
            self.assertEqual(main.returncode, 0, main.stdout + main.stderr)


if __name__ == "__main__":
    unittest.main()
