#!/usr/bin/env python3
"""Read-only GitHub issue search, including comments and recently closed issues."""
import argparse
from datetime import datetime, timedelta, timezone
import difflib
import re
import sys
from urllib.parse import urlencode

from workflow_common import GitHub, WorkflowError, issue_summary, print_json, repository_name, repository_root, text


def words(value):
    return set(re.findall(r"[a-z0-9]+", value.lower()))


def score(query, value):
    a, b = words(query), words(value)
    return len(a & b) / max(1, len(a)) + difflib.SequenceMatcher(None, query.lower(), value.lower()).ratio()


def find(client, query, closed_days=90, limit=8):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=closed_days)).date().isoformat()
    rows = client.pages(f"repos/{client.repo}/issues?state=all&since={cutoff}&sort=updated&direction=desc")
    # since= applies to updates: include all open issues separately, including dormant ones.
    opened = client.pages(f"repos/{client.repo}/issues?state=open")
    inventory = {r["number"]: r for r in rows + opened if "pull_request" not in r and
                 (r.get("state") == "open" or (r.get("closed_at") or "")[:10] >= cutoff)}
    comment_matches = set()
    for state in ("is:open", f"is:closed closed:>={cutoff}"):
        terms = " ".join(sorted(words(query)))
        if not terms:
            raise WorkflowError("query must contain words")
        q = f"repo:{client.repo} is:issue {state} in:comments {terms}"
        response = client.get("search/issues?" + urlencode({"q": q, "per_page": 100}))
        if not isinstance(response, dict) or response.get("incomplete_results") or response.get("total_count", 0) > 100:
            raise WorkflowError("comment search incomplete; narrow the query")
        for row in response.get("items", []):
            inventory[row["number"]] = row
            comment_matches.add(row["number"])
    ranked = []
    for n, row in inventory.items():
        content = row.get("title", "") + " " + (row.get("body") or "")
        overlap = words(query) & words(content)
        if overlap or n in comment_matches:
            ranked.append((score(query, content) + (0.5 if n in comment_matches else 0), n))
    ranked.sort(reverse=True)
    results = []
    for rank, n in ranked[:limit]:
        result = issue_summary(client.issue(n))
        result.update(score=round(rank, 3), comment_match=n in comment_matches)
        results.append(result)
    return {"query": query, "closed_since": cutoff, "inventory_count": len(inventory),
            "match_count": len(ranked), "results": results, "read_only": True}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo")
    p.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="command", required=True)
    f = sub.add_parser("find")
    f.add_argument("query", nargs="+")
    f.add_argument("--closed-days", type=int, default=90)
    f.add_argument("--limit", type=int, default=8)
    s = sub.add_parser("show")
    s.add_argument("number", type=int)
    args = p.parse_args(argv)
    try:
        client = GitHub(args.repo or repository_name(repository_root()))
        if args.command == "find":
            if args.closed_days < 0 or not 1 <= args.limit <= 30:
                raise WorkflowError("closed-days must be nonnegative and limit 1–30")
            result = find(client, " ".join(args.query), args.closed_days, args.limit)
        else:
            result = {"results": [issue_summary(client.issue(args.number))], "read_only": True}
        if args.json:
            print_json(result)
        else:
            for row in result["results"]:
                print(text(f"#{row['number']} [{row['state']}] {row['title']}\n{row['url']}\n{row['body']}"))
                for c in row["comments"]:
                    print(text(f"\nComment ({c['updated_at']}):\n{c['body']}"))
                print()
            if not result["results"]:
                print("No matching issues in the completed search.")
        return 0
    except WorkflowError as exc:
        print(f"issues: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
