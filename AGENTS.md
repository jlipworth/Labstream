# VisionPlay — agent notes (Codex)

Project-specific guidance also lives in `CLAUDE.md`; read it for the full build/test
loop and hard constraints. This file mirrors the points that matter most for Codex.

## Worktree simulators

Each git worktree gets its own visionOS simulator so parallel worktrees don't clobber
each other's app container / login. `scripts/worktree-sim.sh` is the single source of
truth (also invoked by a `post-checkout` git hook).

- The **main** worktree owns the *golden* logged-in sim (`D9BD8E9D…`, in `<main>/.simid`).
  Never delete it.
- A **linked** worktree gets a `vpwt-<branch>` clone of the golden, created **shut down**;
  its UDID lives in `<worktree>/.simid` (git-ignored). Boot it yourself before building.
- Target `"$SIMID"` (from `scripts/worktree-sim.sh id`), never `booted` — `booted` errors
  once more than one sim is up.

```sh
scripts/worktree-sim.sh install-hook   # one-time: auto-clone on `git worktree add`
scripts/worktree-sim.sh setup          # provision this worktree's sim (idempotent)
scripts/worktree-sim.sh teardown       # delete this worktree's clone + .simid
scripts/worktree-sim.sh closeout PATH  # teardown PATH if present, then prune orphans
scripts/worktree-sim.sh prune          # sweep clones whose worktree is gone
SIMID=$(scripts/worktree-sim.sh id)    # this worktree's UDID for build/install/log
```

**Rule:** after creating a worktree run `setup`; when finishing/removing one run
`teardown` **before** `git worktree remove`, or run `closeout PATH` / `prune` immediately
afterward. `setup` clones from the golden sim, which `simctl` can only do while the
golden is shut down, so it briefly bounces a booted main sim (~10s blip).

### Worktree closeout checklist

Never call worktree cleanup done until the matching simulator is gone. Preferred flow:

```sh
# Before removing a linked worktree:
cd <worktree>
scripts/worktree-sim.sh teardown
cd <main>
git worktree remove <worktree>
git branch -D <branch>

# Safer one-command helper from any repo worktree:
scripts/worktree-sim.sh closeout <worktree>

# If the worktree was already removed or you are unsure:
scripts/worktree-sim.sh prune
xcrun simctl list devices | rg 'vpwt|<branch-fragment>' || true
```

Do not delete the golden main-worktree simulator. Only `vpwt-*` linked-worktree clones
should disappear during closeout.
