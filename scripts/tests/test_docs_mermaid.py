import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
CHECKER = REPO / "scripts" / "check-docs-mermaid.py"


class DocsMermaidCheckerTests(unittest.TestCase):
    def run_checker(
        self,
        source: str,
        html: str,
        *,
        excluded_source: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            docs = root / "docs"
            site = root / "site"
            docs.mkdir()
            site.mkdir()
            (docs / "index.md").write_text(textwrap.dedent(source), encoding="utf-8")
            (site / "index.html").write_text(textwrap.dedent(html), encoding="utf-8")

            config = "docs_dir: docs\n"
            if excluded_source is not None:
                plans = docs / "plans"
                plans.mkdir()
                (plans / "example.md").write_text(
                    textwrap.dedent(excluded_source), encoding="utf-8"
                )
                config += "exclude_docs: |\n  plans/\n"
            config_path = root / "mkdocs.yml"
            config_path.write_text(config, encoding="utf-8")

            return subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--config-file",
                    str(config_path),
                    "--site-dir",
                    str(site),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

    def test_accepts_matching_published_source_and_rendered_container_counts(self):
        result = self.run_checker(
            """
            # Page

            ```mermaid
            flowchart LR
              A --> B
            ```
            """,
            """
            <!doctype html>
            <html><body><pre class="diagram mermaid"><code>flowchart LR</code></pre></body></html>
            """,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source=1 rendered=1", result.stdout)

    def test_rejects_missing_rendered_container_for_a_published_source_fence(self):
        result = self.run_checker(
            """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """,
            "<html><body><pre><code>flowchart LR</code></pre></body></html>",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "published Mermaid source fences=1, rendered class=mermaid containers=0",
            result.stderr,
        )

    def test_rejects_literal_mermaid_fence_in_generated_html(self):
        result = self.run_checker(
            """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """,
            """
            <html><body>
              <pre class="mermaid"><code>flowchart LR</code></pre>
              <p>```mermaid</p>
            </body></html>
            """,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("literal ```mermaid fence", result.stderr)

    def test_rejects_external_mermaid_cdn_script(self):
        result = self.run_checker(
            """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """,
            """
            <html><body>
              <pre class="mermaid"><code>flowchart LR</code></pre>
              <script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
            </body></html>
            """,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("external Mermaid/CDN script", result.stderr)

    def test_excludes_unpublished_source_lanes_from_the_source_count(self):
        result = self.run_checker(
            """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """,
            '<html><body><pre class="mermaid"><code>flowchart LR</code></pre></body></html>',
            excluded_source="""
            ```mermaid
            flowchart LR
              Hidden --> Draft
            ```
            """,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source=1 rendered=1", result.stdout)

    def test_does_not_count_a_mermaid_example_inside_a_longer_fence(self):
        result = self.run_checker(
            """
            ````markdown
            ```mermaid
            flowchart LR
              Example --> Only
            ```
            ````

            ```mermaid
            flowchart LR
              Published --> Diagram
            ```
            """,
            '<html><body><pre class="mermaid"><code>flowchart LR</code></pre></body></html>',
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source=1 rendered=1", result.stdout)


class DocsMermaidRepositoryContractTests(unittest.TestCase):
    def test_published_diagrams_follow_accessible_portable_source_conventions(self):
        fence = re.compile(r"(?ms)^```mermaid\s*\n(.*?)^```\s*$")
        published = sorted(path for path in (REPO / "docs").glob("*.md"))

        for path in published:
            for index, source in enumerate(fence.findall(path.read_text(encoding="utf-8")), 1):
                label = f"{path.relative_to(REPO)} Mermaid diagram {index}"
                self.assertEqual(source.count("accTitle:"), 1, label)
                self.assertEqual(source.count("accDescr:"), 1, label)
                self.assertIsNone(re.search(r"(?m)^\s*click\s+", source), label)
                self.assertIsNone(re.search(r"(?im)<\s*(?:br|div|span|font|img)\b", source), label)
                self.assertIsNone(re.search(r"(?m)^\s*(?:classDef|style)\s+", source), label)

    def test_mkdocs_uses_materials_bundled_mermaid_custom_fence_exactly(self):
        config = (REPO / "mkdocs.yml").read_text(encoding="utf-8")
        expected = """\
  - pymdownx.superfences:
      custom_fences:
        - name: mermaid
          class: mermaid
          format: !!python/name:pymdownx.superfences.fence_code_format
"""
        self.assertIn(expected, config)
        self.assertEqual(config.count("name: mermaid"), 1)
        self.assertNotIn("extra_javascript:", config)
        self.assertNotIn("extra_css:", config)

    def test_requirements_add_no_separate_mermaid_dependency(self):
        requirements = (REPO / "requirements.txt").read_text(encoding="utf-8").lower()
        self.assertNotIn("mermaid", requirements)

    def test_pull_request_docs_pipeline_is_unprivileged(self):
        pipeline = (REPO / ".woodpecker" / "docs-pr.yml").read_text(encoding="utf-8")
        self.assertIn("event: pull_request", pipeline)
        self.assertIn("mkdocs build --strict", pipeline)
        self.assertIn("scripts/check-docs-mermaid.py", pipeline)
        self.assertNotIn("from_secret", pipeline)
        self.assertNotIn("DEPLOY_KEY", pipeline)
        self.assertNotIn("gh-deploy", pipeline)

    def test_docs_deployment_remains_trusted_main_only(self):
        pipeline = (REPO / ".woodpecker" / "docs.yml").read_text(encoding="utf-8")
        self.assertIn("event: push", pipeline)
        self.assertIn("event: manual", pipeline)
        self.assertIn("branch: main", pipeline)
        self.assertNotIn("pull_request", pipeline)
        self.assertIn("DEPLOY_KEY: { from_secret: github_deploy_key }", pipeline)
        self.assertIn("scripts/check-docs-mermaid.py", pipeline)

    def test_repo_hygiene_builds_and_checks_published_documentation(self):
        hygiene = (REPO / "scripts" / "ci-hygiene.sh").read_text(encoding="utf-8")
        self.assertIn("mkdocs build --strict", hygiene)
        self.assertIn("scripts/check-docs-mermaid.py", hygiene)


if __name__ == "__main__":
    unittest.main()
