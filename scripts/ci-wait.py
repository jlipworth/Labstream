#!/usr/bin/env python3
"""Wait on exact-commit GitHub statuses/checks, including mirrored Woodpecker results."""
import argparse
import math
import re
import sys
import time

from workflow_common import DeadlineExceeded, GitHub, WorkflowError, endpoint_component, git, print_json, repository_name, repository_root

DEFAULT_REQUIRED = ["ci/woodpecker/push/hygiene", "ci/woodpecker/push/pmskit"]


def evaluate(sha, statuses, checks, required):
    if not isinstance(statuses, list) or not isinstance(checks, list):
        raise WorkflowError("invalid CI inventory")
    if any(not isinstance(r, dict) or not isinstance(r.get("context"), str) or not isinstance(r.get("id"), int) for r in statuses):
        raise WorkflowError("invalid status record")
    if any(not isinstance(r, dict) or not isinstance(r.get("name"), str) or not isinstance(r.get("id"), int) for r in checks):
        raise WorkflowError("invalid check record")
    if not required:
        raise WorkflowError("at least one required context is necessary")
    latest = {}
    for row in statuses:
        key = row["context"]
        if key not in latest or row.get("id", 0) > latest[key].get("id", 0):
            latest[key] = row
    for row in checks:
        if row.get("head_sha") != sha:
            raise WorkflowError("check run belongs to a different commit")
        key = row["name"]
        if key in latest and "context" in latest[key]:
            raise WorkflowError("ambiguous status/check name; choose distinct required contexts")
        if key in latest and latest[key].get("app", {}).get("id") != row.get("app", {}).get("id"):
            raise WorkflowError("multiple check providers use the same required name")
        if key not in latest or row.get("id", 0) > latest[key].get("id", 0):
            latest[key] = row
    states = {}
    for name in required:
        row = latest.get(name)
        if row is None:
            states[name] = "missing"
        elif "context" in row:
            states[name] = row.get("state")
        else:
            states[name] = row.get("conclusion") if row.get("status") == "completed" else "pending"
    if any(s in {"failure", "error", "timed_out", "action_required", "startup_failure"} for s in states.values()):
        return 1, states
    if any(s in {"cancelled", "skipped", "neutral", "stale"} for s in states.values()):
        return 3, states
    if all(s == "success" for s in states.values()):
        return 0, states
    if any(s not in {"success", "pending", "missing", "queued", "in_progress", "waiting", "requested"} for s in states.values()):
        raise WorkflowError("unrecognized CI state")
    return None, states


def snapshot(client, sha, branch, required):
    ref = client.get(f"repos/{client.repo}/git/ref/heads/{endpoint_component(branch)}")
    if not isinstance(ref, dict) or not isinstance(ref.get("object"), dict):
        raise WorkflowError("invalid branch response")
    if ref["object"].get("sha") != sha:
        return 3, {"branch": "head differs from requested commit; not substituting it"}
    status = client.get(f"repos/{client.repo}/commits/{sha}/status")
    if not isinstance(status, dict) or status.get("sha") != sha:
        raise WorkflowError("status response belongs to a different commit")
    statuses = client.pages(f"repos/{client.repo}/commits/{sha}/statuses")
    checks = []
    for page in range(1, 21):
        batch = client.get(f"repos/{client.repo}/commits/{sha}/check-runs?per_page=100&page={page}")
        if not isinstance(batch, dict) or not isinstance(batch.get("check_runs"), list):
            raise WorkflowError("invalid check-run response")
        checks.extend(batch["check_runs"])
        if len(batch["check_runs"]) < 100:
            break
    else:
        raise WorkflowError("check-run pagination limit reached")
    return evaluate(sha, statuses, checks, required)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--commit", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--repo")
    p.add_argument("--require", action="append", help="Exact required context; repeatable. Defaults to Woodpecker push hygiene and PMSKit.")
    p.add_argument("--timeout", type=float, default=600)
    p.add_argument("--interval", type=float, default=10)
    p.add_argument("--once", action="store_true")
    args = p.parse_args(argv)
    try:
        if not all(math.isfinite(v) and v > 0 for v in (args.timeout, args.interval)):
            raise WorkflowError("timeout and interval must be positive")
        root = repository_root()
        sha = git("rev-parse", "--verify", "--end-of-options", f"{args.commit}^{{commit}}", cwd=root)
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise WorkflowError("commit must resolve to a full SHA")
        client = GitHub(args.repo or repository_name(root))
        deadline = time.monotonic() + args.timeout
        client.deadline = deadline
        while True:
            code, states = snapshot(client, sha, args.branch, args.require or DEFAULT_REQUIRED)
            print_json({"commit": sha, "branch": args.branch, "states": states,
                        "result": "pending" if code is None else {0: "passed", 1: "failed", 3: "unverified"}[code]})
            if code is not None:
                return code
            if args.once or time.monotonic() >= deadline:
                return 4
            time.sleep(min(args.interval, max(0, deadline - time.monotonic())))
    except DeadlineExceeded as exc:
        print(f"ci-wait: {exc}", file=sys.stderr)
        return 4
    except WorkflowError as exc:
        print(f"ci-wait: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
