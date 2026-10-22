#!/usr/bin/env python3
"""Local checkpoints, validation/docs receipts, and a review-finding ledger. No remote writes."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile

from workflow_common import WorkflowError, git, print_json, repository_root, text, source_fingerprint


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def load(path):
    if not path.exists():
        return {"version": 1, "checkpoint": None, "receipts": [], "findings": []}
    try:
        state = json.loads(path.read_text())
        if state.get("version") != 1 or not all(isinstance(state.get(k), list) for k in ("receipts", "findings")):
            raise ValueError()
        if state.get("checkpoint") is not None and not isinstance(state["checkpoint"], dict):
            raise ValueError()
        for row in state["receipts"]:
            if not isinstance(row, dict) or not all(k in row for k in ("head", "name", "status", "kind")):
                raise ValueError()
        ids = set()
        for row in state["findings"]:
            if not isinstance(row, dict) or not isinstance(row.get("id"), str) or row["id"] in ids or row.get("status") not in {"open", "fixed", "verified", "deferred", "rejected"} or not isinstance(row.get("history"), list):
                raise ValueError()
            ids.add(row["id"])
        return state
    except (ValueError, AttributeError) as exc:
        raise WorkflowError("invalid workflow state; refusing to overwrite it") from exc


def save(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".workflow-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle, indent=2)
            handle.write("\n")
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def evidence_path(value, root):
    path = Path(value).expanduser()
    path = path if path.is_absolute() else root / path
    if not path.exists():
        raise WorkflowError("evidence path does not exist")
    return str(path.resolve())


def update(state, args, root, head):
    if args.command == "checkpoint":
        state["checkpoint"] = {"goal": args.goal, "next_action": args.next_action, "head": head,
                               "fingerprint": source_fingerprint(root),
                               "branch": git("branch", "--show-current", cwd=root),
                               "base": args.base, "issues": args.issue, "prs": args.pr,
                               "authorized": args.authorized, "remaining_gates": args.gate,
                               "updated_at": timestamp()}
    elif args.command == "receipt":
        evidence = evidence_path(args.evidence, root) if args.evidence else None
        if args.status == "passed" and not evidence:
            raise WorkflowError("passed receipts require existing evidence")
        if args.kind == "docs" and args.status == "not-needed" and not args.note:
            raise WorkflowError("docs not-needed requires a reason")
        if args.kind == "validation" and args.status == "not-needed":
            raise WorkflowError("use not-run or blocked for validation not performed")
        state["receipts"].append({"kind": args.kind, "name": args.name, "status": args.status,
                                   "head": head, "fingerprint": source_fingerprint(root), "evidence": evidence, "note": args.note,
                                   "updated_at": timestamp()})
    elif args.command == "finding":
        row = next((r for r in state["findings"] if r["id"] == args.id), None)
        if args.action == "add":
            if row:
                raise WorkflowError("finding ID already exists; IDs must survive review rounds")
            if not args.summary:
                raise WorkflowError("new findings require a summary")
            row = {"id": args.id, "summary": args.summary, "severity": args.severity,
                   "status": "open", "history": []}
            state["findings"].append(row)
        elif row is None:
            raise WorkflowError("unknown finding ID")
        if args.action == "set":
            if not args.status or not args.note:
                raise WorkflowError("finding updates require status and reason")
            if args.status in {"fixed", "verified"} and not args.commit:
                raise WorkflowError("fixed/verified findings require a resolution commit")
            commit = git("rev-parse", "--verify", "--end-of-options", f"{args.commit}^{{commit}}", cwd=root) if args.commit else None
            if commit:
                git("merge-base", "--is-ancestor", commit, head, cwd=root)
            evidence = evidence_path(args.evidence, root) if args.evidence else None
            if args.status == "verified" and not evidence:
                raise WorkflowError("verified findings require review evidence")
            row.update(status=args.status, resolution_commit=commit, evidence=evidence,
                       fingerprint=source_fingerprint(root))
        row["history"].append({"status": row["status"], "head": head, "note": args.note,
                               "resolution_commit": row.get("resolution_commit"), "evidence": row.get("evidence"),
                               "fingerprint": row.get("fingerprint"), "updated_at": timestamp()})
    return state


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--file", type=Path, help="Default: build/workflow/state.json in this worktree")
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("checkpoint")
    c.add_argument("--goal", required=True)
    c.add_argument("--next-action", required=True)
    c.add_argument("--base", default="main")
    c.add_argument("--issue", type=int, action="append", default=[])
    c.add_argument("--pr", type=int, action="append", default=[])
    c.add_argument("--authorized", action="append", default=[])
    c.add_argument("--gate", action="append", default=[])
    r = sub.add_parser("receipt")
    r.add_argument("kind", choices=["validation", "docs"])
    r.add_argument("--name", required=True)
    r.add_argument("--status", required=True, choices=["passed", "failed", "blocked", "not-run", "not-needed"])
    r.add_argument("--evidence")
    r.add_argument("--note", default="")
    f = sub.add_parser("finding")
    f.add_argument("action", choices=["add", "set"])
    f.add_argument("id")
    f.add_argument("--summary")
    f.add_argument("--severity", choices=["high", "medium", "low"], default="medium")
    f.add_argument("--status", choices=["open", "fixed", "verified", "deferred", "rejected"])
    f.add_argument("--commit")
    f.add_argument("--evidence")
    f.add_argument("--note", default="")
    sub.add_parser("show")
    args = p.parse_args(argv)
    try:
        root = repository_root()
        path = (args.file or root / "build/workflow/state.json").resolve()
        head = git("rev-parse", "HEAD", cwd=root)
        if args.command == "show":
            state = load(path)
        else:
            if path.is_relative_to(root):
                try:
                    git("check-ignore", "--quiet", "--", str(path), cwd=root)
                except WorkflowError:
                    raise WorkflowError("store must be outside the repository or gitignored")
            # Serialize mutations; readers only observe complete atomic snapshots.
            path.parent.mkdir(parents=True, exist_ok=True)
            import fcntl
            with Path(str(path) + ".lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                state = load(path)
                save(path, update(state, args, root, head))
        fingerprint = source_fingerprint(root)
        result = dict(state, current_head=head, current_fingerprint=fingerprint)
        result["checkpoint_stale"] = bool(state["checkpoint"] and state["checkpoint"].get("fingerprint") != fingerprint)
        result["receipts"] = [dict(r, stale=r.get("fingerprint") != fingerprint) for r in state["receipts"]]
        result["findings"] = [dict(r, review_stale=r["status"] == "verified" and r.get("fingerprint") != fingerprint) for r in state["findings"]]
        result["pending_review"] = [r["id"] for r in result["findings"] if r["status"] in {"open", "fixed"} or r["review_stale"]]
        print_json(result)
        return 0
    except (WorkflowError, OSError) as exc:
        print(f"workflow-state: {exc if isinstance(exc, WorkflowError) else type(exc).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
