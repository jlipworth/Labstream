# Issues #239 and #240 Sequential Integration Design

## Goal

Implement GitHub issues #239 and #240 sequentially in the existing `issue-237-trickplay-hover` worktree, preserving the current #237 work and avoiding additional long-lived branches or worktrees.

## Starting State

The existing #237 changes are preserved in a temporary WIP commit. The branch is rebased onto local `main` at `5d369c2`. All subsequent work is performed directly in `/Users/jlipworth/labstream-worktrees/issue-237-trickplay-hover`.

## Sequence

1. Complete #239, including focused tests, mobile builds, and representative iPhone verification.
2. Review and commit #239 as a distinct commit.
3. Complete #240 on top of #237 and #239, including paging-model tests and cross-platform compilation.
4. Review and commit #240 as a distinct commit.
5. Run combined regression tests and smoke verification for the accumulated #237/#239/#240 branch.

This keeps each issue reviewable in Git history without creating parallel branch sprawl.

## Issue #239 Boundaries

The implementation will make compact-width iPhone media details purpose-built for the phone viewport:

- Keep Play/Resume visible in the initial viewport.
- Use compact artwork and metadata composition, preferring suitable landscape/backdrop artwork when the existing model provides it and degrading gracefully to portrait art.
- Keep secondary actions and synopsis reachable in a natural scroll.
- Tighten movie and TV library grid gutters and vertical spacing while preserving readable labels and comfortable touch targets.
- Avoid changing regular-width iPad, macOS, or visionOS layouts unless shared code requires an explicit size-class guard.

Verification will cover representative small and large iPhone simulators, long titles, and both portrait and landscape artwork paths.

## Issue #240 Boundaries

The implementation will add explicit, typed View All destinations to eligible horizontal rails:

- Eligibility and destination queries are represented explicitly; titles are never parsed to infer behavior.
- Home rails are the first supported surface, with Recently Added required and Continue Watching/Next Up exposed only where a complete backend query exists.
- The destination owns loading, empty, paging, later-page error/retry, refresh, and cancellation state.
- The first request is bounded. Additional pages load only near the end of currently loaded content.
- Duplicate triggers are coalesced, stale backend/session results are rejected, and termination follows reported totals or short/empty pages.
- Existing eager all-page movie-version collapsing is not reused for an unbounded View All feed.
- Search and music receive the shared header/action treatment only where a correct complete listing already exists; unsupported rails remain unchanged.

The design will reuse `LibraryPagingSource` and `LibraryPagingModel` where their known-total sparse model fits. Feeds without a reliable total will use a bounded append-style paging state rather than allocating speculative placeholders.

## Integration and Conflict Handling

Both issues are implemented directly in the rebased #237 worktree, one at a time. Each issue receives its own commit after tests pass. If #240 needs to touch layout or navigation code changed by #239, the combined behavior is resolved immediately rather than deferred to a later cherry-pick conflict.

The #237 player hover files remain outside the scope of #239 and #240 except for compilation fixes that are demonstrably necessary.

## Testing and Verification

For each issue:

- Add or update focused unit tests before or alongside production changes.
- Run relevant PMSKit tests and Xcode target builds.
- Inspect the issue-specific diff before committing.

For #239, run iPhone simulator smoke checks on representative compact viewports. For #240, compile all affected platform targets and smoke the primary visionOS path plus a mobile path. Simulator turns are serialized, and every simulator is shut down immediately after its verification turn.

After both issues are committed, run the combined test suite and headless install/launch/log/screenshot verification required by the repository. macOS host checks use the per-worktree development identity and are cleaned up afterward.

## Completion Criteria

- #239 and #240 acceptance criteria are implemented without regressing #237.
- Each issue has a distinct commit on `issue-237-trickplay-hover`.
- Focused tests and combined regression tests pass.
- Required app builds and runtime smoke checks pass, with failures reported rather than hidden.
- No additional feature worktrees or long-lived branches are created.
