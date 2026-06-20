# Worktree-linked simulators — design

**Date:** 2026-06-20
**Status:** Approved (pending spec review)

## Problem

Parallel worktrees all build/install/test against a single booted visionOS
simulator (the hardcoded `D9BD8E9D…` in `CLAUDE.md`). Two worktrees experimenting
at once clobber each other's app container and login state, and the `booted`
shorthand breaks the moment more than one sim is up. We want each worktree to own
an isolated simulator whose lifetime tracks the worktree: cloned on creation, deleted
when the worktree goes away.

## Goals

- Each linked worktree gets its own simulator, cloned from a "golden" logged-in sim
  so experiments start authenticated.
- The main worktree keeps using its existing sim unchanged.
- Behavior is identical whether a worktree is created by an agent (Claude/Codex) or
  manually via `git worktree add` ("both/mixed").
- Sim is deleted when its worktree is removed. A backstop sweep cleans up orphans the
  manual-removal path can't hook.
- Clones are created **shut down**; the worktree's own agent boots/manipulates its sim
  on demand.

## Non-goals

- Auto-booting clones, or managing more than one runtime version.
- Driving the Simulator.app window (still one device visible at a time; headless
  build/install/screenshot/log are per-UDID and work concurrently).

## Architecture

One checked-in shell script is the single source of truth. Both entry points (git hook
and agent instructions) call it, so behavior never diverges.

### `scripts/worktree-sim.sh`

Resolves the current worktree from `cwd`. Subcommands:

- **`setup`** — Idempotent provisioning for the current worktree.
  - If current worktree is the **main** worktree (`.git` is a directory) → no-op. Main
    owns the golden sim.
  - Else (linked worktree, `.git` is a file):
    - If `.simid` exists and names a live sim → no-op.
    - Else clone the golden sim (see below) to a new sim named `vpwt-<branch>`, leave it
      **shut down**, and write the new UDID to `<worktree>/.simid`.
    - If a sim named `vpwt-<branch>` already exists (e.g. stale `.simid`), reuse its
      UDID rather than cloning a duplicate.
- **`teardown`** — For the current worktree: read `.simid`; if it names a `vpwt-*`
  clone (never the golden), `simctl shutdown` (ignore errors) then `simctl delete` it,
  and remove `.simid`. Refuses to act on the golden UDID.
- **`prune`** — Sweep. Enumerate all sims whose name matches `vpwt-*`. For each, check
  whether any live worktree's `.simid` references it (live worktrees from
  `git worktree list --porcelain`). Delete any that nothing references. This is the
  backstop for `git worktree remove`, which has no git hook.
- **`id`** — Print the current worktree's UDID (main → golden UDID; linked → its
  `.simid`). Used inline by build/install/log commands.
- **`install-hook`** — Install the `post-checkout` hook (below) into the shared common
  git dir. One install covers all worktrees.

### Golden sim resolution

The golden sim is the **main worktree's `.simid`**. The main worktree path is derived
from `git rev-parse --path-format=absolute --git-common-dir` (`<main>/.git` →
`dirname`). On first run, `setup`/`id` in the main worktree writes the existing booted
UDID (`D9BD8E9D-8E58-485D-B332-F8CDF37133B5`) to `<main>/.simid` if absent. Clones are
made with `simctl clone <golden-udid> vpwt-<branch>`, which copies the runtime, device
type, and installed/authenticated state.

### Main vs linked detection

`[ -d .git ]` → main worktree; `[ -f .git ]` → linked worktree (git writes a `.git`
*file* pointing to the gitdir in linked worktrees). Confirmed against this repo.

### Branch → sim name

`git symbolic-ref --short HEAD`, with `/` and any non-`[A-Za-z0-9_-]` replaced by `-`,
prefixed `vpwt-`. Detached HEAD falls back to the short SHA.

### Git `post-checkout` hook

Installed at `<common-git-dir>/hooks/post-checkout` (shared across all worktrees).
Body: when invoked as a branch checkout (`$3 == 1`), exec
`"$(git rev-parse --show-toplevel)/scripts/worktree-sim.sh" setup`. Safe to fire on
every checkout because `setup` self-guards: main is excluded and an existing `.simid`
is a no-op, so only a fresh `git worktree add` actually clones. The hook is not
version-controlled; `install-hook` (re)creates it and is documented in CLAUDE.md.

### `.simid`

Per-worktree file at the worktree root containing only the UDID. Git-ignored
(`.gitignore` += `.simid`) so it never gets committed and resolves per-worktree.

## Agent integration

- **CLAUDE.md** — Add a "Worktree simulators" subsection documenting `setup` /
  `teardown` / `closeout` / `prune` / `install-hook`, and the rule: after creating a
  worktree run `scripts/worktree-sim.sh setup`; when finishing/removing a worktree run
  `scripts/worktree-sim.sh teardown` before `git worktree remove`, or run
  `scripts/worktree-sim.sh closeout <worktree>` / `prune` immediately after removal.
  Update the build / install / screenshot / `log show` command block to derive
  `SIMID=$(scripts/worktree-sim.sh id)` and target `"$SIMID"` instead of `booted` /
  the hardcoded UDID. The link-skip and stale-process guards stay; they now target
  `$SIMID`.
- **AGENTS.md** (new, repo root) — Mirror the worktree create/teardown/closeout rule
  for Codex, pointing at the same script.

## Data flow

```
git worktree add ──► post-checkout hook ──┐
                                          ├─► worktree-sim.sh setup ─► clone golden ─► .simid (shutdown)
agent "start worktree" ───────────────────┘

build/install/log ─► SIMID=$(worktree-sim.sh id) ─► simctl ... "$SIMID"

agent "finish worktree" / manual ─► worktree-sim.sh teardown ─► delete vpwt-* sim, rm .simid
safer closeout helper ─────────────► worktree-sim.sh closeout PATH ─► teardown if present + prune orphans
git worktree remove (no hook) ─────► worktree-sim.sh prune (backstop) ─► delete orphaned vpwt-* sims
```

## Agent closeout invariant

A worktree is not fully cleaned up until both the git worktree and its linked simulator
are gone. Agents should prefer `worktree-sim.sh teardown` before `git worktree remove`;
if the worktree has already been removed, they must run `worktree-sim.sh prune` or
`worktree-sim.sh closeout <removed-path>` and verify no matching `vpwt-*` simulator
remains. The golden main-worktree simulator is never deleted by linked-worktree closeout.

## Error handling

- `setup` on a linked worktree when no golden `.simid` exists → error with a clear
  message telling the user to run `id`/`setup` in the main worktree first (or it
  auto-seeds the golden from the known booted UDID — seeding only in main).
- `teardown`/`prune` never delete a non-`vpwt-*` sim or the golden UDID, even if a
  `.simid` is corrupt.
- `simctl` failures (sim already gone, not booted) are tolerated so the commands stay
  idempotent.
- `id` in a linked worktree with no `.simid` falls back to running `setup` first.

## Testing

- `worktree-sim.sh` is plain bash; verify by:
  - `setup` in main → no-op, golden `.simid` present.
  - `git worktree add` a throwaway branch → hook fires, `vpwt-<branch>` sim exists and
    is **Shutdown**, `.simid` written.
  - Re-run `setup` in that worktree → no duplicate sim (idempotent).
  - `teardown` → sim deleted, `.simid` gone; golden untouched.
  - `git worktree remove` then `prune` → orphan `vpwt-*` sim deleted.
- Confirm `simctl list devices booted` and a per-`$SIMID` build/install still work for
  the main worktree (no behavior change there).

## Implementation notes (verified during build)

- **`simctl clone` requires the SOURCE sim to be shut down** (error 405 otherwise). The
  golden sim is normally booted, so `setup` briefly bounces it: shutdown → clone →
  reboot. Login/auth lives on disk in the data container and survives the bounce. Net
  effect: provisioning a new worktree causes a ~10s blip in the main worktree's running
  sim. `clone_golden` guarantees the golden is rebooted even if the clone fails.
- **`core.hooksPath` shadows the hook.** This repo shipped with a stale
  `core.hooksPath = …/visionplex/.git/hooks` (a non-existent, misspelled path) that
  silently disabled *all* git hooks. It was unset so hooks resolve to `.git/hooks`.
  `install-hook` now warns loudly if any `core.hooksPath` override is present, since a
  hook written to `.git/hooks` would otherwise be dead.
- `set -e` + `pipefail`: the `prune` ref-collection loop must not let a per-worktree
  `[ -f .simid ]` miss bubble up as a pipeline failure — it's written as an
  `if`/`then` over process substitution so a missing `.simid` doesn't abort the sweep.

## Files touched

- `scripts/worktree-sim.sh` (new, checked in, executable)
- `.gitignore` (+ `.simid`)
- `CLAUDE.md` (worktree subsection + `SIMID` in the build block)
- `AGENTS.md` (new, repo root — Codex mirror)
- `<common-git-dir>/hooks/post-checkout` (installed via `install-hook`, not committed)
- `<main>/.simid` seeded with the existing booted UDID (git-ignored)
