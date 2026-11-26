#!/usr/bin/env python3
"""Fail when a Swift file that a TLA+ spec models changed and the spec did not.

Each module under specs/ (specs/<area>/<module>/<Module>.tla, found recursively) names the files
it models, one per line, directly in the module text:

    \\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadLifecycleReducer.swift

For a commit range (default: origin/main...HEAD) every changed modelled file must be covered:

  - the spec changed too: for every module that models the file, something in that module's
    folder changed in the range (the module, a helper module, a config, its notes). A module in
    a shared `base/` folder is stricter, because that folder holds unrelated modules: only the
    module itself or one of its .cfg files counts (a config belongs to the module its
    `\\* SPEC:` header names, in its own folder or in the area's base/). A config that the range
    deleted, moved or re-pointed counts for the module it ran at the start of the range; or
  - every commit in the range that touches the file says the model is unaffected, with a trailer:

        Spec-Unaffected: comment-only change to the reducer

    A merge commit touches a file when its recorded result differs from what Git's own merge of
    its parents produces (a conflict resolution, or an edit made while merging). Such a merge
    needs its own trailer; a clean merge needs none.

Everything is read from Git objects: the MODELS lines, the configs and the modelled files come
from the range's head commit (and its base commit, for configs the range removed). Uncommitted
edits in the checkout never change the answer.

Usage:
  check-tla-drift.py                    origin/main...HEAD
  check-tla-drift.py BASE...HEAD        the commits on HEAD since its merge base with BASE
  check-tla-drift.py BASE..HEAD         exactly BASE to HEAD
  check-tla-drift.py --list             print the modelled files and their modules (at HEAD)

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


class CommitTree:
    """The files of one commit, read from Git objects."""

    def __init__(self, repo: pathlib.Path, commit: str, specs: str):
        self.repo, self.commit, self.specs = repo, commit, specs.strip("/")
        self.paths = set(git(repo, "ls-tree", "-r", "--name-only", "-z", commit).split("\0")) - {""}
        self._text: dict[str, str] = {}

    def exists(self, path: str) -> bool:
        return path in self.paths

    def spec_files(self, suffix: str) -> list[str]:
        prefix = self.specs + "/"
        return sorted(path for path in self.paths if path.startswith(prefix) and path.endswith(suffix))

    def read(self, path: str) -> str:
        if path not in self._text:
            self._text[path] = git(self.repo, "show", f"{self.commit}:{path}")
        return self._text[path]


class WorkTree(CommitTree):
    """The checkout's files. For authoring checks only; the drift check never uses it."""

    def __init__(self, repo: pathlib.Path, specs: str):
        self.repo, self.specs = repo, specs.strip("/")
        root = repo / self.specs
        self.paths = {path.relative_to(repo).as_posix() for path in root.rglob("*") if path.is_file()}

    def exists(self, path: str) -> bool:
        return (self.repo / path).is_file()

    def read(self, path: str) -> str:
        return (self.repo / path).read_text(encoding="utf-8")


def modelled_files(tree: CommitTree) -> dict[str, set[str]]:
    """Modelled file -> the modules (repository-relative .tla paths) that declare it."""
    owners: dict[str, set[str]] = {}
    for module in tree.spec_files(".tla"):
        for number, line in enumerate(tree.read(module).splitlines(), 1):
            match = MODELS_LINE.match(line)
            if match:
                owners.setdefault(match.group(1), set()).add(module)
            elif re.match(r"^\s*\\\*\s*MODELS:", line):
                raise DriftError(f"{module}:{number}: malformed MODELS declaration (expected one path)")
    return owners


SHARED_FOLDER = "base"


def config_module(tree: CommitTree, config: str) -> str:
    """The module a config runs: beside it, else in its area's shared folder."""
    declared = None
    for line in tree.read(config).splitlines():
        match = SPEC_LINE.match(line)
        if match:
            declared = match.group(1)
            break
    path = pathlib.PurePosixPath(config)
    name = f"{declared or path.stem}.tla"
    beside = (path.parent / name).as_posix()
    shared = (path.parent.parent / SHARED_FOLDER / name).as_posix()
    return shared if not tree.exists(beside) and tree.exists(shared) else beside


def spec_artifacts(head: CommitTree, base: CommitTree | None = None,
                   changed: set[str] = frozenset()) -> dict[str, set[str]]:
    """Module (at the head commit) -> the paths whose change counts as changing it.

    A path ending in `/` is a folder: any file under it counts. That is the module's own folder,
    unless the module sits in a shared folder; then only it and the configs that run it count.
    A changed config also counts for the module it ran in the base commit, so deleting, moving
    or re-pointing a config is a change to the module it used to check.
    """
    artifacts = {}
    for module in head.spec_files(".tla"):
        paths = {module}
        folder = pathlib.PurePosixPath(module).parent
        if folder.name != SHARED_FOLDER:
            paths.add(folder.as_posix() + "/")
        artifacts[module] = paths
    for config in head.spec_files(".cfg"):
        module = config_module(head, config)
        if module in artifacts:
            artifacts[module].add(config)
    if base is not None:
        for config in base.spec_files(".cfg"):
            if config in changed:
                module = config_module(base, config)
                if module in artifacts:
                    artifacts[module].add(config)
    return artifacts


def touched(artifacts: set[str], changed: set[str]) -> bool:
    folders = tuple(path for path in artifacts if path.endswith("/"))
    return bool(artifacts & changed) or any(path.startswith(folders) for path in changed if folders)


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


def merge_resolution_files(repo: pathlib.Path, sha: str, parents: list[str]) -> set[str]:
    """The files a merge commit itself changed, beyond merging its parents.

    For a two-parent merge that is the difference between the recorded tree and Git's own
    re-merge of the parents: empty for a clean merge, the resolved or hand-edited files
    otherwise. Other merges (octopus) use the combined diff: every file whose result differs
    from all parents, which also lists cleanly merged files and so only over-reports.
    """
    if len(parents) == 2:
        names = git(repo, "show", "--diff-merges=remerge", "--no-renames", "--name-only", "-z",
                    "--format=", sha)
    else:
        names = git(repo, "diff-tree", "-c", "--no-commit-id", "--name-only", "-r", "-z",
                    "--no-renames", sha)
    return set(names.split("\0")) - {""}


def commits_in(repo: pathlib.Path, base: str, head: str) -> list[dict]:
    """The commits in base..head: hash, subject, touched files, Spec-Unaffected reasons."""
    commits = []
    for line in git(repo, "rev-list", "--reverse", "--parents", f"{base}..{head}").splitlines():
        sha, *parents = line.split()
        if len(parents) > 1:
            # What a merge brings in from a parent is attributed to the commits that made it
            # (or is already in the base). Only the merge's own edits belong to the merge.
            files = merge_resolution_files(repo, sha, parents)
        else:
            files = set(git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r",
                            "--no-renames", "--root", sha).splitlines())
        subject = git(repo, "show", "-s", "--format=%s", sha).strip()
        trailers = git(repo, "show", "-s", f"--format=%(trailers:key={TRAILER},valueonly)", sha)
        reasons = [line.strip() for line in trailers.splitlines() if line.strip()]
        commits.append({"sha": sha, "subject": subject, "files": files, "reasons": reasons,
                        "merge": len(parents) > 1})
    return commits


def check(repo: pathlib.Path, specs: str, range_spec: str) -> tuple[list[str], list[str]]:
    """(problems, notes). No problems means no drift."""
    base, head = resolve_range(repo, range_spec)
    head_tree = CommitTree(repo, head, specs)
    if not head_tree.spec_files(""):
        raise DriftError(f"no spec directory {specs}/ in commit {head[:10]}")
    owners = modelled_files(head_tree)
    problems = [
        f"{module}: MODELS names a file that does not exist: {path}"
        for path, modules in sorted(owners.items()) if not head_tree.exists(path)
        for module in sorted(modules)
    ]
    changed = set(git(repo, "diff", "--name-only", "--no-renames", "-z", base, head).split("\0")) - {""}
    artifacts = spec_artifacts(head_tree, CommitTree(repo, base, specs), changed)
    commits = commits_in(repo, base, head)
    notes = []
    for path in sorted(changed & owners.keys()):
        stale = sorted(module for module in owners[path]
                       if not touched(artifacts.get(module, {module}), changed))
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
        problem += [f"    {commit['sha'][:10]} {commit['subject']}"
                    + (" (merge: its own edit needs a trailer)" if commit["merge"] else "")
                    for commit in silent]
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
    try:
        if args.list:
            head = CommitTree(repo, resolve_range(repo, "HEAD..HEAD")[1], args.specs_dir)
            if not head.spec_files(""):
                raise DriftError(f"no spec directory {args.specs_dir}/ in HEAD")
            for path, modules in sorted(modelled_files(head).items()):
                print(f"{path}\t{', '.join(sorted(modules))}")
            return 0
        problems, notes = check(repo, args.specs_dir, args.range)
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
