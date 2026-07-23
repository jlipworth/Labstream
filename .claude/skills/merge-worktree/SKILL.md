---
name: merge-worktree
description: Merge, document, publish-status, and clean up a completed Labstream linked worktree. Use when the user asks to merge, land, integrate, or close out a Labstream issue branch/worktree. Covers rebasing onto local main, validation, documentation and plan lifecycle alignment, GitHub issue comments and conditional closure, simulator teardown, worktree-specific macOS host-app removal, worktree removal, and branch deletion.
---

# Merge and close out a Labstream worktree

Treat closeout as one transaction: integrate the code, align the durable docs, report accurate GitHub status, and remove the lane's resources. Do not call it complete when only the Git merge succeeded.

The main worktree is `/path/to/user/Projects/labstream`. Linked lanes normally live under `/path/to/user/Projects/labstream-worktrees/<lane>` or `/path/to/user/.codex/worktrees/<id>/labstream`, with branches normally named `codex/issue-<number>-<topic>`.

## Safety and authority

- Read `CLAUDE.md` first; it remains canonical if this skill drifts.
- Invocation authorizes the local rebase/merge and normal closeout writes described here. It does **not** authorize a push, force-push, deletion of unrelated branches/worktrees, or cleanup of unrelated dirt.
- Never discard changes to make a worktree removable. Stop and report uncommitted or untracked files.
- Preserve unrelated dirt in main, especially `Labstream.xcodeproj/project.pbxproj`. If it prevents a safe integration, stop instead of stashing or committing it.
- Never infer completion from a green build alone. Physical Vision Pro, two-participant SharePlay, live-backend, App Store, or other external acceptance gates remain real gates.
- GitHub is public. Scrub private hostnames, IPs, usernames, media names, local paths, tokens, and device identifiers from comments and archived docs.

## 1. Establish the closeout contract

From main, capture current truth before changing anything:

```sh
git status --short --branch
git worktree list --porcelain
git -C "$WORKTREE" status --short --branch
git -C "$WORKTREE" log --oneline --decorate --max-count=20
git -C "$WORKTREE" diff --stat main...HEAD
```

Identify the exact source worktree, source branch/commit, issue number(s), and intended acceptance gates. Derive issue candidates from the branch, changed plans, and commit messages, but do not guess when they disagree. A detached lane needs an explicit source commit before integration.

Read the complete issue body **and comments** before deciding its state:

```sh
gh issue view "$ISSUE" --comments \
  --json number,title,state,body,comments,labels,url
```

Comments may establish `implemented / pending validation` even when the issue body is stale. Record whether the outcome is:

1. complete and eligible to close;
2. merged but still awaiting an acceptance gate;
3. partially implemented with a named successor; or
4. not merge-ready.

## 2. Align documentation before the final merge

Inspect all changed docs plus any plan/research file linked from the issue. Do not archive a document merely because a branch is merging.

- Current verified behavior and procedures belong in published topic docs directly under `docs/`.
- Approved work with an open implementation or acceptance gate stays in `docs/plans/`.
- Unresolved investigation stays in `docs/research/`.
- Immutable audit/profiling observations stay in `docs/evidence/`.
- A completed or superseded plan moves to `docs/archive/plans/`; a closed investigation worth retaining moves to `docs/archive/research/`; a resolved branch review moves to `docs/archive/reviews/`.

Before archiving, promote durable facts into canonical current docs and move any unfinished item into an explicitly linked successor. Preserve the historical journal instead of rewriting it as if it had always been complete. Update status text, `docs/plans/README.md`, `docs/research/README.md`, `docs/archive/README.md`, and all live links/navigation affected by the move. Keep the issue and document status consistent: a hardware-blocked plan is still active even if its code merged.

For any documentation content or path change, run:

```sh
scripts/ci-hygiene.sh
```

This includes strict MkDocs and Mermaid checks. Also search the whole tracked tree for every old path and validate relative links and heading anchors in unpublished `plans`, `research`, `evidence`, and `archive` lanes; MkDocs does not cover all of them.

## 3. Rebase, revalidate, and integrate

Use the current **local** `main`; do not reset it to `origin/main`. In the source worktree:

1. require a clean status;
2. rebase the source branch onto current local `main`;
3. resolve conflicts by preserving both current-main behavior and the lane's intended change;
4. rerun the issue-relevant tests and all gates affected by conflict resolution;
5. if main advances, rebase and validate again.

For app-code changes, follow `CLAUDE.md`'s clean build and worktree-owned simulator smoke requirements. Use only the lane's `.simid*`, never `booted`, hold the single simulator lease, and shut the leased simulator down immediately after verification. Do not substitute simulator evidence for a physical-device acceptance gate.

Integrate into main without manufacturing an unnecessary merge commit:

```sh
cd /path/to/user/Projects/labstream
git merge --ff-only "$SOURCE_BRANCH"
git merge-base --is-ancestor "$SOURCE_TIP" main
```

If fast-forward fails, return to the lane, rebase onto the now-current local main, rerun affected gates, and retry. Do not silently switch to `git merge --no-ff` or squash away intentional commits.

After integration, inspect `git status`, the first-parent log, and the full integrated diff. Run any cheap final gates from main that can detect worktree-specific assumptions. Pushing remains a separate user-authorized action.

## 4. Comment on the GitHub issue and close only when true

Every targeted issue receives a concise factual comment after integration. Include:

- what landed and the local main commit range/tip;
- validation actually run and its result;
- documentation promoted, retained active, or archived;
- every remaining acceptance gate or follow-up;
- publication truth: `pushed/reachable on origin/main` or `merged locally, not yet pushed`.

Compose the comment in a temporary Markdown file and use `gh issue comment "$ISSUE" --body-file <file>` to avoid shell-quoting damage.

Close with reason `completed` only when all acceptance criteria are satisfied, no required physical/live validation remains, and the implementing commit is reachable from `origin/main` (unless the user explicitly directs a different publication boundary):

```sh
git fetch origin main
git merge-base --is-ancestor "$SOURCE_TIP" origin/main
gh issue close "$ISSUE" --reason completed
```

Otherwise leave it open and say exactly why. A successful local merge is not by itself a reason to close a public issue. If several issues are referenced, assess and comment on each independently.

## 5. Tear down simulators, worktree, and branch

Only after the merge is verified and the GitHub comment succeeds:

```sh
cd /path/to/user/Projects/labstream

# Remove every native Mac app implementation staged from the closing worktree.
"$WORKTREE/scripts/deploy-macos-to-host.sh" --delete-all-staged

# Remove its simulator implementations.
scripts/worktree-sim.sh closeout "$WORKTREE"
git worktree remove "$WORKTREE"
git branch -d "$SOURCE_BRANCH"
scripts/worktree-sim.sh prune
xcrun simctl list devices | rg 'vpwt|iphonewt|ipadwt|<branch-fragment>' || true
```

Before removal, recheck the lane is clean. The Mac cleanup command is mandatory even when the lane was not primarily a macOS lane: app-code validation may have staged one or more `Labstream Dev — <identity>` builds under that worktree's `build/macos-host/`. It terminates and deletes every Mac app staged by the closing worktree, including any worktree-local production-identity staging, plus its worktree-local Mac build product. Verify that no `Labstream.app` remains below `$WORKTREE/build/macos-host/` and no process is executing from that path.

This cleanup must not delete the canonical `/Applications/Labstream.app`, a Mac app staged from another active worktree, sandbox containers, or Keychain credentials. If `~/Library/Containers/com.jlipworth.Labstream.dev.*` contains an identity associated with the closing lane, classify it against all active worktrees before removal; delete only a confirmed stale development container, and never reset the production container during ordinary closeout.

`closeout` must remove all of that linked worktree's visionOS/iPhone/iPad simulators and `.simid*` ownership files without deleting main's golden visionOS simulator. Prefer `git branch -d`; use `-D` only after proving the exact source tip is an ancestor of main and only when Git's worktree/rebase bookkeeping makes `-d` reject an already-integrated branch.

If the worktree was already removed, run `scripts/worktree-sim.sh prune` and verify no owned simulator remains. Also inspect the removed path's former `build/macos-host` identities and the live process list; if the path is gone, its staged apps are gone, but any matching stale development container still needs the active-worktree classification above.

## 6. Final report

Report each closeout dimension separately:

- **Merged:** source branch/tip and resulting local main tip.
- **Validated:** exact automated, simulator, physical-device, and live-backend gates; never blur them together.
- **Docs:** canonical docs updated and plans/research archived or deliberately retained active.
- **GitHub:** issue comment URL/status, closed or left open with the remaining gate.
- **Cleanup:** worktree-specific Mac apps/processes removed, simulator UDIDs/names removed, worktree removed, branch deleted, and the canonical Mac app plus golden simulator preserved.
- **Publication:** whether main was pushed; if not, say `local main only`.

If any dimension is incomplete, call the closeout partial and give the exact next action.
