# VisionPlay Architecture Review (Issue #53)

_Read-only architecture review synthesizing verified findings across the player, PMSKit, backend abstraction, auth, state/persistence, downloads, music, diagnostics/privacy, system integration, UI shell, theater, and tests subsystems. Acceptance posture honored: **safe, incremental cleanup over sweeping rewrites**; documentation deferred until the architecture settles._

## Executive Summary

VisionPlay is a well-structured visionOS Plex/Jellyfin client whose core seams are largely clean. The pure policy state machines (`AdaptiveBitratePolicy`, `FinalTargetRebuildPolicy`, `SeekRestartBudget`, `PlaybackScrubState`, `MediaBackendSwitch`, `QueueMutation`) live in PMSKit and are hermetically unit-tested; the diagnostics/privacy posture is deliberate and mostly enforced at field-construction time; the AVFoundation-vs-app-layer boundary in PMSKit holds. **No sweeping rewrite is warranted** — every recommendation below is a small, independently-shippable consolidation.

The single most urgent item is a **documentation/code contradiction, not a code bug**: `CLAUDE.md` and `DEVELOPMENT.md` both mandate the Plex transcode profile name stay `"Safari"`, while the shipping code deliberately sends `"Generic"` (Safari was found to regress 4K HEVC, forcing ~20 Mbps video transcode even on Direct Play / Maximum). A contributor following the guardrail docs would re-break high-bitrate playback. **Fix the docs, not the code.**

Beyond that, the findings cluster into duplication of small primitives (the highest-ROI cleanups), oversized files that split mechanically, latent playback restart divergence, two genuine concurrency hot spots, one real privacy gap, and offline-download test-coverage gaps.

### What is already clean (worth stating honestly)
- **PMSKit purity holds.** No AVFoundation or `PlexClient` types cross the package boundary; the control-plane transport is injected. The pure policy state machines are value types, unit-tested, and owned by `PlaybackController` as fields.
- **Diagnostics redaction is principled.** Field-level omission of `host`/`username`/`path`/`title` keys is enforced at construction; the report is opt-in, local, and user-initiated.
- **Backend mapping is consistent.** Both backends converge on the canonical PMSKit `MediaItem`, so detail/poster/player code is genuinely backend-agnostic once an item exists.
- **State ownership is deliberate.** `AppModel` owns no player/download controllers (avoiding retain cycles); the Keychain has a single gateway (`KeychainStore`); offline state has its own clear persistence boundary (`DownloadStore`).

## Themes

| # | Theme | Essence |
|---|-------|---------|
| 1 | **Docs/code contradictions on load-bearing invariants** | Stale guardrails actively mislead: Safari-vs-Generic transcode profile; single-`maxVideoBitrateKbps` persistence comments (now split home/remote/legacy); retired `PlayerView` references. |
| 2 | **Hand-rolled duplication of small primitives** | Same mapping/predicate/view copy-pasted with no owner: `JellyfinClientIdentity` (5), `isRemoteTranscode` (3), restart fork (5-6), duration formatters (4), progress slivers (3), art backdrops (3), etc. |
| 3 | **Oversized types fusing separable concerns** | `PlaybackController` ~3520, `DownloadManager` 1717, `DetailView` 957, `MusicLibraryView` 931, `CustomPlayerChrome` 943, `JellyfinLibrary` 690. Lowest-risk wins are mechanical file/extension splits. |
| 4 | **Playback restart divergence (Plex vs Jellyfin)** | In-place restarts fork by hand into `reopenRemoteStream` vs `beginStreaming`; remote-transcode detection splits across two fields; reopen-failure surfaces eagerly on Jellyfin but lazily on Plex. Latent, not a live bug. |
| 5 | **Concurrency / hot-path inefficiencies** | `DownloadStore.records` stats per row under the lock, amplified O(tasks×rows) at relaunch; dual KVO on `\.timeControlStatus`; per-event UserDefaults read in diagnostics; main-actor poster fetch. |
| 6 | **Privacy + test-coverage gaps** | Raw Plex server NAME escapes best-effort redaction in exported reports. Offline-download Codable migration, reconcile table, quality migration, and `StreamingQuality.label` are untested (no app test target). |

## Prioritized Findings

Ranked by impact ÷ (risk × effort) — high-impact, low-risk consolidations first.

| Rank | Finding | Sev | Effort | Category | Key files | PR |
|-----:|---------|:---:|:------:|----------|-----------|:--:|
| 1 | Correct Safari→Generic transcode-profile invariant in docs | **High** | S | docs | `CLAUDE.md:68`, `docs/DEVELOPMENT.md:56`, `TranscodeRequest.swift:114-121` | PR-1 |
| 2 | One `JellyfinClientIdentity` accessor (replace 5 copies) | Med | S | duplication | `AuthManager.swift:649`, `JellyfinBrowseService.swift:24`, `DownloadManager.swift:321`, `PosterImage.swift:182`, `DetailView.swift:463` | PR-2 |
| 3 | `isRemoteTranscode` computed property (replace 3 inline) | Med | S | duplication | `PlaybackController.swift:2105,2226,2937` | PR-2 |
| 4 | Shared Music/UI view primitives (formatter, sliver, backdrop) | Low | S | duplication | `NowPlayingView.swift:95,449`, `AlbumDetailView.swift:79,283`, `HomeView.swift:252,329`, `DetailView.swift:914` | PR-3 |
| 5 | Split `DownloadManager.swift` into 3 files | Med | S | complexity | `DownloadManager.swift:25,1169,1678` | PR-4 |
| 6 | Move `PlaybackController` diagnostics cluster to extension | Low | S | complexity | `PlaybackController.swift:3309-3520` | PR-4 |
| 7 | Omit raw Plex server NAME from exported reports | Med | S | privacy | `SettingsView.swift:689-698`, `DiagnosticLogging.swift:453-455` | PR-5 |
| 8 | Fix `DownloadStore.records` stat-under-lock at relaunch | Med | M | concurrency | `DownloadStore.swift:303,307`, `DownloadManager.swift:1254,1290` | PR-6 |
| 9 | Collapse dual `\.timeControlStatus` KVO into one hop | Low | M | concurrency | `PlaybackController.swift:2332,2356` | PR-6 |
| 10 | Move offline Codable types to PMSKit + migration tests | Med | M | tests | `DownloadStore.swift:8,96,121,411` | PR-7 |
| 11 | Centralize + test preference/quality reads | Low | M | state-ownership | `PlayerExperiencePreferences.swift:38-64`, `DownloadManager.swift:464`, `PlaybackController.swift:2526-2539` | PR-8 |
| 12 | Diagnostics toggle single-writer + DEBUG probe fix | Low | S | state-ownership | `AppDiagnostics.swift:20-47`, `SettingsView.swift:584`, `DebugJellyfinPlaybackProbe.swift:21` | PR-5 |
| 13 | Move `cachePoster` off the main actor | Low | S | concurrency | `DownloadManager.swift:674-680` | PR-6 |
| 14 | Stale-comment sweep + confirmed dead-code removal | Low | S | dead-code | `StreamingQualityLadder.swift:5`, `JellyfinPlayback.swift:361`, `PlexClient.swift:106`, `AuthManager.swift:70`, `JellyfinLibrary.swift:674` | PR-9 |
| 15 | Extract `restartAtCurrentPosition` helper (deferred) | Med | M | playback-divergence | `PlaybackController.swift:1263,1367,1391,3089,3159` | PR-10 |

## Proposed PR / Issue Breakdown

The work splits cleanly into **10 independently-shippable PRs**, ordered so each lands on a green build and the riskiest player surgery comes last, after the test backfill raises the safety net.

**PR-1 — Docs: Safari→Generic invariant** _(ship immediately, docs-only)_
Update `CLAUDE.md:68` and `DEVELOPMENT.md:56` to state the invariant is now `Generic`, preserving the "unknown/missing profile name returns a bare HTTP 400" warning. No code change — the code is the proven-correct state.

**PR-2 — Predicate/mapping consolidation** _(pure refactor)_
Add `extension ClientIdentity { var jellyfin: JellyfinClientIdentity }` in PMSKit; replace the 5 production constructions. Add `private var isRemoteTranscode` in `PlaybackController`; replace the 3 inline copies (leave the narrower line-1839 check). Byte-identical output.

**PR-3 — Shared view primitives** _(decorative, screenshot-verify)_
One `hms` duration formatter (ms + seconds overload) → 4 copies; `ProgressSliver(offset:duration:)` → 3 copies; `MusicArtBackdrop(art:)` → 3 backdrop blocks.

**PR-4 — Mechanical file splits** _(no logic change; build-verify per link-skip guard)_
Move `BackgroundDownloadSession` and `BackgroundDownloadCompletionRegistry` out of `DownloadManager.swift` (keep the private `String` extension with the manager). Move the diagnostic field-builder cluster to `PlaybackController+Diagnostics.swift`.

**PR-5 — Privacy + diagnostics-toggle hardening**
Return only the product version from `diagnosticServerLine` (mirror the Jellyfin branch's constant) + add a personal-name renderer test. Make `AppDiagnostics.setEnabled` the single writer, drop the redundant `@AppStorage` assignment and per-event UserDefaults read, comment the enable-then-disable ordering. Fix the DEBUG probe so it does not force-persist the user toggle.

**PR-6 — Concurrency hot-path fixes**
`DownloadStore.records`: snapshot under lock, `fileExists` outside; add an FS-free `allRatingKeys` for `reattach`. Collapse dual `\.timeControlStatus` KVO into one MainActor hop (NSLog-instrument first; run pause/stall-recover/seek from `TESTING-CHECKLIST.md`). Move `cachePoster` off-actor via the existing `fetchArtworkData` template.

**PR-7 — Offline persistence to PMSKit + migration tests**
Move `DownloadStatus`/`OfflineMetadata`/`DownloadRecord` into PMSKit; extract `reconciledStatus(current:fileExists:hasLiveTask:)`. Add pre-D2/pre-D5/round-trip/reconcile-table tests. (Closes the silent-data-loss-on-upgrade coverage gap.)

**PR-8 — Centralize + test preference reads**
Inject `defaults: UserDefaults = .standard` into the quality funcs; add facade accessors so `DownloadManager`/`PlaybackController` stop re-implementing nil-check-then-read; consolidate the two preference-key namespaces (preserve raw strings). Optionally move + test `StreamingQuality.label(kbps:)`.

**PR-9 — Stale-comment sweep + dead-code removal**
Fix persistence/`PlayerView`/`isMusic` comments. Delete `streamURLWithoutURLToken`, the unreachable `.alreadyActive` switch case, the `itemFields = fullItemFields` alias; resolve intent on `DownloadError.noOptimizedPart` and `PlexInsecureLANTrustDelegate`.

**PR-10 — `restartAtCurrentPosition` helper** _(deferred; do last)_
Centralize the reopener-vs-`beginStreaming` branch and the `{adaptiveBitratePolicy.reset, finalTargetRebuildPolicy.reset, removeObservers, recovery-client swap, error.clear}` bookkeeping. Migrate one caller at a time **preserving each caller's exact reset set** (behavior-unchanged); unify the divergent adaptive-reset only as a separate reviewed step.

## Documentation Plan (after architecture settles)

1. **Transcode-profile invariant** _(blocks regression — do with PR-1)_: Safari→Generic, with the 4K-HEVC rationale and bare-HTTP-400 warning.
2. **Quality persistence model**: home/remote/legacy three-key split, `AppModel.activeStreamingQualityDefaultsKey` selection, and the intentional-forever legacy write for downgrade compatibility.
3. **Playback restart contract** (after PR-10): per-trigger reset matrix and the Plex-eager-via-observers vs Jellyfin-eager-in-task failure-surfacing asymmetry, in `DEVELOPMENT.md`.
4. **Remote-transcode invariant**: a remote transcode always supplies a reopener; buffer/stall tuning assumes reopenability.
5. **Diagnostics/privacy contract**: align `PRIVACY.md` with the actual guarantee — redaction at `DiagnosticFieldValue` construction only; `.string(raw)` bypasses it; which header fields are omitted vs best-effort.
6. **Backend abstraction note**: there is intentionally no shared backend protocol; the two parallel enums are bridged by `AuthManager.switchChoice`; the `PlexClient` actor vs per-call `JellyfinBrowseService` asymmetry is known.
7. **Test strategy note**: mixed swift-testing/XCTest split; `Live*Probe` files are non-asserting discovery dumps (zero CI signal by design); no app-target test target — which is why offline/preference logic must migrate to PMSKit to be covered.
8. **Theater/Cinema gating**: `RealityTheater` is developer-gated dead-in-release; `CustomCinemaMode.isUserVisible = true` is an experimental scaffold, not the issue #12 path — confirm before public release.

## Closing Note

Nothing here calls for restructuring the app's architecture. The codebase already isolates its pure logic correctly and owns its state deliberately. The work is disciplined consolidation: kill the duplicated primitives, split the oversized files mechanically, close the one real privacy gap and the two real concurrency hot spots, backfill the offline-persistence tests, and only then refactor the deepest player restart path under that new safety net. Highest priority by far is the one-line-class fix that costs nothing and prevents a real regression: **correct the Safari/Generic guardrail docs.**