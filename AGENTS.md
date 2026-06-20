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
scripts/worktree-sim.sh prune          # sweep clones whose worktree is gone
SIMID=$(scripts/worktree-sim.sh id)    # this worktree's UDID for build/install/log
```

**Rule:** after creating a worktree run `setup`; when finishing/removing one run
`teardown` (or `prune` later). `setup` clones from the golden sim, which `simctl` can only
do while the golden is shut down, so it briefly bounces a booted main sim (~10s blip).
