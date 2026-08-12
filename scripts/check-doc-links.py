#!/usr/bin/env python3
"""Validate repository-local Markdown links and heading anchors."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import urllib.parse
from collections import defaultdict
from pathlib import Path


FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")
INLINE_LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))")
REFERENCE_LINK_RE = re.compile(r"^\s*\[[^\]]+\]:\s*(?:<([^>]+)>|(\S+))")
HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.+?)\s*$")
EXPLICIT_ID_RE = re.compile(r"\s*\{#([A-Za-z][\w:.-]*)\}\s*$")


def tracked_markdown(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.md"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [root / item.decode() for item in result.stdout.split(b"\0") if item]


def visible_lines(text: str):
    fence: str | None = None
    for number, line in enumerate(text.splitlines(), 1):
        match = FENCE_RE.match(line)
        if match:
            marker = match.group(1)
            if fence is None:
                fence = marker[0]
            elif marker[0] == fence:
                fence = None
            continue
        if fence is None:
            yield number, line


def github_slug(text: str) -> str:
    text = EXPLICIT_ID_RE.sub("", text)
    text = re.sub(r"!?\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[`*_~]", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
    return text.replace(" ", "-")


def anchors(path: Path) -> set[str]:
    found: set[str] = set()
    duplicates: defaultdict[str, int] = defaultdict(int)
    for _, line in visible_lines(path.read_text(encoding="utf-8")):
        match = HEADING_RE.match(line)
        if not match:
            continue
        heading = match.group(2).rstrip("#").rstrip()
        explicit = EXPLICIT_ID_RE.search(heading)
        if explicit:
            found.add(explicit.group(1))
            continue
        base = github_slug(heading)
        if not base:
            continue
        count = duplicates[base]
        found.add(base if count == 0 else f"{base}-{count}")
        duplicates[base] += 1
    return found


def link_targets(path: Path):
    for number, line in visible_lines(path.read_text(encoding="utf-8")):
        line = re.sub(r"`[^`]*`", "", line)
        for match in INLINE_LINK_RE.finditer(line):
            yield number, match.group(1) or match.group(2)
        match = REFERENCE_LINK_RE.match(line)
        if match:
            yield number, match.group(1) or match.group(2)


def validate(root: Path) -> list[str]:
    root = root.resolve()
    errors: list[str] = []
    anchor_cache: dict[Path, set[str]] = {}
    for source in tracked_markdown(root):
        for line, raw_target in link_targets(source):
            target = raw_target.strip()
            parsed = urllib.parse.urlsplit(target)
            if parsed.scheme or parsed.netloc or target.startswith("/"):
                continue
            decoded_path = urllib.parse.unquote(parsed.path)
            destination = source if not decoded_path else (source.parent / decoded_path).resolve()
            try:
                destination.relative_to(root)
            except ValueError:
                errors.append(f"{source.relative_to(root)}:{line}: link escapes repository: {target}")
                continue
            if not destination.exists():
                errors.append(f"{source.relative_to(root)}:{line}: missing target: {target}")
                continue
            if parsed.fragment and destination.is_file() and destination.suffix.lower() == ".md":
                if destination.name == "SCRIPTS.md" and destination.parent.name == "docs":
                    destination = root / "scripts/README.md"
                fragment = urllib.parse.unquote(parsed.fragment)
                available = anchor_cache.setdefault(destination, anchors(destination))
                if fragment not in available:
                    errors.append(
                        f"{source.relative_to(root)}:{line}: missing anchor #{fragment} in "
                        f"{destination.relative_to(root)}"
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=None)
    args = parser.parse_args()
    root = (args.root or Path(__file__).resolve().parents[1]).resolve()
    errors = validate(root)
    if errors:
        print("Markdown link validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Markdown links and anchors: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
