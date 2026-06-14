# Codebase Consolidation & Merge Roadmap (Plex-first, custom-player-only)

> Status: **planning only — no code changes yet.** Produced 2026-06-14 from a full audit of all
> GitHub issues and every local/remote worktree against the post-#38 codebase. This is the
> sequencing plan for landing relevant in-flight work onto `main` without conflicts, while
> reducing redundancy and streamlining docs. Each wave is executed and live-tested separately.

## Locked-in decisions (from the owner)

1. **The custom player is the ONLY player.** The legacy AVKit path is not a fallback — it is
   removed entirely. All AVKit player code is deleted.
2. **Cinema mode must replicate the full normal-mode control set** (play/pause, scrubber, skip,
   and the quality/audio/subtitle/chapters/stats/speed menu). Apple's environment-docking is
   accepted as lost, since it is only reachable via AVKit.
3. **"Plex solid" bar** (what must be done before Jellyfin #35 / Apple primitives #24 unblock):
   live-verify #27 and #7, fix #34, strip `[VP]` instrumentation, and land #31 + #26.
4. **Cleanup approved:** delete the obsolete spike + close-button experiment branches, drop the
   stale icon worktree, and consolidate/prune worktrees as work lands.
5. **Music (#17/#22) stays parked** behind video stabilization.
6. **Jellyfin (#35) and Apple primitives (#24) are HELD** until Plex is solid. Plex first, then
   bring Jellyfin to parity.
7. **`docs/DEVELOPMENT.md` is retired as a monolith** — knowledge moves to GitHub issues or
   focused per-topic docs.

## Current truth (post-#38)

- `main` HEAD is the `#38` "custom player" merge on top of the MediaSessionProxy / connection-stall
  work (#33) and the final-target seek-rebuild policy.
- **#38 was additive, not a replacement.** `CustomPlayerView.swift` / `CustomCinemaMode.swift` live
  *behind* `experimentalCustomPlayerEnabled` (default **false**), so AVKit is still the shipping
  default today. The custom player already **reuses the shared picker views** in
  `PlayerControlPickers.swift` (Quality/Subtitles/Audio/Chapters/Stats/Speed), so menu parity in
  windowed mode is already met.
- Every unmerged worktree branch except the Jellyfin pair was cut before #33 **and** #38 and is
  ~38 commits behind `main`; their earlier "rebased & clean" notes are now stale.

## Worktree / branch dispositions

| Branch | Issue | Disposition | Notes |
|---|---|---|---|
| `profiling/28-baseline` | #28 | merge (Wave 3) | docs-only; refresh its one "AVKit/Cinema" line after AVKit removal |
| `ci/36-hygiene-forbidden-strings` | #36 | rebase → merge (Wave 3) | drop the now-duplicate `.gitignore` line; smoke-run the script |
| `playback/31-direct-stream-headroom` | #31 | rebase → merge (Wave 2) | default-off; one `SettingsView` footer hunk to hand-merge |
| `settings/26-expanded-surface` | #26 | rebase → merge (Wave 2) | re-apply **on top of** main's Playback section + toggle removal |
| `music/17-22-redesign` | #17/#22 | needs human test (Wave 4) | code/tests green; live §C retest paused; does not touch video player |
| `system/24-app-intents-spotlight` | #24 | **HOLD** | high-change Apple primitives; rebuild+review post-rebase when revisited |
| `backend/35-jellyfin-support` | #35 | **HOLD** | PMSKit/auth/browse reusable; player glue is pre-AVKit-removal → must be redone |
| `origin/ui/35-jellyfin-parity` | #35 | **HOLD + redundant** | the untested visual-polish branch; pick ONE canonical Jellyfin branch |
| `spike/25-avplayer-seek-intercept` | #25 | **drop** (Wave 0) | obsolete — custom player owns seek intent directly |
| `icon/19-layered` | #19 | **drop** (Wave 0) | main already shipped a better icon; can't merge (binary PNG conflict) |
| `close-A-inline-float` / `close-B-custom-transport` / `close-C-ornament` | #1 | **drop** (Wave 0) | settled-against AVKit experiments, local-only |

**Already done on `main` (verify on-sim and close, no merge):** #18 welcome redesign, #19 icon,
#20 hover, #16 sign-in, #21 default quality, #9/#10 chapters, #22 music crash fix, #14 history scrub.

## AVKit removal surface (Wave 1 detail)

**Delete entirely (~1,187 lines):**
- `PlexAVPApp/Player/PlayerView.swift` (AVKit wrapper + `AVPlayerViewController` bridge + legacy
  floated overlays — the custom player reimplements equivalents)
- `PlexAVPApp/Player/PlayerControlSurface.swift` (`customInfoViewControllers`, `contextualActions`,
  `AVExperienceController.Delegate` glue)
- `PlexAVPApp/Player/CinemaEnvironment.swift` (operates only on `AVPlayerViewController.experienceController`)

**Surgery (remove the toggle + AVKit branch):**
- `PlexAVPApp/UI/DetailView.swift` — collapse the `if experimentalCustomPlayerEnabled { … } else { PlayerView(…) }`
  branch to the `CustomPlayerView` arm; remove the `@AppStorage`.
- `PlexAVPApp/UI/SettingsView.swift` — remove the toggle, its `@AppStorage`, and the footer clause.

**Keep (shared, do NOT over-reach):** `PlaybackController.swift`, `PlayerControlPickers.swift`,
`StatsForNerdsView.swift`, `PlaybackDiagnostics.swift`, `TimelineReporter.swift`,
`AudioSessionCoordinator.swift`, `CustomPlayerView.swift`, `CustomCinemaMode.swift`, all of PMSKit.

**Two blockers that gate the deletion:**
- 🔴 **Local/offline playback is hard-wired to AVKit.** `CustomPlayerView` has no `localFile`
  initializer; `DetailView.swift` (downloaded-copy play) and `Downloads/OfflineLibraryView.swift`
  always call `PlayerView(localFile:)`, bypassing the toggle. Deleting `PlayerView` breaks the build
  and removes offline playback. **Must finish first:** give `CustomPlayerView` a local-file
  `controllerFactory` and repoint both call sites (engine already supports local files — this is
  presentation wiring).
- 🟠 **Custom cinema controls are bare.** `CustomCinemaScaffoldView` has only Skip ± and Exit.
  Per decision (2), bring it to full normal-mode parity (play/pause, scrubber, and the menu popover
  reusing the same shared picker views), extending the existing
  [`2026-06-14-custom-player-cinema-mode.md`](2026-06-14-custom-player-cinema-mode.md) plan.

## Execution waves

### Wave 0 — Cleanup (no merges; do first)
- Delete branches + worktrees: `spike/25-avplayer-seek-intercept`, `close-A/B/C`, `icon/19-layered`.
  Capture any salvageable finding in a focused doc first (expected: none — all settled/superseded).
- Move the music worktree (currently outside the repo, e.g. `~/vp-music-1722`) under
  `.claude/worktrees/` so all worktrees live in one place.
- Reconcile the local `jellyfin-35` worktree with `origin/backend/35` (local is slightly ahead).
- Outcome: worktree list shrinks from 11 → ~6.

### Wave 1 — Custom player becomes the sole player (the keystone; requires live sim testing)
*Single branch, live-tested, then merged.*
1. Add the local-file path to `CustomPlayerView`; repoint `DetailView` + `OfflineLibraryView`.
   Verify **both** streaming and offline play through the custom player.
2. Bring `CustomCinemaScaffoldView` to full normal-mode control parity (decision 2).
3. Delete the 3 AVKit files; strip `experimentalCustomPlayerEnabled` from `DetailView`/`SettingsView`.
   Build clean, live-test windowed + cinema + offline.
4. Begin `DEVELOPMENT.md` decomposition for the now-obsolete AVKit sections (see Docs below).
- Unblocks all player-UI work below (it only makes sense against the custom surface now).

### Wave 2 — Plex "solid" bar
- Live-verify #27 (transcode lifecycle: ≥5s restart spacing, 3rd-in-a-minute escalation,
  one transcoder/session) and #7 (Direct Stream + device profile); strip `[VP]` NSLog from
  `PlaybackController.swift`; close both.
- Fix #34 reconnecting-overlay width — now in **one** place (`CustomReconnectingOverlay`).
- Re-apply #30 "retry above close" to the custom `failureCard` (the legacy-targeting branch is
  obsolete — small redo, not a merge).
- `playback/31-direct-stream-headroom`: rebase → merge (default-off).
- `settings/26-expanded-surface`: rebase → merge on top of the toggle removal.
- ⚠️ **Sequencing hotspot — `SettingsView.swift` Playback section** is edited by Wave 1 (toggle
  removal), #31, and #26. Land them **in that order, one at a time** to avoid re-resolving the hunk.
- ⚠️ **`DetailView.swift`** is edited by Wave 1, #17, #24, #35 — rebase cheap consumers before
  `main` moves again.

### Wave 3 — Independent infra (land anytime, parallel-safe)
- `ci/36-hygiene-forbidden-strings` (rebase, drop dup ignore line, smoke-run) and
  `profiling/28-baseline` (docs; refresh the AVKit-wording line).

### Wave 4 — Music (#17/#22), parked
- After video polish: re-rebase (mechanical `DetailView`/checklist conflicts), owner runs
  TESTING-CHECKLIST §C live, merge on green. Closes #17 + #22.

### Wave 5 — Larger Plex-core / unparked-by-shift (after the bar)
- #4 trick-play thumbnails (now unblocked — scope against `CustomPlayerView`).
- #23 A–Z letter rail + true-length paged-list scroll.
- #29 adaptive bitrate + #33 MediaSessionProxy Stage 3 (heavy; plan as a unit).
- Re-verify #25 seek-during-stall behavior against the custom transport.
- #32 bandwidth-mismatch toast.

### HOLD until Plex is solid
- **#24** Apple primitives (`system/24-app-intents-spotlight`) — high-change; full rebuild+review.
- **Jellyfin #35** — pick ONE canonical branch (`backend/35` is the substantive build;
  `origin/ui/35-jellyfin-parity` is the untested visual-polish work). Reuse PMSKit/auth/browse
  as-is; **redo the player glue against the custom player** (no AVKit to target); duplicate the
  Plex visual polish + login screen; live-test playback/seek/quality-reopen. Then **#37** Quick
  Connect (hard-depends on #35).
- **#12** RealityKit theater, **#13** offline `.movpkg` — optional, lowest priority.

## Redundancies addressed by this plan
- Two overlapping Jellyfin branches on the same pre-#38 base → choose one canonical, retire the other.
- The "fix the overlay in both legacy + custom" duplication (#30, #34) **disappears** once AVKit is gone.
- `[VP]` NSLog instrumentation in `PlaybackController.swift` removed as part of closing #27/#7.

## Documentation streamlining
- Decompose `docs/DEVELOPMENT.md`. After AVKit removal, these sections are obsolete (move to an
  "abandoned approaches" appendix or delete): the `contextualActions`/Close-button block, the
  "expanded cinema = system chrome only" findings, the programmatic ⓘ info-panel close hack, the
  platter-✕ collapse behavior, and AVKit retry-storm rationale (lines ~58–68, 82–88, 97–101,
  109–113, 201, 208 at time of writing).
- Migrate still-valid findings (transcode/PMS throttle behavior, `TranscodeRequest` Safari profile,
  `.cardLink()` hit-region rule, transcode-stop lifecycle, signing) into focused per-topic docs or
  issues. Update AVKit-referencing doc comments in `PlaybackController.swift` / `StatsForNerdsView.swift`.

## Recommended new issue
- **"Remove legacy AVKit player path — custom player is the sole player"** with sub-tasks:
  (a) `CustomPlayerView` local-file support + repoint offline call sites; (b) custom cinema full
  control parity; (c) delete the 3 AVKit files + toggle surgery; (d) `DEVELOPMENT.md` AVKit-section
  cleanup. This is the natural completion of #38.

## Pre-public note
- #14 (history scrub) is closed, but optionally ask GitHub Support to GC unreachable cached commits
  before flipping the repo public; land the #36 CI-hygiene guard alongside that.
