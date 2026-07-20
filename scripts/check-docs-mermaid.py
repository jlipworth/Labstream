#!/usr/bin/env python3
"""Validate that every published Mermaid fence reaches generated MkDocs HTML."""

from __future__ import annotations

import argparse
import re
import sys
from html.parser import HTMLParser
from pathlib import Path


FENCE = re.compile(r"^(?P<indent>[ \t]*)(?P<marks>`{3,}|~{3,})(?P<info>.*)$")
EXTERNAL_MERMAID = re.compile(
    r"<script\b[^>]*\bsrc\s*=\s*['\"][^'\"]*(?:mermaid|cdn\.)[^'\"]*['\"]",
    re.IGNORECASE,
)


def config_value(config: str, key: str, default: str) -> str:
    match = re.search(rf"(?m)^{re.escape(key)}:\s*([^#\n]+?)\s*$", config)
    if not match:
        return default
    return match.group(1).strip().strip("'\"")


def excluded_prefixes(config: str) -> tuple[str, ...]:
    match = re.search(
        r"(?ms)^exclude_docs:\s*\|[^\n]*\n(?P<body>(?:^[ \t]+.*(?:\n|$))*)",
        config,
    )
    if not match:
        return ()
    prefixes: list[str] = []
    for line in match.group("body").splitlines():
        value = line.strip()
        if value and not value.startswith("#"):
            prefixes.append(value.rstrip("/") + "/")
    return tuple(prefixes)


def mermaid_fence_count(path: Path) -> int:
    count = 0
    active: tuple[str, int] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        match = FENCE.match(line)
        if not match:
            continue
        marks = match.group("marks")
        marker = marks[0]
        length = len(marks)
        if active is None:
            info = match.group("info").strip().split(None, 1)
            active = (marker, length)
            if info and info[0].lower() == "mermaid":
                count += 1
        elif marker == active[0] and length >= active[1] and not match.group("info").strip():
            active = None
    return count


class MermaidContainerCounter(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.count = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        classes = next((value for name, value in attrs if name == "class"), None)
        if classes and "mermaid" in classes.split():
            self.count += 1


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-file", default="mkdocs.yml")
    parser.add_argument("--site-dir", default="site")
    args = parser.parse_args()

    config_path = Path(args.config_file).resolve()
    config = config_path.read_text(encoding="utf-8")
    root = config_path.parent
    docs_dir = (root / config_value(config, "docs_dir", "docs")).resolve()
    site_dir = Path(args.site_dir)
    if not site_dir.is_absolute():
        site_dir = (root / site_dir).resolve()

    exclusions = excluded_prefixes(config)
    source_count = 0
    for path in docs_dir.rglob("*.md"):
        relative = path.relative_to(docs_dir).as_posix()
        if any(relative == prefix.rstrip("/") or relative.startswith(prefix) for prefix in exclusions):
            continue
        source_count += mermaid_fence_count(path)

    rendered_count = 0
    literal_fence = False
    external_script = False
    for path in site_dir.rglob("*.html"):
        html = path.read_text(encoding="utf-8")
        counter = MermaidContainerCounter()
        counter.feed(html)
        rendered_count += counter.count
        literal_fence = literal_fence or "```mermaid" in html
        external_script = external_script or bool(EXTERNAL_MERMAID.search(html))

    if source_count != rendered_count:
        return fail(
            f"published Mermaid source fences={source_count}, "
            f"rendered class=mermaid containers={rendered_count}"
        )
    if literal_fence:
        return fail("generated HTML contains a literal ```mermaid fence")
    if external_script:
        return fail("generated HTML contains an external Mermaid/CDN script")

    print(f"docs-mermaid: ok source={source_count} rendered={rendered_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
