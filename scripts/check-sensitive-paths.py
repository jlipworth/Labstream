#!/usr/bin/env python3
"""List the changed files that touch Labstream's sensitive paths.

The globs live in .github/triage/sensitive-paths.txt. Give the changed files one of three ways:

  check-sensitive-paths.py --pr 123          a pull request, including renamed-from paths (needs gh)
  check-sensitive-paths.py --base origin/main  the commits on HEAD since BASE
  check-sensitive-paths.py FILE... | -        explicit paths, or one per line on stdin

Prints each matching file with its category, or "no sensitive paths". With --exit-code, exits 1
when anything matches. Read-only: it never checks out or runs pull-request code.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
RULES = REPO / ".github" / "triage" / "sensitive-paths.txt"


def glob_regex(glob: str) -> re.Pattern[str]:
    if glob.endswith("/"):
        glob += "**"
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def load_rules(path: pathlib.Path = RULES) -> list[tuple[str, str, re.Pattern[str]]]:
    rules, category = [], "Sensitive"
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("## "):
            category = line[3:].strip()
        elif line and not line.startswith("#"):
            rules.append((category, line, glob_regex(line)))
    return rules


def matches(files: list[str], rules) -> list[tuple[str, str]]:
    out = []
    for name in sorted(set(files)):
        for category, _glob, pattern in rules:
            if pattern.match(name):
                out.append((name, category))
                break
    return out


def pr_files(number: int) -> list[str]:
    raw = subprocess.run(
        ["gh", "api", "--paginate", f"repos/{{owner}}/{{repo}}/pulls/{number}/files",
         "-q", ".[] | [.filename, (.previous_filename // empty)] | .[]"],
        cwd=REPO, check=True, capture_output=True, text=True).stdout
    return [line for line in raw.splitlines() if line]


def base_files(base: str) -> list[str]:
    raw = subprocess.run(["git", "diff", "--name-only", "--no-renames", f"{base}...HEAD"],
                         cwd=REPO, check=True, capture_output=True, text=True).stdout
    return [line for line in raw.splitlines() if line]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--pr", type=int, help="pull request number")
    source.add_argument("--base", help="compare HEAD with this ref")
    parser.add_argument("files", nargs="*", help="paths, or - to read them from stdin")
    parser.add_argument("--exit-code", action="store_true", help="exit 1 when anything matches")
    parser.add_argument("--rules", type=pathlib.Path, default=RULES, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.pr is not None:
        files = pr_files(args.pr)
    elif args.base:
        files = base_files(args.base)
    elif args.files == ["-"]:
        files = [line.strip() for line in sys.stdin if line.strip()]
    elif args.files:
        files = args.files
    else:
        parser.error("give --pr, --base, or file paths")

    found = matches(files, load_rules(args.rules))
    for name, category in found:
        print(f"{name}  [{category}]")
    print(f"{len(found)} sensitive path(s)" if found else "no sensitive paths")
    return 1 if found and args.exit_code else 0


if __name__ == "__main__":
    sys.exit(main())
