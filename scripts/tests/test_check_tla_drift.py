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
        self.write("specs/downloads/base/Reducer.tla", self.module("Reducer", REDUCER))
        self.write("specs/downloads/core/Core.tla", self.module("Core", REDUCER, SESSION))
        self.write("specs/downloads/base/Shared.tla", "---- MODULE Shared ----\n====\n")
        self.write("specs/downloads/core/Current.cfg", "\\* SPEC: Core\n\\* EXPECT: pass\n")
        self.write("specs/downloads/core/README.md", "notes\n")
        self.write("specs/downloads/core/Projection.cfg", "\\* SPEC: Reducer\n\\* EXPECT: pass\n")
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
        self.assertIn(f"{SESSION} changed, but its spec did not: specs/downloads/core/Core.tla", output)
        self.assertIn("change the session", output)
        self.assertIn("Spec-Unaffected", output)

    def test_spec_change_in_the_range_covers_the_file(self):
        self.append(SESSION)
        self.commit("change the session")
        self.append("specs/downloads/core/Core.tla", "\\* updated\n")
        self.commit("update the spec")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("spec updated", output)

    def test_a_config_of_the_module_counts_as_the_spec(self):
        self.append(SESSION)
        self.append("specs/downloads/core/Current.cfg", "\\* bound changed\n")
        self.commit("change the session and its config")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_any_file_in_the_module_folder_counts_as_the_spec(self):
        self.append(SESSION)
        self.append("specs/downloads/core/README.md", "more notes\n")
        self.commit("change the session and the module notes")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("spec updated", output)

    def test_another_module_folder_does_not_count(self):
        self.append(SESSION)
        self.write("specs/downloads/other/Other.tla", "---- MODULE Other ----\n====\n")
        self.commit("change the session and an unrelated spec")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)

    def test_a_shared_folder_neighbour_does_not_count(self):
        self.append(REDUCER)
        self.append("specs/downloads/core/Core.tla", "\\* updated\n")
        self.append("specs/downloads/base/Shared.tla", "\\* updated\n")
        self.commit("change the reducer, the core and a shared neighbour")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("its spec did not: specs/downloads/base/Reducer.tla", output)

    def test_a_config_elsewhere_that_runs_a_shared_module_counts(self):
        self.append(REDUCER)
        self.append("specs/downloads/core/Projection.cfg", "\\* bound changed\n")
        self.commit("change the reducer and the projection config")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_every_owning_module_must_change(self):
        self.append(REDUCER)
        self.append("specs/downloads/base/Reducer.tla", "\\* updated\n")
        self.commit("change the reducer and one of its two specs")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("specs/downloads/core/Core.tla", output)
        self.assertNotIn("did not: specs/downloads/base/Reducer.tla, specs/downloads/core/Core.tla", output)

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

    def test_malformed_declaration_fails_even_beside_valid_declarations(self):
        self.append("specs/downloads/core/Core.tla", "\\* MODELS: Sources/Other.swift \\* note\n")
        self.commit("malformed declaration")
        status, output = self.run_check()
        self.assertEqual(status, 2)
        self.assertIn("Core.tla:", output)
        self.assertIn("malformed MODELS", output)

    def test_missing_modelled_file_fails(self):
        self.git("rm", "-q", SESSION)
        self.commit("remove the session\n\nSpec-Unaffected: file removed")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn(f"MODELS names a file that does not exist: {SESSION}", output)

    # --- Reviewer scenarios (round 1, R3 item 7) ---

    def merge_with_resolution(self, resolution_message):
        """A covered formatting commit, then a second edit made only while resolving a merge."""
        self.append(SESSION, "// formatted\n")
        self.commit("format the session\n\nSpec-Unaffected: formatting")
        self.git("checkout", "-q", "-b", "side", "base")
        self.append(SESSION, "// side change\n")
        self.commit("side: change the session\n\nSpec-Unaffected: comment only")
        self.git("checkout", "-q", "main")
        merge = subprocess.run(["git", "merge", "--no-ff", "--no-commit", "side"], cwd=self.root,
                               capture_output=True, text=True)
        self.assertNotEqual(merge.returncode, 0, "the two edits must conflict")
        self.write(SESSION, "// session\n// formatted\n// side change\nfunc behaviourAddedInTheMerge() {}\n")
        self.commit(resolution_message)

    def test_a_merge_resolution_edit_needs_its_own_coverage(self):
        self.merge_with_resolution("Merge branch 'side'")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("Merge branch 'side' (merge: its own edit needs a trailer)", output)
        self.assertNotIn("format the session", output)

    def test_a_merge_resolution_with_a_trailer_is_covered(self):
        self.merge_with_resolution("Merge branch 'side'\n\nSpec-Unaffected: kept both comments")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("kept both comments", output)

    def test_a_clean_merge_needs_no_trailer(self):
        self.append(SESSION, "// formatted\n")
        self.commit("format the session\n\nSpec-Unaffected: formatting")
        self.git("checkout", "-q", "-b", "side", "base")
        self.write(SESSION, "// side change\n// session\n")
        self.write("Sources/Other.swift", "// other, changed on the side\n")
        self.commit("side: change the session\n\nSpec-Unaffected: comment only")
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-ff", "-m", "Merge branch 'side'", "side")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("declared unaffected (comment only; formatting)", output)

    def test_an_edit_smuggled_into_a_clean_merge_needs_coverage(self):
        self.git("checkout", "-q", "-b", "side", "base")
        self.append("Sources/Other.swift")
        self.commit("side: change something else")
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-ff", "--no-commit", "side")
        self.append(SESSION, "func addedInTheMerge() {}\n")
        self.commit("Merge branch 'side'")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("(merge: its own edit needs a trailer)", output)

    def test_merging_the_base_branch_brings_no_drift(self):
        self.git("checkout", "-q", "-b", "feature", "base")
        self.append("Sources/Other.swift")
        self.commit("feature work")
        self.git("checkout", "-q", "base")
        self.append(SESSION)
        self.commit("base branch changes the session")
        self.git("checkout", "-q", "feature")
        self.git("merge", "-q", "--no-ff", "-m", "Merge base into feature", "base")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_uncommitted_removal_of_a_declaration_does_not_hide_drift(self):
        self.append(SESSION)
        self.commit("change the session")
        self.assertEqual(self.run_check()[0], 1)
        self.write("specs/downloads/core/Core.tla", self.module("Core", REDUCER))
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn(f"{SESSION} changed, but its spec did not", output)

    def test_uncommitted_spec_edits_and_deletions_do_not_change_the_answer(self):
        self.append(SESSION)
        self.commit("change the session")
        self.append("specs/downloads/core/Current.cfg", "\\* uncommitted\n")
        (self.root / SESSION).unlink()
        (self.root / "specs/downloads/core/Projection.cfg").unlink()
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertNotIn("does not exist", output)
        self.assertEqual(self.run_check("--list")[0], 0)

    def test_committed_removal_of_a_declaration_is_a_spec_change(self):
        self.append(SESSION)
        self.write("specs/downloads/core/Core.tla", self.module("Core", REDUCER))
        self.commit("change the session and stop modelling it")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_deleting_a_shared_modules_config_counts_as_changing_it(self):
        self.append(REDUCER)
        self.git("rm", "-q", "specs/downloads/core/Projection.cfg")
        self.append("specs/downloads/core/Core.tla", "\\* updated\n")
        self.commit("change the reducer, drop the projection config")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn(f"{REDUCER}: spec updated", output)

    def test_deleting_another_modules_config_does_not_count(self):
        self.write("specs/downloads/base/Shared-Check.cfg", "\\* SPEC: Shared\n\\* EXPECT: pass\n")
        self.commit("a config of the shared neighbour")
        self.git("branch", "-f", "base")
        self.append(REDUCER)
        self.git("rm", "-q", "specs/downloads/base/Shared-Check.cfg")
        self.append("specs/downloads/core/Core.tla", "\\* updated\n")
        self.commit("change the reducer, drop a neighbour's config")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("its spec did not: specs/downloads/base/Reducer.tla", output)

    def test_renaming_a_shared_modules_config_counts(self):
        self.append(REDUCER)
        self.git("mv", "specs/downloads/core/Projection.cfg", "specs/downloads/base/Reducer-Check.cfg")
        self.append("specs/downloads/core/Core.tla", "\\* updated\n")
        self.commit("change the reducer, move its config")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_repointing_a_config_counts_for_the_module_it_ran(self):
        self.append(REDUCER)
        self.write("specs/downloads/core/Projection.cfg", "\\* SPEC: Core\n\\* EXPECT: pass\n")
        self.commit("change the reducer, re-point its projection at the core")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_renaming_a_module_with_its_modelled_file_is_covered(self):
        self.append(SESSION)
        self.git("mv", "specs/downloads/core", "specs/downloads/session")
        self.commit("change the session, rename its module folder")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_deleting_a_module_with_its_modelled_file_change_is_covered(self):
        self.append(SESSION)
        self.git("rm", "-q", "-r", "specs/downloads/core")
        self.commit("change the session, delete its only model")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_renaming_a_modelled_file_needs_the_declaration_to_follow(self):
        self.git("mv", SESSION, "Sources/Session2.swift")
        self.commit("rename the session\n\nSpec-Unaffected: rename only")
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn(f"MODELS names a file that does not exist: {SESSION}", output)
        self.write("specs/downloads/core/Core.tla", self.module("Core", REDUCER, "Sources/Session2.swift"))
        self.commit("follow the rename")
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

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
        self.assertIn(f"{REDUCER}\tspecs/downloads/base/Reducer.tla, specs/downloads/core/Core.tla", output)
        self.assertNotIn("Example.swift", output)


class RepositorySpecHeaderTests(unittest.TestCase):
    """The real specs: every MODELS path exists and every hand-written module declares one."""

    def test_modelled_files_exist(self):
        owners = drift.modelled_files(drift.WorkTree(REPO, "specs"))
        self.assertTrue(owners)
        for path in owners:
            self.assertTrue((REPO / path).is_file(), f"MODELS names a missing file: {path}")

    def test_every_downloads_module_declares_what_it_models(self):
        # These hold no model of Swift of their own. One is generated from the Swift reducer and
        # one compares that table with DownloadsReducer.tla. The session's row map is how the
        # session model stores a reducer state (part of that model, which declares its files),
        # and its check compares the map with the same table.
        exempt = {"DownloadsReducerTable.tla", "DownloadsReducerConformance.tla",
                  "DownloadsSessionRowMap.tla", "DownloadsSessionRowMapCheck.tla"}
        declaring = {Path(module).name
                     for modules in drift.modelled_files(drift.WorkTree(REPO, "specs")).values()
                     for module in modules}
        modules = sorted((REPO / "specs" / "downloads").rglob("*.tla"))
        self.assertGreaterEqual(len(modules), 12)
        for module in modules:
            if module.name not in exempt:
                self.assertIn(module.name, declaring, f"{module.name} has no `\\* MODELS:` line")

    def test_reducer_and_table_are_owned(self):
        owners = drift.modelled_files(drift.WorkTree(REPO, "specs"))
        self.assertEqual(
            owners["PMSKit/Sources/PMSKit/Downloads/DownloadLifecycleReducer.swift"],
            {"specs/downloads/base/DownloadsReducer.tla"})


if __name__ == "__main__":
    unittest.main()
