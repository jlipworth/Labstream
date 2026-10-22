---
name: review-ledger
description: Preserve finding IDs, fixes, review evidence and a compact checkpoint across multi-round code reviews. Use for an ongoing review with unresolved findings or a review handoff, not routine one-pass feedback.
---

# Review continuity

Use `scripts/workflow-state.py` from the repository root. Its default store is
`build/workflow/state.json`, private and worktree-local. Use `--file` for a different
explicit store. Preserve the store with other needed evidence before removing a worktree.

- Add a finding once with a stable ID, concrete trigger, and severity. Reuse the ID on
  subsequent rounds rather than creating a fresh issue for the same objection.
- Mark a finding `fixed` with its resolution commit when code changes; this means awaiting
  review. A `verified` disposition requires a reason and an
  existing evidence file. State who reviewed it and whether that review was independent;
  the CLI records evidence, it does not establish reviewer independence. Neither disposition authorizes merging or closing a GitHub issue.
- Keep unaddressed findings `open`. Use `deferred` or `rejected` only with the actual rationale
  and owner decision where required; do not treat deferral as a pass.
- Before another review round, run `show`. Supply the original brief, current diff/base,
  unresolved and fixed-but-unverified findings, previous responses, and remaining gates.
  When using T3 delegation, create a fresh delegated task for each review round.
- Before compaction or handoff, record a checkpoint with the goal, next action, base,
  issue/PR references, already-authorized actions, and remaining gates. Authorization fields
  record the user's decisions; writing them does not grant permission.

```sh
python3 scripts/workflow-state.py finding add F1 --summary 'Old callback overwrites new session' --severity high
python3 scripts/workflow-state.py finding set F1 --status fixed --commit HEAD --note 'Guarded by session generation'
python3 scripts/workflow-state.py finding set F1 --status verified --commit HEAD --evidence build/review.txt --note 'Independent review and regression passed'
python3 scripts/workflow-state.py checkpoint --goal 'Finish lifecycle fix' --base main --issue 123 --next-action 'Review F1 and run Mac smoke' --gate 'Physical headset acceptance'
python3 scripts/workflow-state.py show
```

Receipts carry a hash of the source state as well as HEAD. `show` flags receipts stale
when source changes, including uncommitted/untracked edits. It also flags stale checkpoints
and verified findings, adding stale verified findings to `pending_review` without rewriting
their historical disposition. Re-review relevant changes before carrying approval forward. Hash matching proves source
identity only, not that a claimed test was actually run: inspect the evidence.

See [workflow tools](../../../docs/DEVELOPMENT.md#receipts-checkpoints-and-review-findings)
for receipt and status commands. Keep sensitive evidence local; do not paste private paths,
logs or media identifiers into public review comments.
