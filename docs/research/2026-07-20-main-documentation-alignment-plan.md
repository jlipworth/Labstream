# Main Documentation Alignment Plan

**Date:** 2026-07-20

## Goal

Align active repository documentation with the behavior currently shipped on `main`. The change must correct verified false or missing claims, establish executable clean-clone contributor guidance, preserve clear canonical ownership, and avoid expanding into unrelated documentation housekeeping.

## Scope decision

Use three cohesive passes covering verified P0 and P1 drift plus directly related, inexpensive P2 corrections. The public contributor workflow must support a completely new clone without a pre-existing `.simid`; a maintainer-local golden simulator is not an undocumented prerequisite.

## Verified alignment targets

### Contributor workflow

- Add a complete initial visionOS simulator bootstrap for a clone with no `.simid`.
- Make `docs/DEVELOPMENT.md` canonical for simulator provisioning, exact-product build/install, observable smoke criteria, simulator shutdown, and linked-worktree closeout.
- Replace divergent recipes in `README.md`, `docs/CONTRIBUTING.md`, `docs/MOBILE-IOS.md`, and `docs/TESTING-STRATEGY.md` with concise platform-specific entry points that link to the canonical procedure.
- Add the missing `uv` prerequisite and complete physical Vision Pro first-use guidance.
- Keep public instructions focused on contributor-observable safeguards. Do not copy internal agent-fleet incident history or orchestration rules from `CLAUDE.md`.

### Architecture and current behavior

Correct the verified false claims in `docs/PLAYBACK-ARCHITECTURE.md`:

- `PlaybackController` owns the `AVPlayer`; presenter views own `AVPlayerLayer` instances.
- Jellyfin and Emby initial PlaybackInfo negotiation can occur before controller construction.
- Plex and MediaBrowser prewarming have narrower lane-specific scopes than the current broad wording.
- Stall deadlines are lane-dependent, transport progress rearms the watchdog, adaptive bitrate is optional and default-off, and Direct Play / Maximum is not automatically downshifted.
- Replacement cleanup differs between Plex and Jellyfin/Emby; stop-before-replacement is not universal.
- Experimental Dolby Vision affects both Profile 8 injection and the fallback-less Profile 5 safety gate, while actual playlist injection remains Profile 8-only.

Document newly shipped ownership without duplicating the whole subsystem in every page:

- `docs/ARCHITECTURE.md`: app-lifetime SharePlay composition and corrected high-level boundaries.
- `docs/CODE-MAP.md`: SharePlay and visionOS Now Playing file ownership.
- `docs/PLAYBACK-ARCHITECTURE.md`: SharePlay attachment/Cinema continuity and the separate visionOS Now Playing lifecycle.
- `docs/SYSTEM-INTEGRATION.md`: GroupActivity privacy, participant-local authenticated resolution, and routing.

Also qualify README and contributing summaries of PMSKit effect boundaries and replace the dead `Labstream/Backend/Search/` path with current ownership.

### Downloads and live validation

- Document completed-download poster/chapter repair and its five-attempt, per-row/kind, process-lifetime retry budget in `docs/DOWNLOADS-OFFLINE.md`.
- Correct the active checklist to the current 512 MiB static-range regime and remove the obsolete embedded 64 MiB narrative from current guidance without rewriting archived history.
- Add focused regression checks for:
  - visionOS video Now Playing metadata, artwork, commands, seek, cleanup, and music coexistence;
  - SharePlay activation single-flight, replacement-session dismissal protection, and late-join rebroadcast;
  - iPad continuous-hover preview progress, same-target request deduplication, and stale completion rejection;
  - completed-row side-asset repair, bounded give-up, and resume-data recovery;
  - stale delayed range-auth responses not taking ownership from a newer retry attempt.
- Add concise triage-first evidence guidance.
- Replace the dead `docs/MACOS-228-VALIDATION.md` summary emitted by `scripts/validate-macos-228.sh` with current documentation targets.

## Workflow architecture

The implementation workflow runs three sequential phases. Agents may work in parallel within a phase only when their file ownership does not overlap.

### Phase 1: Contributor workflow

One editing unit owns `docs/DEVELOPMENT.md` and defines the canonical procedure. Other contributor-facing pages are updated only after that canonical text is stable so they can link to it rather than reproducing it.

The clean-clone bootstrap must bridge the current missing `.simid` state explicitly: select or create a compatible initial visionOS simulator, validate its UDID, record it as the main worktree golden simulator, and then use the existing `worktree-sim.sh` lifecycle. The exact procedure must be verified in a disposable clone or worktree.

### Phase 2: Architecture and behavior

Editing units receive non-overlapping document ownership. Each unit works from current code, tests, scripts, and the verified audit findings. Cross-document references should point toward canonical detail rather than repeat it.

### Phase 3: Downloads and validation

One unit owns download behavior documentation; another owns active test/checklist changes and the validator’s user-facing reference. Historical and archived files remain unchanged.

### Integration review

After the three groups are combined, a high-reasoning integration reviewer compares the complete diff with current code, scripts, tests, and the audit report. The reviewer must reject unsupported, cosmetic, duplicated, or out-of-scope changes and confirm that terminology is consistent across documents.

## Editing rules

- Every changed factual claim must be supported by current code, scripts, tests, or the approved clean-clone procedure.
- One document owns each complete procedure or architectural claim; other pages summarize and link.
- Public docs include exact paths, observable smoke criteria, shutdown, and cleanup, but not internal multi-agent operations or incident narratives.
- Archived and dated research material remains historical. Active guidance may stop embedding obsolete evidence, but history is not silently rewritten.
- Do not fix unrelated implementation defects as part of this documentation change.
- Do not promote `scripts/agent-sim-run.sh` as canonical while its separate parallel-worktree product-selection defect remains unresolved.
- Do not add broad checklist coverage merely to inventory every shipped feature.

## Explicit exclusions

- Fixing the `scripts/agent-sim-run.sh` parallel-worktree behavior.
- Changing the documented Xcode 27 CI baseline because script enforcement is a separate preflight question.
- Expanding prose for the already-documented duplicate-top-level-key validator policy.
- Broad test-matrix expansion for sorting, filtering, collections, trailers, extras, music labels, or search refinements.
- Reorganizing `docs/research/` or `docs/archive/`.
- Rewriting archived documents.
- App builds or simulator UI validation for prose-only changes, unless implementation unexpectedly changes app code.

## Verification

The documentation alignment is complete only when all applicable checks pass.

### Diff integrity

```sh
git diff --check
```

Review the complete diff for accidental code changes, sensitive identifiers, unsupported claims, archive rewrites, and scope expansion.

### Published documentation

```sh
uv run --with-requirements requirements.txt \
  mkdocs build --strict --config-file mkdocs.yml
scripts/ci-hygiene.sh
```

Validate relative links in both MkDocs content and the root README.

### Stale-claim checks

Confirm active documentation no longer contains or asserts:

- `Labstream/Backend/Search/`
- `docs/MACOS-228-VALIDATION.md`
- current 64 MiB static segments
- the malformed phrase `512 MiB segments are used`
- a universal 15-second stall watchdog
- unconditional stop-before-replacement behavior

### Documented command validation

Run the relevant scripts' read-only help paths and verify that names, flags, environment overrides, schemes, and destinations match the prose:

```sh
scripts/worktree-sim.sh --help
scripts/deploy-to-device.sh --help
scripts/deploy-mobile-to-device.sh --help
scripts/ci-macos-apple-platforms.sh --help
```

### Clean-clone bootstrap validation

Exercise the documented bootstrap in a disposable clone or worktree with no `.simid`. Confirm that it creates or selects a usable initial visionOS simulator and that the subsequent `worktree-sim.sh` workflow recognizes it. Remove all disposable simulators and worktrees afterward. No app build is required for this procedure-only check.

### Final adversarial review

A final reviewer must explicitly confirm:

- every in-scope P0 and P1 audit finding was addressed;
- directly related P2 corrections were handled without broader housekeeping;
- canonical ownership is clear;
- commands are executable from the documented starting state;
- no excluded work leaked into the diff.

## Completion boundary

The implementation workflow may edit and verify the documentation and the validator's stale user-facing reference. It does not commit, push, or publish implementation changes unless the user separately requests that action.
