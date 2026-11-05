#!/usr/bin/env python3
"""Read-only workspace, PR, issue and repository-recorded release snapshot."""
import argparse
import json
from pathlib import Path
import re
import sys

from workflow_common import GitHub, WorkflowError, git, issue_summary, print_json, repository_name, repository_root, text, source_fingerprint


def worktrees(root):
    raw = git("worktree", "list", "--porcelain", "-z", cwd=root)
    records = []
    for block in raw.split("\0\0"):
        fields = dict(part.split(" ", 1) if " " in part else (part, True)
                      for part in block.split("\0") if part)
        if "worktree" not in fields:
            continue
        path = Path(fields["worktree"])
        row = {"path": str(path), "head": fields.get("HEAD"),
               "branch": str(fields.get("branch", "detached")).removeprefix("refs/heads/")}
        try:
            row["dirty"] = bool(git("status", "--porcelain", cwd=path))
            row["recent_commits"] = [dict(zip(("sha", "subject"), line.split("\t", 1)))
                                     for line in git("log", "-5", "--format=%H%x09%s", cwd=path).splitlines()]
            row["issue_candidates"] = sorted({int(n) for c in row["recent_commits"]
                                               for n in re.findall(r"#(\d+)", c["subject"])})
            try:
                row["upstream"] = git("rev-parse", "--abbrev-ref", "@{upstream}", cwd=path)
                ahead, behind = git("rev-list", "--left-right", "--count", "HEAD...@{upstream}", cwd=path).split()
                row.update(ahead=int(ahead), behind=int(behind))
            except WorkflowError:
                row["upstream"] = None
            state_file = path / "build/workflow/state.json"
            if state_file.exists():
                state = json.loads(state_file.read_text())
                fingerprint = source_fingerprint(path)
                row["checkpoint"] = state.get("checkpoint")
                row["receipts"] = [dict(r, stale=r.get("fingerprint") != fingerprint) for r in state.get("receipts", [])]
                row["open_findings"] = [f for f in state.get("findings", []) if f.get("status") in {"open", "fixed"} or (f.get("status") == "verified" and f.get("fingerprint") != fingerprint)]
                row["checkpoint_stale"] = bool(state.get("checkpoint") and state["checkpoint"].get("fingerprint") != fingerprint)
            release = path / "docs/RELEASES.md"
            if release.exists():
                # This is checked-in historical evidence, never a live ASC assertion.
                row["recorded_release_excerpt"] = "\n".join(release.read_text().splitlines()[:55])
        except (WorkflowError, OSError, ValueError, AttributeError, TypeError, KeyError) as exc:
            row["error"] = str(exc) if isinstance(exc, WorkflowError) else "local evidence unreadable"
        records.append(row)
    return records


def snapshot(root, client=None, issue_numbers=()):
    rows = worktrees(root)
    result = {"worktrees": rows, "github": "offline", "errors": [],
              "release_evidence": "repository-recorded, not live App Store Connect state", "read_only": True}
    if client is None:
        return result
    try:
        prs = client.pages(f"repos/{client.repo}/pulls?state=all&sort=updated&direction=desc", max_pages=5)
        branches = {r["branch"] for r in rows}
        selected = [p for p in prs if p["state"] == "open" or p["head"]["ref"] in branches]
        result["pull_requests"] = [{"number": p["number"], "title": p["title"], "state": p["state"],
                                     "merged": bool(p.get("merged_at")), "url": p["html_url"],
                                     "branch": p["head"]["ref"], "head": p["head"]["sha"],
                                     "base": p["base"]["ref"]} for p in selected]
        numbers = set(issue_numbers)
        for row in rows:
            numbers.update(row.get("issue_candidates", []))
            numbers.update((row.get("checkpoint") or {}).get("issues", []))
        for pr in selected:
            # Explicit references are candidates, not proof the PR satisfies the issue.
            numbers.update(int(n) for n in re.findall(r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", pr.get("body") or "", re.I))
        result["issues"] = []
        result["reference_pull_requests"] = []
        for n in sorted(numbers):
            reference = client.issue(n, allow_pull_request=True)
            if "pull_request" in reference:
                result["reference_pull_requests"].append({"number": n, "url": reference["html_url"]})
                continue
            issue = issue_summary(reference)
            issue["reported_unchecked_items"] = re.findall(r"(?m)^\s*- \[ \] (.+)$", issue["body"])
            result["issues"].append(issue)
        for row in rows:
            row["pull_requests"] = [p["number"] for p in result["pull_requests"] if p["branch"] == row["branch"]]
        result["github"] = "read"
    except WorkflowError as exc:
        result["github"] = "unavailable"
        result["errors"].append(str(exc))
    return result


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--offline", action="store_true")
    p.add_argument("--repo")
    p.add_argument("--issue", type=int, action="append", default=[])
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    try:
        root = repository_root()
        result = snapshot(root, None if args.offline else GitHub(args.repo or repository_name(root)), args.issue)
        if args.json:
            print_json(result)
        else:
            for row in result["worktrees"]:
                print(text(f"{row['branch']} @ {row['head']} {'DIRTY' if row.get('dirty') else 'clean'}\n  {row['path']}"))
                print(text(f"  upstream={row.get('upstream')} ahead={row.get('ahead', '?')} behind={row.get('behind', '?')} PRs={row.get('pull_requests', [])} issue candidates={row.get('issue_candidates', [])}"))
                if row.get("checkpoint"):
                    print(text(f"  next={row['checkpoint'].get('next_action')} checkpoint_stale={row['checkpoint_stale']}"))
                for receipt in row.get("receipts", []):
                    print(text(f"  receipt: {receipt['name']} {receipt['status']} stale={receipt['stale']} head={receipt['head']}"))
                if row.get("open_findings"):
                    print(text("  Pending review: " + ", ".join(f["id"] for f in row["open_findings"])))
                if row.get("error"):
                    print(text(f"  Local error: {row['error']}"))
                if row.get("recorded_release_excerpt"):
                    highlights = [line.strip() for line in row["recorded_release_excerpt"].splitlines() if "build " in line.lower()][:3]
                    print(text("  Recorded release evidence (not live ASC): " + " / ".join(highlights)))
            for pr in result.get("pull_requests", []):
                print(text(f"PR #{pr['number']} {pr['state']} merged={pr['merged']} {pr['branch']} -> {pr['base']} {pr['url']}"))
            for issue in result.get("issues", []):
                print(text(f"Issue #{issue['number']} {issue['state']} {issue['title']}\n  Body checklist (may lag comments): {issue['reported_unchecked_items']}"))
                for comment in issue["comments"][-2:]:
                    print(text(f"  Recent comment: {comment['body']}"))
            for error in result["errors"]:
                print(f"GitHub unavailable: {error}", file=sys.stderr)
        return 2 if result["errors"] or any("error" in row for row in result["worktrees"]) else 0
    except WorkflowError as exc:
        print(f"workspace-status: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
