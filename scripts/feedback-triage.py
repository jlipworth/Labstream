#!/usr/bin/env python3
"""Maintainer helpers for incoming feedback. Dry-run by default; `--yes` writes to GitHub.

  label   Read open issues filed through the app's "Report a problem" form (label `via-app`)
          and add `platform:*` and `backend:*` labels from the form's "App and device" line.
  draft   Turn the newest private App Store Connect digest (scripts/asc-digest.py) into one
          private issue draft per TestFlight feedback item and App Store review.
  file    Create a GitHub issue from a draft the maintainer has rewritten.

Customer and tester text is private. `draft` writes only under the gitignored
artifacts/asc-digest/<date>/drafts/, and `file` refuses a draft whose public summary is
still empty and never sends anything below the draft's private marker. Stdout carries counts,
issue numbers, labels and paths only.

Examples:
  scripts/feedback-triage.py label              # show what would be labelled
  scripts/feedback-triage.py label --yes
  scripts/feedback-triage.py draft
  scripts/feedback-triage.py file artifacts/asc-digest/2026-11-14/drafts/feedback-01.md --yes
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
DIGEST_ROOT = REPO / "artifacts" / "asc-digest"
PRIVATE_MARKER = "<!-- PRIVATE: everything below this line stays on this Mac -->"
SUMMARY_PLACEHOLDER = "(rewrite the report in your own words; no names, emails, titles or addresses)"

# First match wins; visionOS before iOS because "visionOS" contains "iOS".
PLATFORM_RULES = (
    ("platform:visionos", re.compile(r"visionOS|RealityDevice|VISION_OS", re.I)),
    ("platform:tvos", re.compile(r"tvOS|AppleTV|TV_OS", re.I)),
    ("platform:macos", re.compile(r"macOS|\bMac\d|MacBook|Macmini|iMac|MAC_OS", re.I)),
    ("platform:ipados", re.compile(r"iPadOS|\biPad", re.I)),
    ("platform:ios", re.compile(r"\biOS\b|iPhone|\bIOS\b")),
)
BACKEND_RULES = (
    ("backend:plex", re.compile(r"\bPlex\b", re.I)),
    ("backend:jellyfin", re.compile(r"\bJellyfin\b", re.I)),
    ("backend:emby", re.compile(r"\bEmby\b", re.I)),
)


def environment_line(body: str) -> str:
    """The value under the form's "App and device" heading (GitHub renders `### Label`)."""
    match = re.search(r"^###\s+App and device\s*\n+(.+?)(?=\n###\s|\Z)", body or "", re.S | re.M)
    if not match:
        return ""
    value = match.group(1).strip()
    return "" if value == "_No response_" else value


def labels_for(environment: str) -> list[str]:
    labels = []
    for rules in (PLATFORM_RULES, BACKEND_RULES):
        for label, pattern in rules:
            if pattern.search(environment):
                labels.append(label)
                break
    return labels


def gh(*args: str, stdin: str | None = None) -> str:
    result = subprocess.run(["gh", *args], cwd=REPO, input=stdin, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"gh {args[0]} {args[1] if len(args) > 1 else ''} failed: {result.stderr.strip()[:300]}")
    return result.stdout


def command_label(args: argparse.Namespace) -> int:
    issues = json.loads(gh("issue", "list", "--label", "via-app", "--state", "open", "--limit", "200",
                           "--json", "number,body,labels"))
    changed = 0
    for issue in issues:
        have = {label["name"] for label in issue["labels"]}
        add = [label for label in labels_for(environment_line(issue["body"])) if label not in have]
        if not add:
            continue
        changed += 1
        print(f"#{issue['number']}: {'add' if args.yes else 'would add'} {', '.join(add)}")
        if args.yes:
            gh("issue", "edit", str(issue["number"]), "--add-label", ",".join(add))
    print(f"{len(issues)} open via-app issue(s), {changed} {'labelled' if args.yes else 'to label'}")
    return 0


def newest_digest() -> pathlib.Path | None:
    days = sorted(p for p in DIGEST_ROOT.glob("*/digest.json"))
    return days[-1] if days else None


def private_write(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)


def draft_text(*, source: str, labels: list[str], facts: list[str], private: list[str]) -> str:
    return "\n".join([
        "title: ",
        f"labels: {', '.join(labels)}",
        "",
        "## Summary",
        "",
        SUMMARY_PLACEHOLDER,
        "",
        "## Source",
        "",
        *[f"- {fact}" for fact in [f"Source: {source}", *facts]],
        "",
        PRIVATE_MARKER,
        "",
        *private,
        "",
    ])


def drafts_from(digest: dict) -> list[tuple[str, str]]:
    """(file stem, text) per feedback item and review. Public part: non-identifying facts only."""
    out = []
    for index, item in enumerate(digest.get("feedback", []), 1):
        platform = labels_for(str(item.get("platform", "")))
        kind = str(item.get("kind", "feedback"))
        labels = ["needs-triage", "source:testflight", *platform] + (["bug"] if "crash" in kind.lower() else [])
        facts = [f"Kind: {kind}", f"Build: {item.get('platform', '?')} {item.get('build', '?')}",
                 f"OS: {item.get('os', '?')}", f"Device: {item.get('device', '?')}",
                 f"Received: {str(item.get('created', '?'))[:10]}"]
        private = [f"Tester: {item.get('email') or 'no email'}", "", str(item.get("comment") or "(no comment)"),
                   *[f"file: {path}" for path in item.get("files", [])]]
        out.append((f"feedback-{index:02d}", draft_text(source="TestFlight feedback", labels=labels,
                                                        facts=facts, private=private)))
    for index, item in enumerate(digest.get("reviews", []), 1):
        labels = ["needs-triage", "source:review", *labels_for(str(item.get("platform", "")))]
        facts = [f"Rating: {item.get('rating', '?')} of 5",
                 f"Platform: {item.get('platform', '?')} {item.get('app_version') or ''}".rstrip(),
                 f"Received: {str(item.get('created', '?'))[:10]}"]
        private = [f"Reviewer: {item.get('nickname', '?')} ({item.get('territory', '?')})", "",
                   str(item.get("title") or ""), "", str(item.get("body") or "")]
        out.append((f"review-{index:02d}", draft_text(source="App Store review", labels=labels,
                                                      facts=facts, private=private)))
    return out


def command_draft(args: argparse.Namespace) -> int:
    path = pathlib.Path(args.digest) if args.digest else newest_digest()
    if path is None or not path.is_file():
        print("no digest found; run scripts/asc-digest.py first")
        return 1
    drafts = drafts_from(json.loads(path.read_text()))
    directory = path.parent / "drafts"
    for stem, text in drafts:
        private_write(directory / f"{stem}.md", text)
    print(f"{len(drafts)} draft(s) in {directory.relative_to(REPO) if directory.is_relative_to(REPO) else directory}")
    if drafts:
        print("rewrite each Summary and title, then: scripts/feedback-triage.py file <draft> --yes")
    return 0


def parse_draft(text: str) -> tuple[str, list[str], str]:
    """(title, labels, public body). Raises ValueError when the draft is not ready to post."""
    public = text.split(PRIVATE_MARKER, 1)[0]
    lines = public.splitlines()
    title = next((line[len("title:"):].strip() for line in lines if line.startswith("title:")), "")
    labels_line = next((line[len("labels:"):] for line in lines if line.startswith("labels:")), "")
    labels = [label.strip() for label in labels_line.split(",") if label.strip()]
    body = "\n".join(line for line in lines if not line.startswith(("title:", "labels:"))).strip()
    if not title:
        raise ValueError("the draft has no title")
    if SUMMARY_PLACEHOLDER in body:
        raise ValueError("the Summary is still the placeholder")
    summary, in_summary = [], False
    for line in body.splitlines():
        if line.startswith("## "):
            in_summary = line.strip() == "## Summary"
        elif in_summary:
            summary.append(line)
    if not "".join(summary).strip():
        raise ValueError("the Summary is empty")
    return title, labels, body + "\n"


def command_file(args: argparse.Namespace) -> int:
    try:
        title, labels, body = parse_draft(pathlib.Path(args.draft).read_text())
    except ValueError as error:
        print(f"not filed: {error}")
        return 1
    print(f"title: {title}\nlabels: {', '.join(labels) or '(none)'}\nbody: {len(body.splitlines())} public line(s)")
    if not args.yes:
        print("dry run; pass --yes to create the issue")
        return 0
    command = ["issue", "create", "--title", title, "--body-file", "-"]
    for label in labels:
        command += ["--label", label]
    print(gh(*command, stdin=body).strip().splitlines()[-1])
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    label = sub.add_parser("label", help="label via-app issues by platform and backend")
    label.add_argument("--yes", action="store_true", help="apply the labels")
    label.set_defaults(run=command_label)
    draft = sub.add_parser("draft", help="write private issue drafts from the newest digest")
    draft.add_argument("--digest", help="a digest.json other than the newest")
    draft.set_defaults(run=command_draft)
    file = sub.add_parser("file", help="create an issue from a rewritten draft")
    file.add_argument("draft")
    file.add_argument("--yes", action="store_true", help="create the issue")
    file.set_defaults(run=command_file)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
