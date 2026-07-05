#!/usr/bin/env python3
"""Audit public-publication surfaces without printing sensitive values.

Surfaces covered:
  1. tracked documentation/config text files in HEAD,
  2. commit messages and historical blobs across all refs,
  3. optionally, GitHub issue bodies/comments via `gh api`.

The report is intentionally conservative: it prints locations, categories, and
redacted snippets only. It does not echo local forbidden strings loaded from
scripts/ci-hygiene.local.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
os.chdir(REPO)

DOC_SUFFIXES = (".md", ".yml", ".yaml")
DOC_ALWAYS = {"mkdocs.yml", "AGENTS.md", "CLAUDE.md"}
DOC_PREFIXES = (".github/", ".woodpecker/")

PLEX_TOKEN_HEADER = "X-Plex" + "-Token"
PLEX_TOKEN_ENV = "PLEX" + "_TOKEN"

PATTERNS: dict[str, re.Pattern[str]] = {
    # Avoid treating Jellyfin/Emby API endpoints such as /Users/AuthenticateByName as home dirs.
    "home_path": re.compile(r"/Users/(?!AuthenticateByName|Authenticate\b)[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|/path/to/temp"),
    "private_lan_ip": re.compile(r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"),
    "plex_token_marker": re.compile(re.escape(PLEX_TOKEN_HEADER) + "|" + re.escape(PLEX_TOKEN_ENV), re.IGNORECASE),
    "likely_raw_token": re.compile(r"(?i)(bearer\s+[a-z0-9._~+/-]{12,}|token\s*[:=]\s*[a-z0-9._~+/-]{12,}|x-plex-token[=:][a-z0-9._~+/-]{4,})"),
}


def run(args: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def tracked_files() -> list[str]:
    return run(["git", "ls-files"], check=True).stdout.splitlines()


def doc_files(files: list[str]) -> list[str]:
    return [
        path for path in files
        if path.endswith(DOC_SUFFIXES) or path in DOC_ALWAYS or path.startswith(DOC_PREFIXES)
    ]


def text_for_path(path: str) -> str | None:
    try:
        data = Path(path).read_bytes()
    except OSError:
        return None
    if b"\0" in data[:4096]:
        return None
    return data.decode("utf-8", errors="ignore")


def redact(text: str) -> str:
    text = re.sub(r"/Users/[A-Za-z0-9._-]+", "/Users/<user>", text)
    text = re.sub(r"/home/[A-Za-z0-9._-]+", "/home/<user>", text)
    text = re.sub(r"/path/to/temp/[^\s`)]+", "/path/to/temp/<redacted>", text)
    text = re.sub(
        r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b",
        "<private-ip>",
        text,
    )
    text = re.sub(r"(?i)(" + re.escape(PLEX_TOKEN_HEADER) + r"(?:=|: ?))[^&\s`)]+", r"\1<redacted>", text)
    text = re.sub(r"(?i)(" + re.escape(PLEX_TOKEN_ENV) + r"=)[^\s`)]+", r"\1<redacted>", text)
    text = re.sub(r"(?i)(bearer\s+)[a-z0-9._~+/-]{12,}", r"\1<redacted>", text)
    text = re.sub(r"(?i)(token\s*[:=]\s*)[a-z0-9._~+/-]{12,}", r"\1<redacted>", text)
    return " ".join(text.split())


def snippets(label: str, text: str, *, limit: int = 3) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for name, rx in PATTERNS.items():
        for match in rx.finditer(text):
            start = max(0, match.start() - 70)
            end = min(len(text), match.end() + 140)
            out.append((name, redact(text[start:end])[:240]))
            if len(out) >= limit:
                return out
    return out


def load_extra_forbidden() -> list[str]:
    path = Path("scripts/ci-hygiene.local")
    if not path.exists():
        return []
    extras: list[str] = []
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.rstrip("\r")
        if line and not line.startswith("#"):
            extras.append(line)
    return extras


def scan_docs(files: list[str]) -> int:
    docs = doc_files(files)
    print(f"== tracked documentation/config text ({len(docs)} files) ==")
    findings = 0
    for path in docs:
        text = text_for_path(path)
        if text is None:
            continue
        hit_counts = {name: len(rx.findall(text)) for name, rx in PATTERNS.items()}
        hit_counts = {name: count for name, count in hit_counts.items() if count}
        if not hit_counts:
            continue
        findings += 1
        counts = ", ".join(f"{name}={count}" for name, count in hit_counts.items())
        print(f"DOC {path}: {counts}")
        for name, snippet in snippets(path, text):
            print(f"  {name}: {snippet}")
    if findings == 0:
        print("No documentation/config pattern hits.")
    return findings


def scan_commit_messages() -> int:
    print("== commit messages across all refs ==")
    proc = run(["git", "log", "--all", "--format=%H%x00%s%x00%b%x00END"], check=True)
    findings = 0
    for record in proc.stdout.split("\x00END"):
        if not record.strip():
            continue
        parts = record.split("\x00", 2)
        if len(parts) != 3:
            continue
        sha, subject, body = parts
        text = f"{subject}\n{body}"
        categories = [name for name, rx in PATTERNS.items() if rx.search(text)]
        if categories:
            findings += 1
            print(f"COMMIT {sha[:12]} {','.join(categories)} {redact(subject)[:180]}")
    if findings == 0:
        print("No commit-message pattern hits.")
    return findings


def scan_history_blobs(extras: list[str]) -> None:
    print("== historical blobs across all refs ==")
    commits = run(["git", "rev-list", "--all"], check=True).stdout.splitlines()
    print(f"Commit count scanned: {len(commits)}")
    history_patterns = {
        "home_path": r"/Users/(?!AuthenticateByName|Authenticate\b)[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|/path/to/temp",
        "private_lan_ip": r"\b(10\.([0-9]{1,3}\.){2}[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3})\b",
        "plex_token_marker": re.escape(PLEX_TOKEN_HEADER) + "|" + re.escape(PLEX_TOKEN_ENV),
    }
    for name, pattern in history_patterns.items():
        hit_commits: set[str] = set()
        hit_files: Counter[str] = Counter()
        samples: list[tuple[str, str]] = []
        for i in range(0, len(commits), 60):
            batch = commits[i:i + 60]
            grep = run(["git", "grep", "-l", "-I", "-P", pattern, *batch])
            for line in grep.stdout.splitlines():
                if ":" not in line:
                    continue
                commit, path = line.split(":", 1)
                hit_commits.add(commit)
                hit_files[path] += 1
                if len(samples) < 8:
                    samples.append((commit[:12], path))
        print(f"HISTORY {name}: commits={len(hit_commits)} files={len(hit_files)}")
        for commit, path in samples:
            print(f"  sample {commit} {path}")

    print(f"Local extra forbidden strings loaded: {len(extras)}")
    for idx, value in enumerate(extras, 1):
        hit_commits: set[str] = set()
        for i in range(0, len(commits), 80):
            batch = commits[i:i + 80]
            grep = run(["git", "grep", "-l", "-I", "-F", "--", value, *batch])
            for line in grep.stdout.splitlines():
                if ":" in line:
                    hit_commits.add(line.split(":", 1)[0])
        if hit_commits:
            samples = ",".join(sorted(commit[:12] for commit in hit_commits)[:10])
            print(f"HISTORY local-extra-forbidden#{idx}: commits={len(hit_commits)} samples={samples}")
        else:
            print(f"HISTORY local-extra-forbidden#{idx}: commits=0")


def github_api(path: str) -> object:
    proc = run(["gh", "api", path])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"gh api failed for {path}")
    return json.loads(proc.stdout)


def scan_github_issues(repo: str, extras: list[str]) -> int:
    print(f"== GitHub issues ({repo}) ==")
    issues: list[dict[str, object]] = []
    page = 1
    while True:
        page_items = github_api(f"/repos/{repo}/issues?state=all&per_page=100&page={page}")
        if not isinstance(page_items, list) or not page_items:
            break
        for item in page_items:
            if isinstance(item, dict) and "pull_request" not in item:
                issues.append(item)
        page += 1
    print(f"Issue count scanned: {len(issues)}")

    findings = 0
    for issue in issues:
        number = int(issue["number"])
        texts: list[tuple[str, str]] = [("title", str(issue.get("title") or "")), ("body", str(issue.get("body") or ""))]
        if int(issue.get("comments") or 0):
            comments = github_api(f"/repos/{repo}/issues/{number}/comments?per_page=100")
            if isinstance(comments, list):
                for comment in comments:
                    if isinstance(comment, dict):
                        texts.append((f"comment:{comment.get('id')}", str(comment.get("body") or "")))
        issue_hits: list[str] = []
        issue_snippets: list[tuple[str, str, str]] = []
        for location, text in texts:
            for name, rx in PATTERNS.items():
                if rx.search(text):
                    issue_hits.append(f"{location}:{name}")
                    for _, snippet in snippets(location, text, limit=1):
                        issue_snippets.append((location, name, snippet))
                        break
            for idx, value in enumerate(extras, 1):
                if value and value in text:
                    issue_hits.append(f"{location}:local-extra-forbidden#{idx}")
        if issue_hits:
            findings += 1
            print(f"ISSUE #{number} state={issue.get('state')} hits={';'.join(sorted(set(issue_hits)))}")
            for location, name, snippet in issue_snippets[:3]:
                print(f"  {location} {name}: {snippet}")
    if findings == 0:
        print("No GitHub issue pattern hits.")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-issues", action="store_true", help="Scan issue bodies/comments with gh api.")
    parser.add_argument("--repo", default=None, help="GitHub repo owner/name. Defaults to `gh repo view`.")
    args = parser.parse_args()

    files = tracked_files()
    extras = load_extra_forbidden()
    scan_docs(files)
    scan_commit_messages()
    scan_history_blobs(extras)

    if args.github_issues:
        repo = args.repo
        if repo is None:
            repo_proc = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
            if repo_proc.returncode != 0:
                print("ERROR: could not resolve GitHub repo; pass --repo owner/name", file=sys.stderr)
                return 2
            repo = repo_proc.stdout.strip()
        scan_github_issues(repo, extras)

    print("publication-audit: report complete (review findings; values above are redacted)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
