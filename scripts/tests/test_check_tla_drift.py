import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path

from _script_loader import load_script

REPO = Path(__file__).resolve().parents[2]
drift = load_script("check_tla_drift", REPO / "scripts" / "check-tla-drift.py")

REDUCER = "Sources/Reducer.swift"
SESSION = "Sources/Session.swift"


class TlaDriftTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Tooling Test")
        self.git("config", "commit.gpgsign", "false")
        self.write(REDUCER, "// reducer\n")
        self.write(SESSION, "// session\n")
        self.write("Sources/Other.swift", "// other\n")
        self.write("specs/downloads/Reducer.tla", self.module("Reducer", REDUCER))
        self.write("specs/downloads/Core.tla", self.module("Core", REDUCER, SESSION))
        self.write("specs/downloads/Current.cfg", "\\* SPEC: Core\n\\* EXPECT: pass\n")
        self.commit("baseline")
        self.git("branch", "base")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, text=True).stdout

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def append(self, relative, text="// changed\n"):
        with (self.root / relative).open("a", encoding="utf-8") as handle:
            handle.write(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    @staticmethod
    def module(name, *models):
        header = "".join(f"\\* MODELS: {path}\n" for path in models)
        # The indented block-comment example must not count as a declaration.
        return (f"---- MODULE {name} ----\n(*   \\* MODELS: Sources/Example.swift   *)\n"
                f"{header}EXTENDS Naturals\n====\n")

    def run_check(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = drift.main(["--repo", str(self.root), *(args or ["base...HEAD"])])
        return status, out.getvalue() + err.getvalue()

    def test_unmodelled_change_passes(self):
        self.append("Sources/Other.swift")
        self.commit("change something else")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_modelled_change_without_spec_fails_and_names_the_commit(self):
        self.append(SESSION)
        self.commit("change the session")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn(f"{SESSION} changed, but its spec did not: specs/downloads/Core.tla", output)
        self.assertIn("change the session", output)
        self.assertIn("Spec-Unaffected", output)

    def test_spec_change_in_the_range_covers_the_file(self):
        self.append(SESSION)
        self.commit("change the session")
        self.append("specs/downloads/Core.tla", "\\* updated\n")
        self.commit("update the spec")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("spec updated", output)

    def test_a_config_of_the_module_counts_as_the_spec(self):
        self.append(SESSION)
        self.append("specs/downloads/Current.cfg", "\\* bound changed\n")
        self.commit("change the session and its config")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_every_owning_module_must_change(self):
        self.append(REDUCER)
        self.append("specs/downloads/Reducer.tla", "\\* updated\n")
        self.commit("change the reducer and one of its two specs")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("specs/downloads/Core.tla", output)
        self.assertNotIn("did not: specs/downloads/Core.tla, specs/downloads/Reducer.tla", output)

    def test_trailer_on_the_touching_commit_covers_the_file(self):
        self.append(SESSION)
        self.commit("reword a comment\n\nSpec-Unaffected: comment-only change")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("declared unaffected (comment-only change)", output)

    def test_trailer_on_another_commit_does_not_cover_the_file(self):
        self.append(SESSION)
        self.commit("change the session")
        self.append("Sources/Other.swift")
        self.commit("unrelated\n\nSpec-Unaffected: nothing modelled changed here")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)

    def test_every_touching_commit_needs_the_trailer(self):
        self.append(SESSION)
        self.commit("first\n\nSpec-Unaffected: comment only")
        self.append(SESSION)
        self.commit("second, a real change")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("second, a real change", output)
        self.assertNotIn("first", output.split("DRIFT", 1)[1].split("check-tla-drift")[0])

    def test_empty_trailer_is_not_a_reason(self):
        self.append(SESSION)
        self.commit("change the session\n\nSpec-Unaffected:")
        status, _ = self.run_check()
        self.assertEqual(status, 1)

    def test_reverted_change_is_not_drift(self):
        self.append(SESSION)
        self.commit("change the session")
        self.write(SESSION, "// session\n")
        self.commit("change it back")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_two_dot_range_and_bare_base(self):
        self.append(SESSION)
        self.commit("change the session")
        self.assertEqual(self.run_check("base..HEAD")[0], 1)
        self.assertEqual(self.run_check("base")[0], 1)
        self.assertEqual(self.run_check("HEAD..HEAD")[0], 0)

    def test_missing_modelled_file_fails(self):
        self.git("rm", "-q", SESSION)
        self.commit("remove the session\n\nSpec-Unaffected: file removed")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn(f"MODELS names a file that does not exist: {SESSION}", output)

    def test_unresolvable_base_is_an_error_not_a_pass(self):
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        status, output = self.run_check("origin/main...HEAD")
        self.assertEqual(status, 2, output)
        self.assertIn("cannot resolve 'origin/main'", output)

    def test_missing_spec_directory_is_an_error(self):
        status, output = self.run_check("--specs-dir", "nowhere", "base...HEAD")
        self.assertEqual(status, 2, output)

    def test_list_prints_the_model_map(self):
        status, output = self.run_check("--list")
        self.assertEqual(status, 0)
        self.assertIn(f"{REDUCER}\tspecs/downloads/Core.tla, specs/downloads/Reducer.tla", output)
        self.assertNotIn("Example.swift", output)


class RepositorySpecHeaderTests(unittest.TestCase):
    """The real specs: every MODELS path exists and every hand-written module declares one."""

    def test_modelled_files_exist(self):
        owners = drift.modelled_files(REPO, REPO / "specs")
        self.assertTrue(owners)
        for path in owners:
            self.assertTrue((REPO / path).is_file(), f"MODELS names a missing file: {path}")

    def test_every_downloads_module_declares_what_it_models(self):
        # These two hold no model of their own: one is generated from the Swift reducer, the
        # other compares that table with DownloadsReducer.tla.
        exempt = {"DownloadsReducerTable.tla", "DownloadsReducerConformance.tla"}
        declaring = {Path(module).name
                     for modules in drift.modelled_files(REPO, REPO / "specs").values()
                     for module in modules}
        for module in sorted((REPO / "specs" / "downloads").glob("*.tla")):
            if module.name not in exempt:
                self.assertIn(module.name, declaring, f"{module.name} has no `\\* MODELS:` line")

    def test_reducer_and_table_are_owned(self):
        owners = drift.modelled_files(REPO, REPO / "specs")
        self.assertEqual(
            owners["PMSKit/Sources/PMSKit/Downloads/DownloadLifecycleReducer.swift"],
            {"specs/downloads/DownloadsReducer.tla"})


if __name__ == "__main__":
    unittest.main()
