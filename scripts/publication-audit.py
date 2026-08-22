#!/usr/bin/env python3
"""Audit publication surfaces without printing sensitive values.

The audit is conservative and privacy preserving. Text output contains only locations,
categories, and redacted snippets. JSON output is stable enough for CI and never contains the
configured forbidden values themselves.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
os.chdir(REPO)

DOC_SUFFIXES = (".md", ".yml", ".yaml")
DOC_ALWAYS = {"mkdocs.yml", "AGENTS.md", "CLAUDE.md", "SECURITY.md", "CODE_OF_CONDUCT.md"}
DOC_PREFIXES = (".github/", ".woodpecker/")
ALLOWLIST_PATH = Path("scripts/publication-audit-allowlist.json")
PLEX_TOKEN_HEADER = "X-Plex" + "-Token"
PLEX_TOKEN_ENV = "PLEX" + "_TOKEN"

PATTERNS: dict[str, tuple[re.Pattern[str], bool]] = {
    "home_path": (
        re.compile(r"/Users/(?!AuthenticateByName|Authenticate\b)[A-Za-z0-9._-]+|(?<![/A-Za-z0-9])/home/[A-Za-z0-9._-]+|/private/var/folders"),
        True,
    ),
    "private_lan_ip": (
        re.compile(r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"),
        True,
    ),
    "private_email": (
        re.compile(r"(?i)\b[A-Z0-9._%+-]+@(?!users\.noreply\.github\.com\b|noreply\.github\.com\b|example\.(?:com|org|net|invalid)\b|github\.com\b)[A-Z0-9.-]+\.[A-Z]{2,}\b"),
        True,
    ),
    "plex_token_marker": (
        re.compile(re.escape(PLEX_TOKEN_HEADER) + "|" + re.escape(PLEX_TOKEN_ENV), re.IGNORECASE),
        False,
    ),
    "likely_raw_token": (
        re.compile(r"(?i)(bearer\s+[a-z0-9._~+/-]{12,}|token\s*[:=]\s*[a-z0-9._~+/-]{12,}|x-plex-token[=:][a-z0-9._~+/-]{4,})"),
        True,
    ),
}

# Short, hex-only live Emby Connect values evade generic entropy scanners. Keep this narrow to the
# wire-shape regression fixture that previously carried live-verified values.
EMBY_CONNECT_LIVE_FIXTURE = re.compile(
    r'(?i)"(?:AccessKey|AccessToken|UserId|LocalUserId|SystemId|Id)"\s*:\s*"[0-9a-f]{8,}"'
)


@dataclass(frozen=True)
class Finding:
    surface: str
    location: str
    category: str
    severity: str
    allowlisted: bool
    reason: str | None
    snippet: str


class Audit:
    def __init__(self, allowlist: list[dict[str, str]], extras: list[str]) -> None:
        self.allowlist = allowlist
        self.extras = sorted((value for value in extras if value), key=len, reverse=True)
        self.findings: list[Finding] = []
        self.summaries: list[dict[str, Any]] = []
        self.scanned: dict[str, int] = {}

    def allow_reason(self, surface: str, location: str, category: str) -> str | None:
        for entry in self.allowlist:
            if entry.get("category") != category or entry.get("surface") != surface:
                continue
            if fnmatch.fnmatch(location, entry.get("location", "")):
                return entry.get("reason") or "documented allowlist"
        return None

    def add_text(self, surface: str, location: str, text: str, *, edited: bool = False) -> None:
        location = redact(location, self.extras)
        for index, value in enumerate(self.extras, 1):
            if value in text:
                self.findings.append(Finding(
                    surface=surface, location=location,
                    category=f"configured_forbidden_value#{index}", severity="blocker",
                    allowlisted=False, reason=None, snippet="<redacted configured value>",
                ))
        for category, (rx, blocking) in PATTERNS.items():
            for match in rx.finditer(text):
                reason = self.allow_reason(surface, location, category)
                is_blocker = blocking and reason is None
                start = max(0, match.start() - 70)
                end = min(len(text), match.end() + 140)
                self.findings.append(Finding(
                    surface=surface,
                    location=location,
                    category=category,
                    severity="blocker" if is_blocker else "review",
                    allowlisted=reason is not None,
                    reason=reason,
                    snippet=redact(text[start:end], self.extras)[:240],
                ))
        if edited:
            reason = self.allow_reason(surface, location, "edit_history_unverified")
            self.findings.append(Finding(
                surface=surface,
                location=location,
                category="edit_history_unverified",
                severity="review" if reason else "blocker",
                allowlisted=reason is not None,
                reason=reason,
                snippet="<edited item requires revision-history review>",
            ))

    @property
    def blockers(self) -> int:
        return sum(f.severity == "blocker" and not f.allowlisted for f in self.findings)


def run(args: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def redact(text: str, extras: list[str] | None = None) -> str:
    for value in sorted((extras or []), key=len, reverse=True):
        text = text.replace(value, "<configured-forbidden-value>")
    text = re.sub(r"/Users/[A-Za-z0-9._-]+", "/Users/<user>", text)
    text = re.sub(r"/home/[A-Za-z0-9._-]+", "/home/<user>", text)
    text = re.sub(r"/private/var/folders/[^\s`)]+", "/private/var/folders/<redacted>", text)
    text = re.sub(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", "<redacted-email>", text)
    text = re.sub(
        r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b",
        "<private-ip>", text,
    )
    text = re.sub(r"(?i)(" + re.escape(PLEX_TOKEN_HEADER) + r"(?:=|: ?))[^&\s`)]+", r"\1<redacted>", text)
    text = re.sub(r"(?i)(" + re.escape(PLEX_TOKEN_ENV) + r"=)[^\s`)]+", r"\1<redacted>", text)
    text = re.sub(r"(?i)(bearer\s+)[a-z0-9._~+/-]{12,}", r"\1<redacted>", text)
    text = re.sub(r"(?i)(token\s*[:=]\s*)[a-z0-9._~+/-]{12,}", r"\1<redacted>", text)
    return " ".join(text.split())


def load_allowlist(path: Path = ALLOWLIST_PATH) -> list[dict[str, str]]:
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("version") != 1 or not isinstance(data.get("entries"), list):
        raise ValueError(f"invalid publication audit allowlist: {path}")
    entries: list[dict[str, str]] = []
    for entry in data["entries"]:
        if not isinstance(entry, dict) or not all(entry.get(k) for k in ("surface", "location", "category", "reason")):
            raise ValueError(f"invalid publication audit allowlist entry: {entry!r}")
        entries.append({k: str(entry[k]) for k in ("surface", "location", "category", "reason")})
    return entries


def load_extra_forbidden() -> list[str]:
    path = Path("scripts/ci-hygiene.local")
    if not path.exists():
        return []
    return [line for line in path.read_text(encoding="utf-8", errors="ignore").splitlines()
            if line and not line.startswith("#")]


def tracked_files(target: str) -> list[str]:
    return run(["git", "ls-tree", "-r", "--name-only", target], check=True).stdout.splitlines()


def scan_tracked(audit: Audit, files: list[str], target: str) -> None:
    docs = [p for p in files if p.endswith(DOC_SUFFIXES) or p in DOC_ALWAYS or p.startswith(DOC_PREFIXES)]
    audit.scanned["tracked_documentation_files"] = len(docs)
    for path in docs:
        proc = run(["git", "show", f"{target}:{path}"])
        if proc.returncode != 0:
            continue
        data = proc.stdout.encode("utf-8", errors="ignore")
        if b"\0" in data[:4096]:
            continue
        audit.add_text("tracked", path, proc.stdout)

    fixture = "PMSKit/Tests/PMSKitTests/EmbyConnectTests.swift"
    if fixture in files:
        proc = run(["git", "show", f"{target}:{fixture}"])
        if proc.returncode == 0:
            for _ in EMBY_CONNECT_LIVE_FIXTURE.finditer(proc.stdout):
                audit.findings.append(Finding(
                    surface="tracked", location=fixture,
                    category="live_credential_fixture", severity="blocker",
                    allowlisted=False, reason=None,
                    snippet="<live-shaped Emby Connect fixture value withheld>",
                ))


def scan_commit_messages(audit: Audit) -> None:
    records = run(["git", "log", "--all", "--format=%H%x00%s%x00%b%x00END"], check=True).stdout.split("\x00END")
    audit.scanned["commit_messages"] = 0
    for record in records:
        if not record.strip():
            continue
        parts = record.split("\x00", 2)
        if len(parts) != 3:
            continue
        sha, subject, body = parts
        audit.scanned["commit_messages"] += 1
        audit.add_text("commit_message", sha[:12], f"{subject}\n{body}")


def scan_author_emails(audit: Audit) -> None:
    lines = run(["git", "log", "--all", "--format=%H%x00%ae"], check=True).stdout.splitlines()
    audit.scanned["commit_author_records"] = len(lines)
    seen: set[str] = set()
    for line in lines:
        if "\x00" not in line:
            continue
        sha, email = line.split("\x00", 1)
        normalized = email.strip().lower()
        if normalized in seen:
            continue
        seen.add(normalized)
        if normalized.endswith("@users.noreply.github.com") or normalized in {"noreply@anthropic.com"}:
            continue
        reason = audit.allow_reason("git_author", "author-email", "private_email")
        audit.findings.append(Finding(
            surface="git_author", location=sha[:12], category="private_email",
            severity="review" if reason else "blocker", allowlisted=reason is not None,
            reason=reason, snippet="<redacted-email>",
        ))


def scan_history(audit: Audit, extras: list[str]) -> None:
    commits = run(["git", "rev-list", "--all"], check=True).stdout.splitlines()
    audit.scanned["historical_commits"] = len(commits)
    patterns = {
        "home_path": r"/Users/(?!AuthenticateByName|Authenticate\b)[A-Za-z0-9._-]+|(?<![/A-Za-z0-9])/home/[A-Za-z0-9._-]+|/private/var/folders",
        "private_lan_ip": r"\b(10\.([0-9]{1,3}\.){2}[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3})\b",
        "plex_token_marker": re.escape(PLEX_TOKEN_HEADER) + "|" + re.escape(PLEX_TOKEN_ENV),
        "likely_raw_token": r"(?i)(bearer\s+[a-z0-9._~+/-]{12,}|token\s*[:=]\s*[a-z0-9._~+/-]{12,}|x-plex-token[=:][a-z0-9._~+/-]{4,})",
    }
    for category, pattern in patterns.items():
        hit_commits: set[str] = set()
        hit_files: Counter[str] = Counter()
        for i in range(0, len(commits), 60):
            grep = run(["git", "grep", "-l", "-I", "-P", pattern, *commits[i:i + 60]])
            for line in grep.stdout.splitlines():
                if ":" in line:
                    commit, path = line.split(":", 1)
                    hit_commits.add(commit)
                    hit_files[path] += 1
        audit.summaries.append({
            "surface": "history", "category": category,
            "commit_count": len(hit_commits), "file_count": len(hit_files),
        })
        # Token-shaped syntax is deliberately broad and common in source declarations. Retain
        # it as a review summary here; Gitleaks is the independent value-aware blocking scanner.
        if category == "likely_raw_token":
            continue
        for path in sorted(hit_files):
            reason = audit.allow_reason("history", path, category)
            blocking = PATTERNS.get(category, (None, True))[1]
            audit.findings.append(Finding(
                surface="history", location=redact(path, audit.extras), category=category,
                severity="blocker" if blocking and reason is None else "review",
                allowlisted=reason is not None, reason=reason,
                snippet="<historical match; value withheld>",
            ))
    audit.scanned["local_forbidden_values"] = len(extras)
    for index, value in enumerate(extras, 1):
        hit_commits: set[str] = set()
        for i in range(0, len(commits), 80):
            grep = run(["git", "grep", "-l", "-I", "-F", "--", value, *commits[i:i + 80]])
            for line in grep.stdout.splitlines():
                if ":" in line:
                    hit_commits.add(line.split(":", 1)[0])
        if hit_commits:
            audit.findings.append(Finding(
                surface="history", location=f"local-extra-forbidden#{index}",
                category="configured_forbidden_value", severity="blocker", allowlisted=False,
                reason=None, snippet=f"<redacted; present in {len(hit_commits)} commit(s)>",
            ))


def github_api(path: str) -> Any:
    proc = run(["gh", "api", path])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"gh api failed for {path}")
    return json.loads(proc.stdout)


def paged_github(path: str) -> list[dict[str, Any]]:
    separator = "&" if "?" in path else "?"
    page = 1
    items: list[dict[str, Any]] = []
    while True:
        batch = github_api(f"{path}{separator}per_page=100&page={page}")
        if not isinstance(batch, list) or not batch:
            break
        items.extend(item for item in batch if isinstance(item, dict))
        page += 1
    return items


def is_edited(item: dict[str, Any]) -> bool:
    created = str(item.get("created_at") or "")
    updated = str(item.get("updated_at") or "")
    return bool(created and updated and created != updated)


def scan_github(audit: Audit, repo: str, extras: list[str]) -> None:
    items = paged_github(f"/repos/{repo}/issues?state=all")
    audit.scanned["github_issues_and_prs"] = len(items)
    comment_count = 0
    review_count = 0
    for item in items:
        number = int(item["number"])
        kind = "pr" if "pull_request" in item else "issue"
        # GitHub updates issue/PR `updated_at` for comments and state changes, so it is not an
        # edit-history signal for the title/body themselves.
        audit.add_text("github", f"{kind}:{number}:title", str(item.get("title") or ""))
        audit.add_text("github", f"{kind}:{number}:body", str(item.get("body") or ""))
        comments = paged_github(f"/repos/{repo}/issues/{number}/comments")
        comment_count += len(comments)
        for comment in comments:
            audit.add_text("github", f"{kind}:{number}:comment:{comment.get('id')}",
                           str(comment.get("body") or ""), edited=is_edited(comment))
        if kind == "pr":
            reviews = paged_github(f"/repos/{repo}/pulls/{number}/reviews")
            review_comments = paged_github(f"/repos/{repo}/pulls/{number}/comments")
            review_count += len(reviews) + len(review_comments)
            for review in reviews:
                audit.add_text("github", f"pr:{number}:review:{review.get('id')}",
                               str(review.get("body") or ""), edited=is_edited(review))
            for comment in review_comments:
                audit.add_text("github", f"pr:{number}:review-comment:{comment.get('id')}",
                               str(comment.get("body") or ""), edited=is_edited(comment))
    audit.scanned["github_issue_comments"] = comment_count
    audit.scanned["github_reviews_and_review_comments"] = review_count
    releases = paged_github(f"/repos/{repo}/releases?")
    audit.scanned["github_releases"] = len(releases)
    for release in releases:
        audit.add_text("github", f"release:{release.get('id')}:name", str(release.get("name") or ""), edited=is_edited(release))
        audit.add_text("github", f"release:{release.get('id')}:body", str(release.get("body") or ""), edited=is_edited(release))
def render_text(audit: Audit) -> str:
    lines = ["== publication audit =="]
    for key, value in sorted(audit.scanned.items()):
        lines.append(f"SCANNED {key}={value}")
    grouped = Counter((f.surface, f.category, f.severity, f.allowlisted) for f in audit.findings)
    for (surface, category, severity, allowlisted), count in sorted(grouped.items()):
        lines.append(f"SUMMARY surface={surface} category={category} severity={severity} allowlisted={str(allowlisted).lower()} count={count}")
    for finding in audit.findings:
        allowance = f" allowlisted={finding.reason}" if finding.allowlisted else ""
        lines.append(f"FINDING {finding.severity} {finding.surface} {finding.location} {finding.category}{allowance}")
        lines.append(f"  {finding.snippet}")
    for summary in audit.summaries:
        lines.append("HISTORY " + " ".join(f"{key}={value}" for key, value in summary.items() if key != "surface"))
    lines.append(f"publication-audit: blockers={audit.blockers} findings={len(audit.findings)}")
    return "\n".join(lines) + "\n"


def render_json(audit: Audit, repo: str | None, target: str) -> str:
    payload = {
        "schema": "publication-audit/v1",
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "repository": repo,
        "targetSha": target,
        "status": "block" if audit.blockers else "pass",
        "scanned": audit.scanned,
        "counts": {"findings": len(audit.findings), "blockers": audit.blockers},
        "findings": [asdict(f) for f in audit.findings],
        "historySummaries": audit.summaries,
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-issues", action="store_true", help="Scan issues, PRs, comments, reviews, and releases with gh api.")
    parser.add_argument("--repo", default=None, help="GitHub repo owner/name. Defaults to gh repo view.")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--output", type=Path, default=None, help="Write the report to a file instead of stdout.")
    parser.add_argument("--target", default="HEAD", help="Exact commit to scan for the current-tree surface (default: HEAD).")
    args = parser.parse_args()
    extras: list[str] = []
    try:
        allowlist = load_allowlist()
        extras = load_extra_forbidden()
        target_proc = run(["git", "rev-parse", "--verify", f"{args.target}^{{commit}}"])
        if target_proc.returncode != 0:
            raise RuntimeError(f"invalid audit target: {args.target}")
        target = target_proc.stdout.strip()
        audit = Audit(allowlist, extras)
        scan_tracked(audit, tracked_files(target), target)
        scan_commit_messages(audit)
        scan_author_emails(audit)
        scan_history(audit, extras)
        repo = args.repo
        if args.github_issues:
            if repo is None:
                proc = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
                if proc.returncode != 0:
                    raise RuntimeError("could not resolve GitHub repo; pass --repo owner/name")
                repo = proc.stdout.strip()
            scan_github(audit, repo, extras)
        report = render_json(audit, repo, target) if args.format == "json" else render_text(audit)
        if any(value and value in report for value in extras):
            raise RuntimeError("configured forbidden value survived report redaction")
        if args.output:
            args.output.write_text(report, encoding="utf-8")
        else:
            sys.stdout.write(report)
        return 1 if audit.blockers else 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"publication-audit: operational error: {redact(str(exc), extras)}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
