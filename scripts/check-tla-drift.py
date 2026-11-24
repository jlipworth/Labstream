#!/usr/bin/env python3
"""Fail when a Swift file that a TLA+ spec models changed and the spec did not.

Each module under specs/ names the files it models, one per line, directly in the module text:

    \\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadLifecycleReducer.swift

For a commit range (default: origin/main...HEAD) every changed modelled file must be covered:

  - the spec changed too: every module that models the file, or one of that module's .cfg files
    (a config belongs to the module its `\\* SPEC:` header names), changed in the range; or
  - every commit in the range that touches the file says the model is unaffected, with a trailer:

        Spec-Unaffected: comment-only change to the reducer

Usage:
  check-tla-drift.py                    origin/main...HEAD
  check-tla-drift.py BASE...HEAD        the commits on HEAD since its merge base with BASE
  check-tla-drift.py BASE..HEAD         exactly BASE to HEAD
  check-tla-drift.py --list             print the modelled files and their modules

Exit status: 0 no drift; 1 drift, or a MODELS line that names a missing file; 2 the range or the
repository could not be read (that is an error, never a pass).
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

DEFAULT_RANGE = "origin/main...HEAD"
TRAILER = "Spec-Unaffected"
MODELS_LINE = re.compile(r"^\s*\\\*\s*MODELS:\s*(\S+)\s*$")
SPEC_LINE = re.compile(r"^\s*\\\*\s*SPEC:\s*(\S+)\s*$")


class DriftError(Exception):
    """The check could not run."""


def git(repo: pathlib.Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise DriftError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def relative(repo: pathlib.Path, path: pathlib.Path) -> str:
    return path.relative_to(repo).as_posix()


def modelled_files(repo: pathlib.Path, specs_dir: pathlib.Path) -> dict[str, set[str]]:
    """Modelled file -> the modules (repository-relative .tla paths) that declare it."""
    owners: dict[str, set[str]] = {}
    for module in sorted(specs_dir.rglob("*.tla")):
        for line in module.read_text(encoding="utf-8").splitlines():
            match = MODELS_LINE.match(line)
            if match:
                owners.setdefault(match.group(1), set()).add(relative(repo, module))
    return owners


def spec_artifacts(repo: pathlib.Path, specs_dir: pathlib.Path) -> dict[str, set[str]]:
    """Module -> itself and the configs that run it."""
    artifacts = {relative(repo, module): {relative(repo, module)} for module in specs_dir.rglob("*.tla")}
    for config in sorted(specs_dir.rglob("*.cfg")):
        declared = None
        for line in config.read_text(encoding="utf-8").splitlines():
            match = SPEC_LINE.match(line)
            if match:
                declared = match.group(1)
                break
        module = relative(repo, config.with_name(f"{declared or config.stem}.tla"))
        if module in artifacts:
            artifacts[module].add(relative(repo, config))
    return artifacts


def resolve_range(repo: pathlib.Path, spec: str) -> tuple[str, str]:
    """(base commit, head commit) for `A...B`, `A..B` or a single base revision."""
    if "..." in spec:
        left, right = spec.split("...", 1)
        symmetric = True
    elif ".." in spec:
        left, right = spec.split("..", 1)
        symmetric = False
    else:
        left, right, symmetric = spec, "HEAD", True
    left, right = left or "HEAD", right or "HEAD"

    def commit(rev: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
            capture_output=True, text=True)
        if result.returncode != 0:
            raise DriftError(
                f"cannot resolve {rev!r}; fetch it (for example `git fetch origin main`) "
                "or pass an explicit range")
        return result.stdout.strip()

    base, head = commit(left), commit(right)
    if symmetric:
        merge_base = subprocess.run(
            ["git", "-C", str(repo), "merge-base", base, head], capture_output=True, text=True)
        if merge_base.returncode != 0 or not merge_base.stdout.strip():
            raise DriftError(
                f"no merge base between {left} and {right}; the clone may be shallow "
                "(`git fetch --unshallow`) or the histories are unrelated")
        base = merge_base.stdout.strip()
    return base, head


def commits_in(repo: pathlib.Path, base: str, head: str) -> list[dict]:
    """The commits in base..head: hash, subject, touched files, Spec-Unaffected reasons."""
    commits = []
    # Merge commits are skipped: what they bring in is either already in the base or is
    # attributed to the commits that made the change.
    for sha in git(repo, "rev-list", "--reverse", "--no-merges", f"{base}..{head}").split():
        files = git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r",
                    "--no-renames", "--root", sha).splitlines()
        subject = git(repo, "show", "-s", "--format=%s", sha).strip()
        trailers = git(repo, "show", "-s", f"--format=%(trailers:key={TRAILER},valueonly)", sha)
        reasons = [line.strip() for line in trailers.splitlines() if line.strip()]
        commits.append({"sha": sha, "subject": subject, "files": set(files), "reasons": reasons})
    return commits


def check(repo: pathlib.Path, specs_dir: pathlib.Path, range_spec: str) -> tuple[list[str], list[str]]:
    """(problems, notes). No problems means no drift."""
    owners = modelled_files(repo, specs_dir)
    problems = [
        f"{module}: MODELS names a file that does not exist: {path}"
        for path, modules in sorted(owners.items()) if not (repo / path).is_file()
        for module in sorted(modules)
    ]
    artifacts = spec_artifacts(repo, specs_dir)
    base, head = resolve_range(repo, range_spec)
    changed = set(git(repo, "diff", "--name-only", "--no-renames", base, head).splitlines())
    commits = commits_in(repo, base, head)
    notes = []
    for path in sorted(changed & owners.keys()):
        stale = sorted(module for module in owners[path] if not (artifacts.get(module, {module}) & changed))
        if not stale:
            notes.append(f"{path}: spec updated ({', '.join(sorted(owners[path]))})")
            continue
        touching = [commit for commit in commits if path in commit["files"]]
        silent = [commit for commit in touching if not commit["reasons"]]
        if touching and not silent:
            reasons = "; ".join(sorted({reason for commit in touching for reason in commit["reasons"]}))
            notes.append(f"{path}: declared unaffected ({reasons})")
            continue
        problem = [f"{path} changed, but its spec did not: {', '.join(stale)}"]
        problem += [f"    {commit['sha'][:10]} {commit['subject']}" for commit in silent]
        problems.append("\n".join(problem))
    return problems, notes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("range", nargs="?", default=DEFAULT_RANGE,
                        help=f"commit range (default: {DEFAULT_RANGE})")
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1],
                        help="repository root (default: this script's repository)")
    parser.add_argument("--specs-dir", default="specs", help="spec directory, relative to the repository")
    parser.add_argument("--list", action="store_true", help="print the modelled files and exit")
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    specs_dir = repo / args.specs_dir
    try:
        if not specs_dir.is_dir():
            raise DriftError(f"no spec directory at {specs_dir}")
        if args.list:
            for path, modules in sorted(modelled_files(repo, specs_dir).items()):
                print(f"{path}\t{', '.join(sorted(modules))}")
            return 0
        problems, notes = check(repo, specs_dir, args.range)
    except DriftError as error:
        print(f"check-tla-drift: {error}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"ok    {note}")
    if problems:
        for problem in problems:
            print(f"DRIFT {problem}")
        print(
            f"\ncheck-tla-drift: {len(problems)} problem(s) in {args.range}. Update the spec with the "
            f"code, or add a `{TRAILER}: <reason>` trailer to each commit that changes a modelled "
            "file without changing what the spec describes.", file=sys.stderr)
        return 1
    print(f"check-tla-drift: ok ({args.range})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
