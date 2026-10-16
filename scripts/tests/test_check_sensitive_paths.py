import contextlib
import importlib.util
import io
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_sensitive_paths", ROOT / "scripts/check-sensitive-paths.py")
csp = importlib.util.module_from_spec(spec)
sys.modules["check_sensitive_paths"] = csp
spec.loader.exec_module(csp)


class SensitivePathTests(unittest.TestCase):
    def setUp(self):
        self.rules = csp.load_rules()

    def categories(self, *files):
        return dict(csp.matches(list(files), self.rules))

    def test_glob_forms(self):
        self.assertTrue(csp.glob_regex("**/*.plist").match("Info.plist"))
        self.assertTrue(csp.glob_regex("**/*.plist").match("Config/Info-tvOS.plist"))
        self.assertTrue(csp.glob_regex(".claude/").match(".claude/skills/x/SKILL.md"))
        self.assertFalse(csp.glob_regex("scripts/ci-*.sh").match("scripts/ci/x.sh"))
        self.assertFalse(csp.glob_regex("LICENSE").match("docs/LICENSE"))

    def test_sensitive_paths_are_flagged(self):
        found = self.categories(
            "Labstream/Labstream.entitlements",
            "Labstream/Shared/Auth/KeychainStore.swift",
            "PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift",
            "PMSKit/Package.resolved",
            ".woodpecker/hygiene.yml",
            "scripts/testflight-release.py",
            ".codex/skills/testflight-deploy/SKILL.md",
            "Labstream.xcodeproj/project.pbxproj",
        )
        self.assertEqual(len(found), 8)
        self.assertEqual(found["Labstream/Shared/Auth/KeychainStore.swift"],
                         "Authentication, credentials, and diagnostics redaction")

    def test_ordinary_changes_are_not_flagged(self):
        self.assertEqual(self.categories(
            "Labstream/Shared/Player/PlayerControls.swift",
            "PMSKit/Sources/PMSKit/Music/Queue.swift",
            "docs/DEVELOPMENT.md",
            "scripts/media-corpus.py",
        ), {})

    def test_every_rule_names_a_category(self):
        self.assertTrue(self.rules)
        self.assertTrue(all(category != "Sensitive" for category, _, _ in self.rules))

    def test_exit_code(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(csp.main(["--exit-code", "SECURITY.md"]), 1)
            self.assertEqual(csp.main(["--exit-code", "docs/README.md"]), 0)
        self.assertIn("SECURITY.md  [Policies and licensing]", out.getvalue())


if __name__ == "__main__":
    unittest.main()
