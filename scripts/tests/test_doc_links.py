import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_doc_links", REPO / "scripts/check-doc-links.py")
LINKS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(LINKS)


class DocumentationLinkTests(unittest.TestCase):
    def make_repo(self, files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp())
        subprocess.run(["git", "init", "-q", root], check=True)
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        self.addCleanup(lambda: __import__("shutil").rmtree(root))
        return root

    def test_accepts_relative_files_fragments_and_duplicate_headings(self):
        root = self.make_repo({
            "README.md": "[first](docs/guide.md#setup) [second](docs/guide.md#setup-1)\n",
            "docs/guide.md": "# Setup\n\n## Setup\n",
        })
        self.assertEqual(LINKS.validate(root), [])

    def test_reports_missing_file_and_anchor_but_ignores_code_fences(self):
        root = self.make_repo({
            "README.md": (
                "[bad file](missing.md)\n[bad anchor](guide.md#absent)\n"
                "```md\n[historical example](also-missing.md)\n```\n"
            ),
            "guide.md": "# Present\n",
        })
        errors = LINKS.validate(root)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("missing target" in error for error in errors))
        self.assertTrue(any("missing anchor" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
