# Cross-platform simplification and performance program

Status: **Waves 0–4 implemented and validated; Wave 5 measurement prerequisites are in progress**

Audit baseline: `b3045bc0` (`Record tvOS merge checkpoint`) on
`codex/audit-simplification-performance`

Scope: visionOS, iOS/iPadOS, tvOS, native macOS, the shared app layer, PMSKit,
tests, performance tooling, and physical-device acceptance.

This plan owns the post-July-21 simplification and performance program. The
[July 10 remediation journal](2026-07-10-codebase-remediation.md) remains the
authority for already-landed correctness work and its still-open physical gates.
This plan must not reopen completed remediation slices or weaken download,
playback, auth, SharePlay, and platform invariants merely to reduce line count.

## Executive direction

The program has two ordered halves:

1. **Simplify ownership and execution paths without flattening platform UX.**
   Capture current contracts, remove provably dead paths, make unsupported
   capabilities absent, split platform presentation from shared policy, and
   consolidate duplicated network/data/state orchestration.
2. **Re-baseline and optimize the simplified app.** Measure launch, browse,
   artwork, playback, downloads, memory, energy, disk, network, rendering, and
   compile/test cost in an optimized profiling configuration. Optimize only
   demonstrated bottlenecks and compare every change against paired evidence.

A small pre-simplification measurement pass is still required. It is a control,
not permission to tune the current architecture before its ownership is clear.
The comparison chain has three immutable points, each recorded by exact commit
and artifact manifest: the original audited control, a post-safety/pre-structural
control using the final instrumentation, and the simplified-but-unoptimized
candidate. Optimization slices compare against the last applicable immutable
point; instrumentation changes require a new compatible control rather than a
hand-assembled comparison.

The target is not “fewest files” or “fewest `#if`s.” The target is:

- one clear owner for each state machine and side effect;
- shared policy below platform presentation forks;
- platform-only services absent from unsupported products;
- no duplicated polling, request fan-out, image decode, persistence, or metadata
  hydration where one scoped owner can serve all consumers;
- small, typed boundaries that preserve backend and platform differences; and
- performance claims backed by reproducible optimized-build and physical-device
  evidence.

## Audit snapshot

This section records the **pre-Wave 0 audited starting point**, not the current
post-Wave 1 tree. The audit was static and read-only. No builds, simulators, devices, live servers,
or runtime performance measurements were used, so all performance findings below
are hypotheses until the measurement phase proves them.

| Signal | Pre-Wave 0 baseline |
| --- | ---: |
| Production Swift | about 92,000 lines |
| App download implementation | 26,138 lines / 29 files |
| Shared player implementation | 14,923 lines / 29 files |
| Shared UI implementation | 13,860 lines / 34 files |
| PMSKit production | 27,748 lines / 219 files |
| App conditional compilation | 517 `#if` blocks + 67 `#elseif` branches |
| `CustomPlayerChrome.swift` | 3,320 lines / 120 conditional markers |
| `BackgroundDownloadSession.swift` | 7,243 lines |
| `DownloadStore.swift` | 5,739 lines |
| `PlaybackController.swift` | 5,684 lines |
| `DownloadManager.swift` | 5,522 lines |
| Recent high-churn surfaces | downloads, player chrome, library grid, Detail, SharePlay, Root |
| Existing runtime phases | 9 Debug-only browse/artwork/playback signposts |
| Existing committed runtime evidence | two small June Plex/visionOS-simulator baselines |

At that starting point, all four apps attached the same filesystem-synchronized `Labstream/`
source root. Platform ownership is therefore expressed almost entirely through
conditional compilation and no-op compatibility types. This is useful for truly
shared code, but it also causes tvOS to compile and instantiate unsupported
offline machinery and causes non-vision targets to carry inert Cinema, Reality
Theater, and SharePlay state.

## Program rules

1. **Contract capture precedes extraction.** Recent tvOS focus/remote work,
   Cinema handoff, downloads recovery, system media, and SharePlay are not moved
   until their current invariants have deterministic tests and device checklists.
2. **Mechanical movement and behavior change are separate commits.** Move a file,
   prove equivalence, then simplify it in a later slice.
3. **Share policy, not false platform sameness.** tvOS focus, Mac keyboard/window
   behavior, mobile PiP/orientation, and visionOS gaze/Cinema remain distinct.
4. **Make unsupported capabilities absent.** Do not construct a large real object
   and call it disabled because one registration flag is false.
5. **No native-resume-only download pivot.** The user has rejected a
   `URLSession` resume-data-only end state as too fragile. Retain an app-owned,
   deterministic checkpoint/recovery engine; simplify its unreachable and
   duplicated branches instead of deleting the recovery authority.
6. **ABR is evidence-gated, not sacred.** Client-driven playback ABR may be
   removed if measured benefit does not justify its reopen/restart/deadline
   complexity.
7. **No simulator-only performance conclusions.** Simulator runs are useful for
   deterministic comparisons; physical hardware closes launch, energy, thermal,
   HDR/audio, background, input, and system-surface claims.
8. **No giant cross-cutting PRs.** Each slice must be independently reviewable,
   reversible, and attributable in the paired performance data.
9. **Privacy remains load-bearing.** Never log or persist authenticated artwork
   keys, URLs, headers, media titles, server identities, tokens, or local paths.
10. **Performance wins do not excuse behavior drift.** A faster path that breaks
    offline integrity, focus, Cinema, PiP, SharePlay, playback progress, or
    backend ordering is a regression.
11. **Documentation ships with each durable change.** Every slice must review the
    current architecture, code-map, platform, testing, and operator docs that its
    changes could invalidate, and update affected current docs in the same slice.
    Wave 7 still performs the final whole-repository reconciliation and archives
    superseded plans/evidence; it is not the first time documentation is updated.

## Behaviors that must remain platform-specific

### visionOS

- one app-owned `PlaybackController` and `AVPlayer` across window/Cinema handoff;
- app-owned Custom Cinema with measured `visualBounds` placement;
- scoped `MPNowPlayingSession`, not the process-global mobile/Mac lease;
- exact participant-local SharePlay resolution and explicit consent before
  player attachment;
- ornament-based music presentation and proven gaze/hit-target behavior; and
- physical Vision Pro evidence for system surfaces, HDR/DV, Cinema, thermal, and
  device lifecycle.

### iOS/iPadOS

- native `.sidebarAdaptable` tab/navigation behavior, system sheets/lists/forms,
  `AVPictureInPictureController`, `AVRoutePickerView`, and MediaPlayer surfaces;
- justified iPhone landscape behavior and iPad pointer/multitasking behavior;
- background-download relaunch and real-device lock/background transitions; and
- separate compact/regular shell behavior rather than a phone-sized universal UI.

### tvOS

- five-tab TV shell with no Offline product surface;
- app-owned custom player and remote-native timeline, not default player chrome;
- hidden focus owner, guarded focus writes, focus sections, auto-hide timing, and
  TV-native pairing/search behavior;
- no general browser/pasteboard assumptions; and
- physical Siri Remote, search, HDR/audio/HDMI, long-play, and lifecycle gates.

### macOS

- native `NavigationSplitView`, desktop density, pointer/keyboard behavior,
  root-lifted full-window player, and focus-independent physical Escape route;
- process-wide music/video media ownership and native fullscreen/window behavior;
- staged-development credential isolation versus the canonical production
  Keychain identity; and
- host-app cleanup after validation.

### Backends and shared engine

- Plex `Generic` client profile plus explicit codec directives;
- backend-specific auth, URL, playback, subtitle, conversion, and cleanup rules;
- exact download-attempt ownership and cleanup durability;
- durable checkpoint, live OS-temp, and resumable-display bytes as distinct facts;
- source identity on all offline media and side assets;
- stop-before-restart and deferred prior-encoding cleanup ordering; and
- one terminal playback progress event with a non-regressing position.

## Decisions and open product questions

| Decision | Current direction | Needed by |
| --- | --- | --- |
| Download recovery | Keep app-owned deterministic checkpoint/recovery; native resume-data-only path rejected | Download decomposition |
| Client ABR | May be removed if paired measurements show little benefit | Playback typed restart work |
| Mac browse windows | **Resolved in Wave 1: one reusable main browse/player window plus singleton Settings.** Focused-scene multiwindow routing is intentionally out of scope | Mac shell extraction |
| visionOS Cinema | **Keep.** The shipping app-owned `CustomCinemaMode` remains a first-class visionOS capability; its ownership and implementation may be simplified, but the product surface and handoff invariants must remain | Every visionOS/player slice |
| Reality Theater prototype | **Removed in Wave 1.** Issue #12/#51 history and scene/chrome routing confirmed that the hidden `RealityTheater*` lab was independent from shipping `CustomCinemaMode`; useful historical context remains in Git/archive docs | visionOS source split |
| Offline Detail action | **Open.** Keep explicit “Play Offline” unless product direction says primary Play should prefer local media | Offline launch consolidation |
| Storage cap semantics | Recommendation: enforce durable bytes + known reservations; present side assets, held/resume data, and OS temp separately | Storage snapshot work |
| Legacy download schemas/tasks | **Remove fully.** Delete compatibility for legacy schemas and abandoned OS tasks; keep only the current schema and the app-owned checkpoint/recovery authority required by current downloads | Migration sunset |
| Physical matrix | Local discovery records this Apple-silicon Mac plus one paired iPhone, one paired iPad, and one paired AVP (the mobile devices/headset were unavailable during discovery). Physical Apple TV availability and any second AVP remain unconfirmed; unavailable cells must be labeled hardware-blocked rather than inferred from simulators | Final acceptance |

## Safety findings to resolve before broad refactoring

These are correctness or bounded-execution findings discovered during the audit.
Each remains a static hypothesis until a focused reproduction/test confirms it.
Confirmed findings should be small slices before structural work because they can
invalidate performance data or make later extraction harder; disproven findings
must be retired rather than “fixed” speculatively.

A second independent code re-review on 2026-07-21 re-confirmed the cited
mechanism for `SAFE-01`, `SAFE-03` through `SAFE-08`, and `SAFE-10` at the
listed locations. `SAFE-09` was confirmed as a real cancellation/completion
ordering race, with the caveat that actor serialization already prevents a
double resume — the required fix is ordering determinism, not crash prevention.
At audit time `SAFE-02` remained verify-first: the session sets 5s/20s
`timeoutIntervalForRequest`, the built `URLRequest` never sets
`timeoutInterval` (so the 60s request default is in play), and observed
behavior with a hanging transport must decide whether any change is needed.
Focused reproductions/tests were therefore required before each fix; the Wave 0
journal below records the current disposition rather than treating the static
re-review as runtime proof.

| ID | Priority | Finding | Evidence | Required stroke |
| --- | --- | --- | --- | --- |
| `SAFE-01` | P0 | Cancelled system-entry readiness can spin on `MainActor` until its 12-second wall deadline because cancelled sleeps are suppressed | `Labstream/Shared/SystemIntegration/SystemEntryRouter.swift:151-166` | Propagate cancellation immediately; then replace polling with a readiness single-flight |
| `SAFE-02` | P0 verify | Recovery/proxy request deadlines may not produce the intended 5s/20s behavior; session configuration may already be sufficient | `PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift:13-47`; `PlexRequest+URLRequest.swift:24-30` | First prove actual behavior with a hanging transport; change request preparation only if the configured deadline is not enforced |
| `SAFE-03` | P0 | Rotating one HLS upstream session can cancel unrelated healthy sibling requests | `PMSKit/Sources/PMSKit/MediaSession/UpstreamConnection.swift:15-45`; `MediaSessionProxy.swift:211-241` | Generation-tagged session swap; old work drains and stale failures cannot rotate the new session |
| `SAFE-04` | P0 | Closing during an itemless playback reopen can send terminal progress at zero | `Labstream/Shared/Player/PlaybackController.swift:5163-5189`; `Labstream/Shared/Player/TimelineReporter.swift:90-107` | Canonical position snapshot: live clock, held target, last trustworthy offset, saved offset |
| `SAFE-05` | P0 | MediaBrowser `Playing` is committed before the first request succeeds — the started flag flips when the request is built, not when it is accepted | `Labstream/Shared/Player/TimelineReporter.swift:189-225` | Commit only after accepted 2xx; retry `Playing` ahead of coalesced progress |
| `SAFE-06` | P0 | Offline side assets can survive a source/version change without consistent source fencing — `preserveCachedSideAssets` fences only `embyBIFRelativePath` by `mediaSourceID`; poster, Plex BIF, Jellyfin trick-play/tiles, chapter images, and subtitles carry forward unfenced | `PMSKit/Sources/PMSKit/Downloads/OfflineDownloadModels.swift:782-816`; `Labstream/Capabilities/Downloads/Core/DownloadStore.swift:2794-2799` | Source-owned side-asset bundle and attempt-scoped retirement |
| `SAFE-07` | P0 | SharePlay receive/send work is not fully fenced to the exact replacement session and outgoing status can reorder | `Labstream/Platforms/visionOS/SharePlay/WatchTogetherCoordinator.swift:388-450` | Session generation on receive/send; ordered outbound tail; stale revision rejection |
| `SAFE-08` | P0 | Non-vision remote seek/skip conversion lacks the validation already present on visionOS | `Labstream/Shared/Player/VideoNowPlayingCore.swift:95-112`; `Labstream/Platforms/visionOS/Player/VideoNowPlayingCoordinator.swift:185-194` | One pure validated remote-command policy feeding canonical controller intents |
| `SAFE-09` | P1 | Side-asset waiter cancellation can race successful completion | `Labstream/Shared/Player/SideAssetFetchCoordinator.swift:116-145,353-399` | Post-resume cancellation check and deterministic waiter/job index |
| `SAFE-10` | P1 | Background completion registry silently replaces a same-identifier handler | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadCompletionRegistry.swift:17-64` | Encode exact cardinality and prove every supplied handler fires exactly once |

### Wave 0 implementation journal

The following work was committed at `40af93f3`. Wave 0's
deterministic package, hosted-test, all-target build, tooling, and serialized
simulator-smoke gates now pass. Physical-device acceptance remains a later explicit
gate and is not inferred from these results. A dev-identity macOS host launch remains
blocked by entitlement signing; the already-running production-identity app was not
disturbed.

| Item | Current result |
| --- | --- |
| Original package control | `b3045bc0`: 1,638 PMSKit tests / 212 suites passed |
| Original Mac-hosted control | Five retry-disabled full-plan runs all exposed scheduler-bound tests: search fan-out 4/5, persistence timeout 3/5, dirty retry 1/5, and malformed-startup release 1/5. Deterministic gates replaced the sleep/semaphore assumptions; no production browse or persistence defect was found |
| `SAFE-01` | Confirmed and fixed. The final scheduler-independent contract handshakes the first real sleep, cancels, awaits false, and proves exactly one sleep call; it passed 10 repetitions and under the full hosted plan. Readiness single-flight remains a later simplification |
| `SAFE-02` | Retired without a source change; a silent loopback proved the session's configured request timeout overrides the request object's 60-second default |
| `SAFE-03` | Confirmed and fixed with generation-tagged compare-and-swap rotation and draining old sessions |
| `SAFE-04` / `SAFE-05` | Canonical terminal-position and accepted-Playing authorities are integrated with focused deterministic contracts |
| `SAFE-06` | Exact attempt-plus-source ownership covers every optional side asset. Promotion and metadata admission reject delayed old-source callbacks, deterministic subtitle adoption is gone, ownerless bundles fail closed, and retirement protects the complete cross-row artifact union |
| `SAFE-07` | Replacement-session receive/send fencing, ordered outbound delivery, per-participant revisions, roster buffering, and a bounded terminal-leave fallback are integrated; two-participant behavior remains a physical gate |
| `SAFE-08` | One validated absolute/relative remote-command policy now feeds the app-owned controller while platform publishers remain separate |
| `SAFE-09` | Deterministic waiter indexing and cancellation-wins behavior passed a 500-iteration standalone race harness |
| `SAFE-10` | Finish-events atomically claims an exact ordered token batch before persistence awaits. Delayed old-cycle releases cannot sweep newer same-identifier handlers; duplicate releases remain idempotent and reentrant handlers wait for the next cycle |
| Adversarial review | Independent review found one completion-cycle P1, three side-asset provenance/retirement P1s, and three tooling P1s. All seven were fixed with focused regressions; no remaining reviewed P0/P1 was reported in the Wave 0 diff |
| Integrated package gate | 1,668 PMSKit tests / 219 suites passed in one non-parallel run |
| Integrated hosted gate | Five full `LabstreamMacTests` runs passed, each with 343 tests / 40 suites. The original scheduler-bound tests and the SAFE-01 cancellation test are now load-independent |
| Integrated build gate | Debug build lanes passed for visionOS, iOS/iPadOS, tvOS test-build, and macOS. Fresh isolated simulator builds also passed before the visionOS, iPhone, and tvOS install/launch checks |
| Serialized simulator smoke | Exact worktree simulators were used one at a time and shut down. Built/installed Mach-O UUIDs matched for visionOS, iPhone, and tvOS; launches and logs were crash-free. iPhone and tvOS produced visible login screenshots; visionOS produced an active process/network log and a shell screenshot, but the spatial app window was not visible in the captured forward display |
| macOS host smoke | The non-simulator test/build gates pass. Per-worktree dev-identity launch was attempted and failed at the expected entitlement-signing gate; an already-running production-identity Labstream process was left untouched and staged dev apps were cleaned up |
| Performance control | `PerformanceAudit` is Release-parity for all four app targets, defines only `PERFORMANCE_AUDIT`, enables the existing nine privacy-safe spans, and has a closed local manifest/binary contract. The guard now rejects Debug/unoptimized/sanitized compiler drift and constrains manifest metadata to opaque identifiers/enums while explicitly not claiming raw-payload sanitization |
| Native test control | A checked smoke/affected/full matrix driver now separates hermetic tests, builds, simulator-hosted lanes, UI evidence, planned visionOS hosting, live probes, and benchmarks. Simulator lanes require the exact current-worktree UDID to be the sole booted simulator |

## Simplification workstreams

### S1 — Source topology and capability composition

**Goal:** make shared code genuinely shared and make platform-only ownership
visible in the project structure.

1. Consume Wave 0's frozen clean-build, binary-size, and compile-time baseline for
   all four targets plus the hosted tests that exist at that checkpoint. Do not
   imply visionOS hosted-test coverage until the Wave 0 strategy lands.
2. Add filesystem-synchronized roots for `Shared`, `Capabilities/Downloads`,
   `Platforms/visionOS`, `Platforms/Mobile`, `Platforms/macOS`, and `Platforms/tvOS`
   (including tvOS debug support).
3. Move whole-platform entrypoints/adapters/fixtures mechanically. Do not change
   behavior in the move commits.
4. Introduce one app-lifetime `AppRuntime`/`AppComposition` that owns common
   services and bootstrap state. Keep each platform `@main` focused on its real
   scene/delegate/window topology.
5. Model downloads, Cinema, SharePlay, system integrations, and platform input as
   explicit capabilities. Prefer absence/optional ownership for unsupported
   products; allow tiny no-op adapters only for genuinely best-effort APIs.
6. Stop constructing `DownloadManager`, `DownloadStore`, migrations, recovery,
   and background sessions on tvOS.
7. Remove inert SharePlay/Cinema/Reality state from non-vision products.
8. Make process lifecycle observation one aggregate scene-activity model rather
   than three identical effect triggers. It must preserve foreground truth while
   the main window and immersive scenes overlap or replace one another.

**Success evidence**

- exactly one entrypoint per target without whole-file platform guards;
- TV launch performs no download directory, index, migration, recovery, or
  background-session work;
- visionOS window teardown still preserves auth/player state through Cinema;
- mobile/vision background downloads reattach; Mac Settings shares the same
  runtime; TV fixtures still launch only in explicit UI-test mode; and
- compile time and binary-size changes are measured, not assumed.

### S2 — Platform shells, navigation, and feature state

**Goal:** keep four native shells while sharing routes, destinations, and state
transitions.

1. Split the 1,106-line `RootView` into platform shell leaves.
2. Add a typed navigation coordinator owning tab/destination selection,
   online paths, the current offline return/focus rating-key state,
   push/pop/reset/search, system entry, and Cinema return actions. Adding a new
   Offline `NavigationPath` is not part of the extraction.
3. Add a reusable browse-stack boundary that owns the session revision,
   destination construction, environment injection, and push closure.
4. Preserve platform shells: TV focus tabs, Mac split view, mobile adaptive tabs,
   and vision ornament/overlay behavior.
5. Replace Mac process-wide command notifications with direct single-window
   actions or focused-scene values after the window-model decision.
6. Extract a tested compact/regular mobile Settings transition state machine.
7. Share one narrowly scoped backend-neutral library-catalog repository across
   surfaces that currently enumerate the same sections/views. Home hubs, Search
   aggregation, and Music keep their distinct endpoints, ordering, pivots, and
   partial-failure policies.
8. Consolidate repeated TV directional-entry focus logic behind a tested helper,
   preserving Home-versus-grid validity rules.
9. Split large feature views into explicit models without wholesale rewrites:
   `DetailModel`, `DownloadOptionsModel`, `SeasonPlanDraft`, and small Settings
   sections/action models.
10. Add per-surface metric snapshots shared by live content and skeletons;
    explicit TV/vision jump-picker versus iOS index-rail adapters; and platform
    auth-control adapters. Do not flatten couch-distance, gaze, touch, and desktop
    metrics into one universal scale.

**Success evidence**

- backend/session change clears online navigation only;
- Offline state remains cross-backend;
- Siri Remote Back, Mac Command-[, mobile tab/sheet resizing, system entries,
  Cinema return, and Now Playing navigation all retain exact behavior; and
- platform shells observe only the state they render.

### S3 — Player controller, chrome, and platform presentation

**Goal:** preserve one playback engine while replacing optional/Boolean state
soup and four-platform presentation entanglement with typed boundaries.

1. Capture deterministic contracts for start, first frame, seek, restart,
   cleanup, terminal progress, track changes, system pause, PiP/AirPlay,
   Cinema, SharePlay attachment, and tvOS focus/input.
2. Remove confirmed dead state first: retired buffering compatibility state,
   permanently disabled mismatch state, unused task identity, and provably
   unreachable tvOS play/timeline chrome branches.
3. Replace overlapping player initializers and nil-combination capabilities with
   typed `.offline`, `.plex`, and `.mediaBrowser` sessions.
4. Replace restart Boolean combinations with a typed restart intent. Keep reason-
   specific deadline authority; evaluate client ABR as a removable intent family
   after measurement.
5. Introduce one canonical playback-position snapshot and one typed progress
   transition cause.
6. Consolidate subtitle/audio choices into explicit `.native`, `.backend`,
   `.offline`, and `.off` mechanisms; parse an offline subtitle only when selected.
7. Split `CustomPlayerChrome` into shared interaction/state plus Vision, Mobile,
   TV, and Mac presentation/input leaves. Do not force their layouts together.
8. Extract a `CinemaPresentationCoordinator` only after current handoff contracts
   are pinned. Keep one player/audio path.
9. Preserve separate system-media publishers for scoped visionOS versus global
   iOS/macOS, but share pure metadata snapshots, context formatting, artwork, and
   validated command intents.
10. Introduce an explicit Mac player input router with the priority
    `menu -> exit fullscreen -> close player -> pass through`.

**Success evidence**

- controller/chrome files become reviewable ownership units rather than simply
  renamed fragments;
- all backend cleanup and restart ordering remains exact;
- TV remote/focus, mobile PiP/AirPlay/rotation, Mac physical Escape/fullscreen,
  and visionOS window/Cinema/Now Playing pass their platform matrices; and
- two-AVP SharePlay remains hardware-blocked, not simulator-proven, until run.

### S4 — Backend, transport, catalog, and metadata seams

**Goal:** consolidate shared request/data execution without erasing backend wire
differences.

1. Snapshot immutable authenticated session context on `MainActor`; run transport,
   JSON decode, and DTO mapping in a Sendable executor; publish final values only.
2. Reuse one ordered bounded fan-out primitive for A-Z probes, search libraries,
   SharePlay shortlist hydration, version labels, and similar control-plane work.
3. Add a session/auth-revision-scoped library-catalog repository used only for
   the shared section/view enumeration boundary. Surface loaders retain their
   own request and presentation policies.
4. Add a metadata repository with summary/detail hydration, in-flight coalescing,
   short stale-while-revalidate policy, watched-state patching, and provenance.
   Every value is fenced to exact auth/session/server/source revision; stale data
   may paint UI but must never authorize playback or downloads.
5. Replace heavyweight `fullItem` use with named surface profiles such as grid,
   search, Home, playlist, detail, and playback, with backend wire-contract tests
   before any field is removed.
6. Make MediaBrowser Home progressive: publish available rails immediately,
   preserve successful rails during a partial failure, and retry only failed rails.
7. Make movie-version collapsing incremental and page coalescing task-based rather
   than polling.
8. Page long playlists while preserving duplicates and server order.
9. Consolidate mirrored Jellyfin/Emby browse plumbing only around their proven
   shared request factory/core; retain auth/playback/download differences.
10. Remove verified transitional wrappers and pass-through facades only after all
    production and probe callers migrate.

**Success evidence**

- zero large JSON decode/map work on the main thread;
- bounded peak request concurrency with stable result order;
- one catalog load per session generation and one detail metadata read for
  open-to-immediate-Play when context remains valid;
- progressive Home degradation rather than a slowest-rail barrier; and
- live Plex/Jellyfin/Emby probes preserve wire shape and cleanup behavior.

### S5 — Artwork and image ownership

**Goal:** one authenticated, bounded fetch/decode pipeline instead of independent
per-view requests and incompatible image caches.

1. Create an actor-backed `ArtworkPipeline` with process-local authenticated
   request identity, in-flight coalescing, per-origin concurrency, priority, and
   cancellation.
2. Cache compressed responses where appropriate and decoded/downsampled images in
   a cost-limited cache. Never log or persist credential-bearing cache keys.
3. Downsample and eagerly decode with ImageIO off the main actor.
4. Serve poster views, video/music system artwork, `AVPlayerItem` metadata,
   offline row thumbnails, and suitable chapter/trick-play consumers from shared
   fetch/decode primitives.
5. Replace the Mac `UIImage == NSImage` compatibility lie with an explicit
   `PlatformImage`/decoded-image boundary.
6. Resolve pixel size from the actual display/environment rather than assuming
   2x everywhere.
7. Share or reduce loading shimmer animation rather than running one perpetual
   animation per placeholder.
8. Make “Clear image cache” clear all owned cache layers and failure state.

**Success evidence**

- one network request per unique in-flight authenticated key;
- backend/account revision never reuses stale artwork;
- cost-based eviction survives memory pressure;
- warm reverse-scroll cache hit target is established and ratcheted after the
  first baseline; and
- fast A-Z scroll, TV rails, AVP gaze, Mac Retina, Now Playing, and offline lists
  remain visually correct.

### S6 — Downloads and offline engine

**Goal:** reduce a 36K-line app/package subsystem while preserving deterministic,
app-owned recovery.

1. Fix source ownership for all side assets before deleting or moving engine
   code.
2. Make schema 4 and the current typed task markers the only supported durable
   formats. Unsupported schemas trigger a fail-closed destructive reset: keep the
   background session dormant, cancel and drain every old task, then quarantine or
   delete the old download root before writing an empty current envelope.
3. Delete old row migrations, ownerless adoption, v1/v2 task-marker parsing,
   URL-derived task identity, and closed-range legacy resume branches after tests
   prove the reset/sanitizer ordering. Retain current exact-attempt checkpoint,
   artifact-intent replay, held-body recovery, and current task reattachment; those
   are the app-owned recovery authority that protects against native resume
   fragility, not compatibility code.
4. Decompose by ownership, not arbitrary file length:
   - task/session delegate and reattachment;
   - checkpoint/range transfer;
   - validation/promotion;
   - store/persistence;
   - side assets;
   - server preparation/cleanup; and
   - presentation snapshots.
5. Make `DownloadWorkRegistry` track ownership without forcing BIF parsing,
   writes, promotions, and chapter/tile work onto `MainActor`.
6. Batch chapter/tile metadata persistence instead of one full durable index write
   per image.
7. Derive one immutable lightweight row-presentation snapshot per refresh and
   resolve full records only for play/actions.
8. Create one storage snapshot containing durable media, side assets, held/resume
   artifacts, live OS temp, and expected reservations; choose display versus cap
   enforcement fields explicitly.
9. Make season planning reuse server invariants, use bounded item probes, compute
   one draft, and commit new rows/retry markers in one Store transaction.
10. Use rename/replace for a byte-zero completed static body after exact ownership
   revalidation; append only when a genuine nonzero checkpoint exists.
11. Reject a provably short static body before expensive HEVC/AVPlayer validation.
12. Build one typed side-asset inventory/validation/repair path for posters,
    Plex BIF, Jellyfin trick-play, Emby BIF, subtitles, and chapters.
13. Retain/memory-map one BIF index and copy only selected frames.

**Success evidence**

- exact attempt/task/store/finalizer ownership remains intact;
- durable/live/resumable byte provenance remains honest;
- off-head, force-quit, lock, wake, route change, 401/416/503, ENOSPC,
  delete/pause-near-completion, and source A-to-B replacement pass on hardware;
- optional assets never gate media completion or cross source identity; and
- main-thread side-asset work, persistence write count, copied bytes, and queue
  snapshot cost show measured reductions.

### S7 — Auth, lifecycle, persistence, preferences, and diagnostics

**Goal:** separate three backend auth flows and process lifecycle from giant
coordinators while reducing repeated secure-storage and file I/O.

1. Split selected-backend restore from demand-driven inactive-backend hydration so
   noncritical work does not compete with time-to-browse.
2. Commit a usable Plex connection before nonessential profile metadata; make
   prioritized connection racing cancel worse candidates when safe.
3. Extract `PlexAuthFlow`, `JellyfinAuthFlow`, and `EmbyAuthFlow` behind one global
   authorization generation and shared polling/commit result types.
4. Replace service-identity-based Mac development file storage with an explicit
   Debug-only build capability that fails closed in Release.
5. Add snapshot reads and one-time migration/hardening state to reduce repeated
   Keychain work; consider one encoded item per Jellyfin/Emby session only after
   migration/rollback tests exist.
6. Introduce one typed playback preference store preserving every shipped key and
   migration/default.
7. Introduce one aggregate runtime lifecycle coordinator and one idempotent
   download-recovery coordinator with typed reasons.
8. Replace synchronous open/seek/write/close per diagnostic event with one serial
   buffered writer, bounded flushes, preserved rotation/redaction, and a documented
   crash-loss window.
9. Classify download index mutations by durability tier. Retain exact barriers for
   destructive/network lifecycle edges; coalesce nonauthoritative progress and
   optional metadata only after fault-injection proves safety.

**Success evidence**

- selected backend reaches browse without waiting for unused lanes;
- stale auth attempts cannot publish or erase credentials;
- Release Mac never silently falls back to file credentials;
- duplicate scene/ready/active events run one recovery pass;
- enabled diagnostics have bounded I/O and background completion remains bounded;
  and
- power-loss/fault tests preserve all exact durability boundaries.

### S8 — Test, fixture, and build-tool simplification

**Goal:** make the verification system cheaper and more truthful before it becomes
the gate for the performance program.

1. Add visionOS-hosted deterministic coverage or move all suitable policy into
   PMSKit and retain only narrow vision integration tests. The primary platform
   cannot remain the only app without a hosted test strategy.
2. Create one native Apple matrix driver with smoke, affected-platform, and full
   tiers; include visionOS, mobile, tvOS, Mac, hosted tests, and PMSKit.
3. Split pure, app-core, filesystem/background, live-probe, and UI/platform tests
   by ownership. Do not count credentialless live-probe returns as ordinary passes.
4. Move timing benchmarks out of ordinary correctness suites into optimized,
   structured benchmark targets.
5. Consolidate common test support: temporary directories, deterministic clocks,
   gates, locked boxes, and network stubs.
6. Make tvOS evidence swizzling explicit opt-in; retain a small PR UI smoke plan
   and move exhaustive focus/remote sweeps to full/manual tiers.
7. Retire keyboard-bisection fixtures and issue-era Mac validation naming only
   after their acceptance gates close.
8. Avoid duplicate strict docs builds across CI jobs while keeping one canonical
   local/full validation command.

## Performance audit and optimization workstreams

Performance optimization begins after the relevant simplification workstream is
stable. Baselines use the immutable chain defined above: original audited control,
post-safety/pre-structural control with final instrumentation,
simplified-but-unoptimized candidate, and each optimization slice.

### P0 — Measurement system

This workstream is a hard prerequisite to every runtime baseline.

1. Add an optimized `PerformanceAudit`/Profile configuration with privacy-safe
   signposts and no TV evidence swizzle or verbose debug probes. It must match
   Release optimization, entitlements, dependencies, and signing behavior,
   differing only by the profiling compilation condition. Add an automated
   binary/launch-contract check proving that UI fixtures, live probes, TV event
   swizzling, and verbose Debug evidence logging are absent.
2. Extend instrumentation to process launch, service composition, selected-backend
   restore, first render, first/complete Home content, catalog, search, metadata,
   decode/map, artwork cache/decode, music start, playback decision/first frame,
   seek/restart, Cinema entry/steady state, SharePlay lookup/attachment, download
   persistence/finalization, diagnostics, and background recovery.
3. Record the full run metadata defined in the committed comparison protocol
   below, outside sensitive logs.
4. Upgrade summary tools so they accept two explicit commits/artifact manifests,
   reject mismatched machine/toolchain/configuration/scenario/cache metadata, and
   emit paired baseline/candidate JSON/CSV tables plus explicit insufficient-data
   results. The current compile runner's single-`HEAD` snapshot is not a paired
   verdict.
5. Add tests for phase stability, field sanitization, exactly-once span completion,
   cancellation/failure, malformed input, and zero debug-evidence noise in the
   profiling configuration.
6. Evaluate bounded privacy-safe MetricKit launch/hang/CPU/disk/memory summaries;
   keep them local/user-exported unless separately approved. MetricKit is delayed,
   aggregated longitudinal health evidence; it must not approve or reject one
   optimization slice.

#### Committed comparison protocol

- **Short latency scenarios:** three warmups followed by at least 20 measured
  runs per artifact. Use a seeded blocked random order that alternates artifacts
  on the same device rather than running every baseline sample first.
- **Long soak, energy, thermal, and destructive lifecycle scenarios:** one warmup
  plus at least five measured runs when repeatable. Report every value and the
  median; do not report p95 below 20 measured successes.
- **Failures and timeouts:** retain them as a separate failure-rate result and
  treat any new failure mode as a regression. Never drop a failure and then call
  the remaining latency distribution faster.
- **Intervals and decision rule:** use paired bootstrap confidence intervals with
  10,000 resamples. Before running a candidate, freeze the minimum detectable
  effect as the larger of 5% or twice the control interval width. Accept a
  performance claim only when the paired interval excludes zero, exceeds that
  frozen effect, and correctness/failure gates remain green.
- **Run metadata:** exact commit and product checksum, tool/schema version,
  platform and OS build, Xcode build, privacy-safe local device label, power
  source, battery/thermal state, free storage, display mode, install/container
  state, cache-reset command and result, backend/server version where applicable,
  scenario/fixture identity, and profiling configuration. Publish only the
  reviewed nonsensitive subset.
- **Deterministic fixtures:** generated 1K/10K/50K catalogs, fixed slow/failing-
  rail delays, fixed query-replacement schedule, declared cache seeds, expected
  request counts, and a privacy-safe media capability corpus recording route,
  codec/container, HDR/audio/subtitle facts, local fixture hash, start/first-frame/
  terminal markers, and cleanup proof.
- **Live servers:** separate wire/acceptance evidence. Mutable content and network
  latency cannot replace deterministic performance fixtures.
- **Evidence artifact:** write into a stable ignored run directory containing a
  versioned manifest, checksums, tool version, raw artifact pointers, privacy-
  review status, retention deadline, and redacted-summary pointer.

### P1 — Launch, restore, and idle energy

Measure and improve:

- cold/warm launch to first usable browse;
- time and work spent constructing services by target;
- selected-backend restore versus inactive hydration;
- Keychain reads/migrations and Plex connection/profile work;
- TV launch after removing downloads;
- duplicate lifecycle/recovery emissions;
- idle wakeups from polling/timers; and
- diagnostics enabled/disabled overhead.

Primary suspected wins are absent TV downloads, one aggregate scene-activity owner,
demand-driven inactive hydration, prioritized Plex connection racing, and removal
of duplicate clocks/polls.

### P2 — Home, library, search, detail, and artwork

Deterministic fixtures own regression verdicts; live-server runs separately prove
current wire behavior. Scenarios:

- cold/warm Home with one slow and one failing rail;
- 1K/10K/50K libraries, multi-version movies, rapid scroll, and A-Z jumps;
- search across 1/4/8/12 libraries with rapid query replacement;
- Home/Search to Detail to immediate Play;
- long playlists and music screens; and
- backend/account switch during every in-flight category.

Metrics:

- first-content and complete p50/p95;
- HTTP count, bytes, TTFB, peak concurrency, cancellation latency;
- catalog/metadata/artwork cache hits and in-flight joins;
- decode/map/image-decode duration and main-thread time;
- SwiftUI body invalidations and large-array publications;
- allocations, resident/peak memory, hitches, and GPU/offscreen cost; and
- Spotlight work on the browse critical path.

Candidate optimizations include bounded/slim search, incremental Home, task-based
page coalescing, incremental movie collapsing, lazy long lists, narrow observable
snapshots, and the shared artwork pipeline.

### P3 — Playback, player UI, Cinema, and system media

The primary polling hypotheses are the 500 ms scrubber/System Now Playing loop at
`Labstream/Shared/Player/CustomPlayerView.swift:286-299` and the 250 ms visionOS
SharePlay attachment loop at `CustomPlayerView.swift:331-368`. Event-driven
replacement is a measured hypothesis, not an assumed win; the current loops also
carry load-bearing recovery and delayed-attachment behavior.

Scenarios:

- direct/progressive/copy/transcode start and resume on all backends;
- first frame, deep seek, quality/track restart, fallback, stall, network loss,
  and close during reopen;
- 30-minute play/pause with Stats closed/open;
- PiP, AirPlay, background/interruption, Control Center/media keys;
- tvOS remote scrubbing/auto-hide and physical HDR/audio;
- visionOS window/Cinema handoff, placement adjustment, long Cinema soak, system
  Now Playing, and SharePlay; and
- local/offline playback with subtitles and trick-play.

Metrics:

- decision-to-first-frame and seek-to-frame p50/p95;
- restart count/reason, server encoder count, and ABR benefit/cost;
- CPU, wakeups, energy, thermal state, memory, and frame hitches;
- Now Playing publication count and artwork requests;
- HDR probe count/concurrency and access-log work;
- attachment/placement update counts; and
- progress request count/order/position.

Candidate optimizations include one controller clock, event-driven Now Playing,
single-flight HDR probing, event/revision-driven SharePlay attachment, bounded
Cinema placement, off-main trick-play/chapter decode, shared player artwork, and
removal of client ABR if its measured value is poor.

### P4 — Network proxy and transport

1. Instrument control-plane versus artwork versus streaming versus background
   transport profiles without logging request identity.
2. Verify request deadlines with a hanging transport, fix only if needed, and land
   generation-safe session rotation before benchmarking.
3. Stream loopback media bodies with bounded buffers/backpressure; buffer/rewrite
   playlists only.
4. Make the loopback origin own accepted connection tasks and provide an awaited
   stop boundary.
5. Add bounded retry only for declared-idempotent operations and respect
   `Retry-After`.
6. Compare first byte, first frame, peak RSS, copies, allocations, cancellation,
   sibling isolation, and behavior with 64/256 MiB fixtures.

### P5 — Downloads, offline, persistence, and storage

Scenarios:

- 100+ rows and multiple multi-GB transfers;
- 20-30 episode planning and mixed existing/failed rows;
- foreground/off-head/lock/sleep, OS suspension/termination, user swipe-force-
  quit, relaunch, and network change as separate lifecycle cases with separate
  expected results;
- pause/delete near completion, source replacement, disk pressure, and auth loss;
- largest BIF repeated scrub; and
- enabled diagnostics during active transfer.

Metrics:

- temp-directory scans, filesystem stats, snapshot construction cost;
- index encode/fsync count/latency and bytes encoded;
- main-thread file/decode time;
- bytes copied during checkpoint/final commit;
- finalizer duration, HEVC scan bytes, AVPlayer probe count;
- side-cache RSS, allocation, repair request count, and BIF first-preview time;
- season-planner request count and admission transaction count; and
- honest durable/reserved/live-temp storage totals.

Candidate optimizations include gating expensive health inventory before the
60-second cadence, batched side-asset metadata, lightweight row snapshots,
off-main side-cache work, rename-at-zero commit, early short-file rejection,
BIF index reuse, and durability-tiered persistence with fault-injection gates.

### P6 — Compile, test, and developer throughput

- paired compile audit for PMSKit and all four app targets;
- cold, no-op, and representative incremental changes;
- per-target source topology and platform-chrome split impact;
- smoke/affected/full test wall time and flake rate;
- tvOS UI smoke versus exhaustive plan time;
- test-source duplication and live-probe isolation; and
- docs/CI duplicate work.

Run at least five cold, five no-op, and five representative incremental compile
samples per artifact in seeded alternating order. Run timing-sensitive test plans
at least five times with automatic retry disabled. Report product/test failures
separately from runner, simulator, and infrastructure failures, and freeze timeout
policy before comparison.

Compile-time improvement is valuable but never a substitute for runtime or
correctness evidence.

## Execution waves

```mermaid
flowchart LR
  accTitle: Simplification and performance execution order
  accDescr: Safety and baseline work precede structural simplification. The simplified app is then measured and optimized before physical acceptance and documentation closeout.
  A["Wave 0: Safety fixes and control baselines"] --> B["Wave 1: Source topology and app capabilities"]
  B --> C["Wave 2: Data, catalog, transport, and artwork"]
  B --> D["Wave 3: Shells, player, and platform presentation"]
  C --> E["Wave 4: Downloads, auth, lifecycle, and persistence"]
  D --> E
  E --> F["Wave 5: Simplified-app performance baseline"]
  F --> G["Wave 6: Measured optimizations"]
  G --> H["Wave 7: Physical acceptance and docs closeout"]
```

### Wave 0 — Safety and controls

- Reproduce `SAFE-01` through `SAFE-10` with focused tests, then resolve confirmed
  findings or retire disproven hypotheses as focused changes.
- Land the optimized performance configuration, comparison tooling, fixture
  corpus, artifact contract, and committed protocol above before recording any
  runtime baseline.
- Decide and record the available physical inventory. Use repeated paired runs on
  one device where only one exists; mark unavailable classes blocked before
  defining budgets rather than claiming a device distribution.
- Freeze the exact original and post-safety control commits and record their
  visual/focus/behavior snapshots.
- Land S8's matrix driver, benchmark separation, TV evidence opt-in, shared test
  support, and an explicit visionOS hosted-test/policy-migration strategy.
- Add missing deterministic contracts, especially tvOS, playback, Cinema,
  downloads, SharePlay messaging, and visionOS integration.

### Wave 1 — Mechanical ownership

- Create platform source roots and move whole-platform files.
- Introduce `AppRuntime` and capability composition.
- Remove TV download construction and inert non-vision spatial/SharePlay objects.
- Decide the Mac window model and remove the already-retired Reality Theater
  prototype plus its cross-target plumbing while retaining shipping
  `CustomCinemaMode`.
- After platform-root target membership becomes exclusive, close the capability
  gate only with all of these structural assertions:
  - the tvOS app compile-input list contains no
    `Labstream/Capabilities/Downloads/` source; its linked app has no app-owned
    `DownloadManager`/`BackgroundDownloadSession` symbols, while the first-render
    smoke still reaches the streaming UI;
  - the iOS/iPadOS, macOS, and tvOS app compile-input lists contain no
    `Labstream/Platforms/visionOS/SharePlay/` source and no app-facing Cinema source
    (`CustomCinemaMode.swift` or `CinemaAppRouting.swift`); the visionOS list
    contains the real SharePlay and Cinema sources exactly once (PMSKit's
    cross-platform pure SharePlay/Cinema policies are intentionally not part of
    this exclusion);
  - all four target builds pass after the exclusions. `CinemaAppRoutingTests` retains exact
    online-tab, offline-rating-key, autoplay, system-entry-fallback, and missing-item-no-op
    assertions behind `#if os(visionOS)`, but the matrix must continue to report them as planned,
    not executed, until a visionOS-hosted app test target exists.

#### Wave 1 implementation journal

Wave 1 is implementation-complete in the audit worktree. It established six
non-overlapping production roots: universal `Shared`, the download-capable
`Capabilities/Downloads` root, and one owner root for each of visionOS, Mobile,
macOS, and tvOS. The app targets now own exactly `Shared` plus their platform
root; visionOS, Mobile, and macOS additionally own Downloads, while tvOS does
not. No production membership exception is used to approximate this boundary.

The behavior-bearing ownership changes are also complete:

- one app-lifetime `AppRuntime` owns common service identity and bootstrap state;
- tvOS constructs and ships no app-owned download graph and exposes no Offline
  or season-download surface;
- Cinema and SharePlay app sources compile only into visionOS, shipping
  `CustomCinemaMode` remains intact, and the unrelated hidden Reality Theater
  prototype is deleted;
- mobile orientation ownership is iOS-only with the old non-iOS no-op removed;
- one aggregate scene-activity owner prevents main-window/Cinema/Settings
  handoffs from producing false download foreground/background transitions; and
- macOS now has one reusable browse/player window plus singleton Settings.
  Close and Command-W hide the retained main graph; Dock reopen, commands, and
  system entries reactivate that exact window without duplicating it.

Fresh isolated clean builds completed on 2026-07-22 at 01:50 +04. Their generated
app-target `SwiftFileList` manifests were inspected directly after the source split.
The manifests remain local build products; this bounded summary records the
compile-input evidence without committing machine-specific paths or giant file lists.

| App target | Shared Swift | Downloads Swift | Owned platform Swift | Other platform roots | Clean gate |
| --- | ---: | ---: | ---: | ---: | --- |
| visionOS | 116 | 35 | 8 visionOS | 0 | `build` passed |
| iOS/iPadOS | 116 | 35 | 3 Mobile | 0 | `build-for-testing` passed |
| macOS | 116 | 35 | 5 macOS | 0 | `build-for-testing` passed |
| tvOS | 116 | 0 | 5 tvOS | 0 | `build-for-testing` passed |

This proves the post-split target inputs: downloads are absent from tvOS, and no
app target compiles another platform's owner root. Deterministic topology tests
also enforce those memberships and keep the visionOS-hosted Cinema suite visibly
`planned` until that host exists.

Adversarial review found and closed four integration defects before the final
gates: unfavorable scene-handoff ordering, last-scene activity retention, a
reachable tvOS season-download action without a manager, and Mac system entries
reopening underneath a retained player. It also found a pre-existing flaky
SideAsset test handshake; the test now waits for the observable queued waiter
instead of assuming `Task.yield()` establishes actor ordering. The formerly
flaky test passed 1,000 focused repetitions, its full coordinator suite passed
2,500 test executions, and the complete Mac plan passed three fresh post-fix
repetitions.

Automated and runtime evidence at the Wave 1 closeout:

- PMSKit: 1,668 Swift Testing tests in 219 suites plus 92 XCTest tests, all green;
- Mac hosted plan: three post-fix repetitions, each 352 Swift Testing plus 26
  XCTest tests, all green;
- script suite: 86/86; focused topology/matrix suite: 22/22;
- fresh clean visionOS build, iOS build-for-testing, macOS build-for-testing,
  and tvOS build-for-testing: all green;
- exact-worktree passive smokes on visionOS, iPhone, iPad, and tvOS: all four
  built from fresh isolated DerivedData, installed with matching binary UUIDs,
  survived launch, rendered expected UI, and produced no relevant crash/fatal
  log match; and
- tvOS season-absence test: 5/5 focused repetitions; full TV UI suite: 18/18.
  Xcode printed the complete green full-suite summary but hung in diagnostic
  finalization, so the text log is authoritative and the full-suite xcresult is
  deliberately not claimed as valid. The focused xcresult is valid.

Raw screenshots, logs, DerivedData, and xcresults remain local under
`/tmp/labstream-validation/audit-simplification-performance/`; only bounded,
privacy-safe counts are recorded here. No simulator remains booted.

Wave 1 does not claim physical-device acceptance. Real Vision Pro Cinema
placement/adjustment, Crown/system dismissal, and window-to-immersive handoff;
two-Vision-Pro SharePlay; authenticated Mac playback/download survival across
close/reopen; mobile background transfer reattachment; and physical Apple TV
remote/focus behavior remain explicit later acceptance gates rather than failed
or simulator-proven checks.

### Wave 2 — Shared data plane

- Keep behavior-neutral ownership extraction separate from progressive/caching/
  execution changes. Every semantic or performance-affecting slice in this wave
  compares against the frozen post-safety control and has independent behavior
  gates; Wave 5 then establishes the new consolidated simplified baseline.
- Move decode/map off main.
- Bound request fan-out.
- Add catalog/metadata repositories and progressive Home.
- Add shared artwork pipeline and explicit platform image boundary.
- Fix page/task coalescing and incremental movie collapsing.

#### Wave 2 audit and implementation journal

Wave 2 began from committed Wave 1 base `507b149a`. A parallel read-only inventory covered
session authority, decode/map execution, catalog and metadata duplication, progressive Home,
fan-out/paging/collapsing, artwork ownership, image compatibility, tests, performance tooling,
and current-document drift. It produced these ordering constraints:

- establish exact opaque session authority before adding any cache or in-flight repository;
- move decode/map behind immutable Sendable execution seams before changing fan-out timing;
- keep catalog enumeration, metadata hydration, progressive Home, page coalescing, movie
  collapsing, and artwork adoption as separate rollback boundaries;
- stale metadata may paint only within the exact same authority and must never authorize Play,
  Download, watched mutation, Spotlight, or SharePlay matching; and
- Plex native `/hubs` remains server-composed; progressive Home applies only to the independent
  Jellyfin/Emby rail requests.

Wave 2 implementation slices were committed at `e6e67519`:

1. `AppModel` vends an immutable `AuthenticatedBrowseSessionContext` with an opaque process-local
   authority. Production auth apply/select/clear paths publish multi-field Plex/Jellyfin/Emby lane
   changes coherently; token A-to-B-to-A, server/base/user/client changes, sign-out/reauth, backend
   selection, and inactive-lane isolation have deterministic tests.
2. Plex, Jellyfin, and Emby now decode/map browse responses behind immutable Sendable execution
   seams. The Jellyfin/Emby facades snapshot session plus transport into
   `MediaBrowserBrowseCore`; `PlexBrowseService` pins session plus client identity and keeps its
   existing MainActor transport callback while `PlexBrowseResponseExecutor` performs JSON decode
   and normalization off the main actor. Request shape, ordering, typed errors, transport
   isolation, and cancellation fences are pinned. This is an execution-boundary improvement only;
   no runtime speedup is claimed before paired evidence.
3. The open Emby warped-poster defect, GitHub #245, was confirmed as an image-type selection and
   request-aspect mismatch rather than a cache problem. Home now prefers portrait season/series
   Primary art and keeps Thumb/Backdrop fallbacks at 16:9 request and presentation dimensions.
   Automated policy/request/mapping and hosted-app gates pass, but the issue remains open until its
   required physical-iPhone Emby check plus movie and episode-fallback regressions are recorded.
4. One ordered bounded fan-out now has explicit fail-fast and partial-result APIs. MediaBrowser
   search and all three video/music A-Z probe paths cap active work at four while retaining server
   order, all-or-error search, failed-letter degradation, and cancellation behavior.
5. A behavior-neutral `LibraryCatalogLoader` normalizes one native section/view enumeration, and
   the app-lifetime `LibraryCatalogRepository` now shares the exact-authority value/in-flight read
   across Libraries, MediaBrowser Home, Search, Music, the Mac sidebar, visibility editing, system
   entries, and Watch Together. Backend/authority mismatches, delayed old work, queued forced work
   after auth replacement, failures, cancellation, and force-refresh chains are fenced; each
   surface's query, visibility, ordering, and destination policy remains outside the repository.
6. Current docs are updated continuously rather than deferred: the Wave 1 target topology, tvOS
   streaming-only boundary, simulator/test lanes, single-window Mac model, and current source map
   have been reconciled; Wave 7 remains the final whole-repository sweep and archive step.
7. Jellyfin/Emby metadata fields now use intent-bearing `grid`, `search`, `home`, `playlist`,
   `item`, `relatedMedia`, and `music` profiles. Every profile is currently an exact alias of the
   pre-slice grid/full field bytes; purpose-routing tests prevent a later Home trim from silently
   changing Music, item hydration, downloads, playback probes, or Detail extras.
8. Sparse library pages now use one model-owned task flight per page instead of 50-ms polling.
   Duplicate callers share one fetch/commit, a cancelled waiter cannot poison a surviving waiter,
   last-waiter/reset cancellation releases the flight, stale completions are fenced, and the prior
   one-retry rail-jump contract is retained for failures and short successful pages. This removes
   polling and duplicate work; no runtime speedup is claimed before paired evidence.
9. Shared image values now cross an explicit immutable `DecodedImage` boundary instead of the
   macOS `UIImage == NSImage` compatibility alias. Native AppKit/UIKit values exist only at
   framework bridges; orientation, scale, wide-gamut/high-depth color, CMYK fallback, crop, JPEG,
   fetch, and cache behavior are pinned as a behavior-neutral extraction. All-target builds and
   smokes remain required before this slice is accepted.
10. Movie-version collapsing now retains stable identity/group indexes and publishes only the
    projection positions touched by each new page rather than re-collapsing all prior raw items.
    First-seen representatives/order, progressive version chooser updates, dense monotonically
    growing slots, final alphabet offsets, partial-prefix failure behavior, and reset/source fences
    remain pinned. Work is proportional to new items plus the immutable snapshots for touched
    version groups; the plan does not make a false strict-linear claim for a pathological group.
11. `MediaArtwork` now produces authenticated ordinary-poster descriptors with a token-free task
    identity containing backend, opaque authority, purpose, source digest, and requested pixels;
    debug strings, reflection, transport failures, and cache keys cannot reveal the private
    request. The app-lifetime actor-owned `ArtworkPipeline` performs exact joins, independent
    waiter/last-waiter cancellation, priority admission under one four-request ceiling per
    canonical origin, off-main ImageIO downsampling/eager decode, actual-display-scale requests,
    bounded compressed/decoded/definitive-4xx caches, and epoch-fenced clear through a
    nonpersistent ephemeral session. Ordinary `PosterImage`, music/video system Now Playing,
    `AVPlayerItem` external metadata, offline rows, and offline player artwork now share that
    boundary, including visionOS scoped metadata. Exact descriptor, pipeline, consumer-generation,
    and current-item fences cover both success and terminal-failure publication. Settings clears
    the one app-lifetime pipeline; persisted `posterGeneration` prevents same-path/same-byte-count
    offline replacement aliases; and one reference-counted shimmer clock spans the root UI plus
    visionOS Custom Cinema ImmersiveSpace while Reduce Motion remains static. AVKit-hosted
    chapter stills remain request-backed because they lack the injected pipeline/pixel contract.
    BIF and sprite-sheet providers, Emby generated per-position frames, Emby online/offline chapter
    fallback, and the player nearest-frame cache remain provider-scoped time-indexed exceptions
    rather than `ArtworkPipeline` consumers. Authenticated requests use the nonpersistent side-asset
    transport. Wave 3 retained those provider-scoped boundaries while adding byte-and-entry-cost
    cache limits, eager off-main preview decode, one-backing BIF indexes, mapped offline BIF reads,
    and selected-frame copying. Largest-BIF/tile-sheet peak-RSS validation remains a Wave 5
    measurement gate; the structural work alone is not claimed as a runtime win. `DecodedImage`
    use in those paths is an image boundary, not pipeline migration; downloaded
    image-payload validation remains Wave 4 side-asset work.
12. The paired measurement gate now regenerates strict summaries from exact checksummed raw
    captures, requires an opaque run/workload/launch marker plus closed privacy and correctness
    profiles, freezes a deterministic control-only MDE artifact, validates seeded same-index order
    and pairwise device covariates, and emits provenance-complete JSON/CSV. Invalid evidence is
    insufficient rather than a regression/improvement. The current schema cannot machine-prove
    that freezing preceded candidate capture, so results disclose that timing as operator-attested.
13. Jellyfin/Emby Home now builds one stable, duplicate-safe rail plan and reduces keyed results
    into canonical order while retaining pending, empty-success, failure, completeness, degraded,
    and authoritative state separately. Resume, next-up, and per-library latest work share one
    four-request ceiling; successful rails publish as each completion arrives, and one automatic
    retry requests only failed keys while preserving successful and empty-success rails. Exact
    authority, generation, and attempt fences reject late/third-pass results, and Home pins only a
    complete non-degraded identity. Plex native `/hubs` is unchanged.
14. The app-lifetime `MetadataRepository` joins exact backend/opaque-authority/item native reads.
    Display hydration reuses values for ten seconds, then can immediately paint bounded stale data
    through sixty seconds while one refresh runs; Detail visibly joins that refresh before actions
    re-enable. Authoritative callers ignore completed cache values. Provenance, source revision,
    TTL, item, and authority admission prevent reused/stale/patched/superseded values from
    authorizing actions, while an exact current native Detail value supports immediate Play without
    a second read. Accepted watched mutations patch only exact presentation state, reconcile with
    older flights, and never become action authority.
15. Plex, Jellyfin, and Emby playlist requests now expose native start/limit paging through a
    dedicated positional `PlaylistPagingModel`. More-than-200-row fixtures, duplicates spanning
    page boundaries, server order, clamped pages, retry, cancellation, generation, and opaque
    authority replacement are pinned. Page zero paints progressively, but Play/Shuffle/row/queue
    actions retain the old complete-list semantic.
16. The durable slices above have focused package/hosted tests and adversarial review at their
    owning boundaries, followed by a final independent closure audit with no remaining blocker.
    Automated product acceptance is complete: PMSKit passed 1,678 tests in 219 suites; clean
    isolated visionOS, iOS/iPadOS, tvOS, and macOS builds passed; Mac hosted tests passed 499 tests
    in 50 suites; iPhone hosted tests passed 485 tests in 47 suites; tvOS hosted tests passed 229
    tests in 25 suites; and both tvOS launch/remote fixture UI tests passed. Exact worktree
    simulators then passed install/build UUID, bounded-log, live-process, and screenshot smokes on
    visionOS, iPhone, iPad, and tvOS, with all four shut down afterward; the isolated unsigned Mac
    matrix product also launched and remained live on the host before explicit termination. The
    iPhone test run's Xcode diagnostic collector stalled after every selected test had passed; it
    was terminated independently, after which `xcodebuild` finalized the result as `TEST
    SUCCEEDED`. Strict MkDocs, 14/14 Mermaid rendering, generated-site links/anchors across 24
    pages, all 107 repository-hygiene tests, and `git diff --check` pass. Optional live-backend and
    physical-device gates remain without weakening this automated acceptance. In particular,
    GitHub #245 stays open until the physical-iPhone Emby poster matrix in item 3 is recorded.

The deeper inventory found duplicate catalog reads across Libraries, Mac sidebar, visibility,
Home, Search, and Music; uncached repeated detail metadata reads; a slowest-rail Jellyfin/Emby Home
barrier; unbounded search and 26-letter probes; 50-ms page polling; quadratic whole-history movie
collapsing; eager unpaged playlists whose duplicates cannot use the deduplicating rail model;
fragmented artwork fetch/decode/cache ownership; stale same-path offline poster caching;
unvalidated downloaded image payloads; per-placeholder perpetual shimmer; and incomplete
image-cache clearing. The catalog-adoption, metadata, progressive-Home, bounded-fan-out,
page-flight, incremental-collapse, playlist, `DecodedImage`, actor artwork core, named consumer
adoption, offline poster generation, unified clear, and shared-shimmer slices now address their
corresponding findings. AVKit-hosted chapter stills, BIF and sprite-sheet providers, Emby generated
per-position frames, Emby online/offline chapter fallback, and the player nearest-frame cache retain
explicit provider-scoped time-indexed boundaries. Wave 3 added byte-cost eviction, off-main eager
preview decode, one-backing/mapped BIF indexes, and selected-frame copying while retaining those
boundaries. Largest-BIF/tile-sheet peak-RSS validation remains a Wave 5 measurement gate, while
downloaded side-asset validation is deferred to Wave 4.
None of these structural changes is treated as a runtime performance win until the paired
comparison gate produces valid evidence.

### Wave 3 — Presentation and playback structure

- Split platform shells and shared navigation coordinator.
- Introduce typed playback sessions/restart/track models.
- Split platform chrome leaves.
- Consolidate system-media pure policy while retaining publishers.
- Centralize Cinema transition ownership only after contract tests.

#### Wave 3 implementation journal

Wave 3 began from committed Wave 2 base `e6e67519`. Parallel read-only inventories covered native
shell/navigation ownership, playback sessions/restarts/position/tracks, player chrome, system-media
publication, visionOS Cinema transitions, and preview/BIF memory structure. Implementation kept
platform-native layout and input behavior in exclusive leaves while sharing only typed state and pure
policy:

1. `RootView` is now a small common composition wrapper. A typed `RootNavigationCoordinator` owns
   destination selection, session-scoped online paths, Search transitions, system-entry fencing,
   Cinema return, and Offline focus; `BrowseNavigationStack` owns the common session/destination
   boundary. Mobile, Mac, TV, and visionOS retain exclusive native root shells.
2. Playback construction uses explicit Plex, MediaBrowser, and Offline session sources rather than
   mutually exclusive optionals. Restart recipes, position evidence/seek holds, progress causes, and
   subtitle/audio mechanisms are typed and contract-tested. Offline subtitle payloads parse only on
   selection, and async subtitle/audio changes use latest-intent plus serialized server authority so
   stale work cannot overwrite local or account-sticky track state.
3. `CustomPlayerChrome` is split into shared interaction/components/menus and target-exclusive
   Mobile, Mac, TV, and visionOS leaves. Mac Escape routing is explicitly ordered as menu, exit
   fullscreen, close player, then pass through; TV focus and native remote behavior remain TV-owned.
4. Global iOS/macOS and scoped visionOS system-media publishers remain separate. They consume shared
   pure Now Playing snapshots and typed command profiles, while token-fenced controller events replace
   the former 500-ms global metadata polling dependency; the UI scrubber clock remains unchanged.
5. An app-lifetime visionOS `CinemaTransitionCoordinator` is the single mutable transition owner.
   Open confirmation and matching-generation immersive appearance are both required before the player
   window detaches; stale scaffolds cannot bind callbacks or attachment work; exit finalization remains
   exact-once in leave, stop, route, reopen, clear order with the same controller/player/audio path.
6. Provider-scoped trick-play caches now enforce byte and entry limits. BIF indexes retain one backing
   payload, map offline files where safe, and copy only the selected frame; Jellyfin sheets and final
   previews eagerly decode off-main with cancellation and publication-generation fences. Peak RSS and
   first-preview latency remain Wave 5 measurement work rather than asserted improvements.
7. Deterministic policy/controller tests cover the new navigation, session, restart, position, track,
   system-media observer, Cinema, eager-decode, cache, and BIF contracts. Source topology, affected-lane
   selection, PMSKit correctness, all four generic target builds, Mac hosted tests, and documentation
   hygiene are the automated acceptance boundary. visionOS-hosted execution and physical AVP/Siri
   Remote/system-surface acceptance remain explicit later gates rather than simulator claims.

### Wave 4 — Heavy coordinators and durable state

- Decompose download ownership and side assets.
- Simplify season planning/storage/presentation snapshots.
- Split auth flows and selected/inactive restore.
- Consolidate lifecycle/recovery, preferences, buffered diagnostics, and
  durability tiers.

#### Wave 4 foundation checkpoint journal

1. Download startup now probes the index before mutation. Unsupported schemas remain dormant while
   all OS tasks drain, then the opaque root is durably quarantined and replaced by a protected empty
   schema-v4 root; unreadable/current-malformed data fails closed. Cleanup authority lives outside
   the versioned root, quarantine reclamation is resumable by durable name, and task adoption accepts
   only current exact-attempt markers. The app-owned checkpoint/range engine remains unchanged.
   Residual per-row reset/migration APIs, ownerless mutation/removal paths, legacy index decoding,
   string attempt-ID projections, and URL/old-marker task adoption have now been deleted. Current
   malformed rows remain fail-closed and unsupported top-level schemas still take the whole-root
   destructive-reset path.
2. `DownloadItemPlanner` uses an injected nonpersistent executor instead of `URLSession.shared`;
   credential-bearing redirects are restricted to same-origin semantics-preserving 307/308 hops.
3. Side-asset repair is off-main, payload-validating, complete across poster/subtitle/chapter/BIF/
   trick-play inventory, exact attempt/source/resource budgeted, generation-fenced, and batched.
4. Download options use a typed resolved selection. Season review captures an immutable draft with
   exact retry attempts; new rows and retries persist as one transaction before admission. Offline
   snapshots are scalar/lightweight and actions resolve exact attempt identity; storage snapshots
   distinguish known, unknown, and not-applicable values.
5. Launch restores the selected auth lane first and demand-hydrates only inactive backends with
   durable active work. One global attempt authority fences stale auth publication, Plex publishes a
   usable connection before optional profile metadata, and Release refuses Mac development-file
   credential storage/import. `AuthorizationPollingCoordinator` now separately owns the one live
   backend polling task and rejects stale exact-owner finish/cancel requests.
6. Aggregate lifecycle recovery is typed while preserving the 500 ms scene-handoff grace.
   Preferences use typed keys without changing shipped raw keys/defaults, diagnostics use a bounded
   serial buffer, and durability tiers explicitly separate barriers, recoverable checkpoints,
   best-effort state, and ephemeral state.
7. `BackgroundDownloadWakeCoordinator` now privately owns the background completion gate, deferred
   exact-attempt revalidation keys, and range-rebuild grace generations. Persistence, callbacks,
   diagnostics, and timer effects remain in the session and execute only after the coordinator lock
   is released.
8. `EmbyConvertCleanupJournal` now owns its own lock and cleanup-authority file I/O, so durable
   read-modify-write transactions no longer block unrelated `DownloadStore` index reads while
   preserving exact-UUID ambiguous-write reconciliation.
9. `DownloadKeepaliveCoordinator` owns Jellyfin/Emby exact-attempt task registries, generation-safe
   self-removal, and credential-generation quarantine. The manager now uses narrow reconcile,
   start, cancel, and health-count operations.
10. `EmbyConnectAuthFlow` privately owns pending Connect secrets, linked-server selection authority,
    server resolution, and exchange. `AuthManager` retains global attempt/publication authority and
    the sole polling-task coordinator; cancellation is rechecked before every follow-up network hop
    and secure runtime commit.
11. The background session no longer accepts ignored caller destinations: every transfer resolves
    its exact-attempt working file from the store. The dead compile-time static-range regime and
    unsafe closed-segment resume-blob retry/adoption branches are gone; known totals always use the
    bounded train and unknown totals keep the open-ended durable-checkpoint fallback. Closed trains
    also skip the obsolete pause-watermark aggregation because no segment blob is persisted.
12. The final serial automated gate passed: 1,643 PMSKit tests / 202 suites, focused Mac download
    coordinator/startup tests, generic visionOS and iOS arm64 builds, tvOS arm64 build-for-testing,
    and repository hygiene/documentation checks. Download-only coordinator tests are explicitly
    excluded from the tvOS test lane alongside the production capability. Physical-device and
    suspension/relaunch runtime acceptance remain later explicit gates; no measured performance
    claim is made by Wave 4.

### Wave 5 — Re-baseline the simplified app

- Repeat every control scenario on the simplified/unoptimized code.
- Attribute structural wins and regressions before additional tuning.
- Establish budgets from the available-device paired results, then ratchet rather
  than inventing ungrounded absolute thresholds.

#### Wave 5 readiness audit journal

1. The Release-parity `PerformanceAudit` configuration, binary/manifest guard, strict raw-summary
   binding, frozen-MDE workflow, and seeded paired comparator remain valid foundations. The current
   nine spans cover only broad browse, artwork, and playback latency; they do not yet make launch,
   idle energy, Search, transport, downloads, persistence, storage, Cinema placement, SharePlay,
   wakeups, RSS, or compile/test throughput comparable.
2. Existing span integrity must be repaired before capture: current Home and Detail success fields
   exceed the closed schema, begin-only dimensions disappear from comparable records, several stale
   returns can leave spans open, and a value-type span can be ended more than once. Instrumentation
   and deterministic workloads must be applied identically to both artifacts before paired evidence.
3. Runtime comparisons use `40af93f3` as the post-safety benchmark-ready control when a Wave 0 fix
   was a prerequisite for valid measurement; the simplified candidate begins at `cf2ceeb3`. Compile
   topology may additionally report the original `b3045bc0` control, but must label the different
   provenance rather than mixing controls inside one paired result.
4. Highest-priority hypotheses to measure, not assume, are synchronous launch-time download-store
   I/O; Plex restore waiting beyond first usable connection; zero-work recovery wakeups; load-all
   movie grids; whole-snapshot Home/Search publication; shimmer invalidation; store-and-forward media
   proxy bodies; unowned proxy connection tasks; redundant playback/diagnostics/Cinema clocks; HDR
   probe overlap; ungated download-health temp scans; main-actor row/task refresh; full-index fsync;
   and large side-asset/finalizer memory and I/O.
5. No admissible paired runtime or five-sample compile artifact exists yet. The first implementation
   slices are measurement-only: exact-once/schema-compatible spans, deterministic fixture/counter
   contracts, a paired seeded compile runner with five samples and PMSKit incremental coverage, and
   explicit test-tier timing/failure taxonomy. Expensive captures remain serialized with cooling,
   stable power/thermal/storage covariates, raw artifacts local, and physical-only cells reported as
   hardware-blocked rather than inferred from simulators.
6. The measurement foundation now closes stale Home/Libraries/Detail spans exactly once and admits
   their existing terminal fields through the strict schema. The compile runner now snapshots two
   explicit commits, measures at least five same-index scenario-adjacent A/B pairs, includes PMSKit
   incremental coverage, sanitizes live-probe environment, invalidates dependent/restoration failures,
   checksums the private artifact set, and records exact runner provenance. The expensive paired
   compile capture has not started while runtime workload instrumentation is still being established.
7. Launch measurement now separates synchronous app-runtime composition from selected-backend
   restore. Composition records only whether the platform owns Downloads; restore uses the actual
   usable backend session as authority, classifying credential-retained-but-unavailable lanes as
   partial rather than successful. Both phases have closed backend/field correctness profiles and
   pass Mac hosted tests plus visionOS, iOS arm64, and tvOS arm64 build gates.

### Wave 6 — Optimize measured bottlenecks

- Land one attributable optimization per slice.
- Require paired baseline/candidate data and behavior gates.
- Remove ABR if evidence supports deletion.
- Do not optimize paths that remain below noise or outside product impact.

### Wave 7 — Acceptance and closeout

- Run every applicable available backend/platform/device cell and explicitly
  disposition every unavailable cell.
- Promote durable architecture and procedures into current docs.
- Archive superseded plans/evidence without rewriting historical records.
- Close only gates actually proven; mark unavailable physical/SharePlay evidence
  hardware-blocked.

## Pull request / commit slicing

Recommended initial slice order:

1. profiling configuration and metadata schema;
2. system-entry cancellation fix;
3. request deadline verification and proxy rotation fixes;
4. progress/SharePlay/remote-command safety fixes;
5. offline side-asset source ownership;
6. platform source roots, mechanical moves only;
7. `AppRuntime` and TV download absence;
8. non-vision spatial/SharePlay removal;
9. off-main decode/map and bounded fan-out;
10. catalog repository;
11. shared artwork pipeline;
12. incremental Home/page/collapser;
13. platform shell extraction and typed navigation;
14. typed playback source/restart/position;
15. platform player chrome extraction;
16. event-driven clock/system-media work;
17. Cinema coordinator and SharePlay attachment revisions;
18. download safe deletions and presentation snapshots;
19. side-cache/season/storage/persistence improvements;
20. auth/lifecycle/preferences/diagnostics decomposition;
21. simplified-app rebaseline;
22. isolated measured optimizations; and
23. physical acceptance and documentation promotion/archive.

Each slice should state:

- owned invariant and explicit non-goals;
- before/after files and deleted compatibility surface;
- automated and physical gates;
- paired performance scenarios, or “no runtime claim” for mechanical slices;
- current-docs impact, listing updated files or an explicit evidence-backed
  “no current documentation change” disposition;
- rollback boundary; and
- remaining follow-up IDs.

## Validation matrix

### Required for every production slice

- focused deterministic tests;
- PMSKit suite when shared policy/request/model code changes;
- affected hosted app tests;
- before S1 completes, clean builds of all four app targets for every shared app
  edit; afterward, a checked target-membership manifest determines affected
  targets, with all four still required for shared-root edits;
- worktree simulator install/launch/log/screenshot smoke for visionOS, iPhone,
  iPad, or an explicitly assigned TV simulator as applicable, serialized through
  the one-simulator lease; Mac uses the isolated host deploy/launch/log/cleanup
  path instead;
- a current-docs drift review for the changed ownership, behavior, tooling, and
  validation surfaces; and
- repository hygiene plus strict docs/link/Mermaid checks whenever documentation
  changes, including every slice whose drift review requires an update.

### Backend matrix

- Plex, Jellyfin, and Emby;
- direct/progressive/copy/transcode where supported;
- original, prepared/existing version, local/offline;
- start, resume, seek, quality, audio, subtitle, retry, EOF, close, and cleanup;
- small/large libraries, duplicate versions, playlists, collections/extras; and
- auth expiry, backend switch, account/server revision, partial failure.

### Command/gate classes

Each slice must name the exact command for every applicable class rather than
using “build/test/smoke” generically:

- clean target build;
- hosted unit/integration test plan;
- simulator build/install/launch/log/screenshot smoke;
- Mac host build/stage/launch/log/delete smoke;
- live-server probe, when wire behavior is in scope; and
- physical-device deploy and acceptance checklist.

### Physical platform gates

| Platform | Mandatory proof |
| --- | --- |
| Vision Pro | window/Cinema, gaze/pinch, HDR/DV, Now Playing, sleep/wake, background downloads, long-play energy/thermal |
| Two Vision Pros | invitation, readiness, late join, replacement item, Cinema handoff, disconnect, privacy, exact synchronization |
| iPhone | compact/landscape, PiP, AirPlay, Control Center, lock/background, network policy |
| iPad | regular/split/Stage Manager, pointer/keyboard, PiP, lock/background, large-library/season flows |
| Apple TV | Siri Remote, focus restoration, search keyboard, HDR/audio/HDMI, lifecycle, long play |
| Mac | single reusable main window, singleton Settings, sidebar/commands, physical Escape, fullscreen, media keys, sleep/wake, staged identity cleanup |

### Performance evidence rules

- optimized profiling configuration;
- sample counts, order, intervals, p50/p95 eligibility, and decision rules from
  the committed protocol;
- physical hardware for product claims;
- cache/network/device conditions recorded;
- raw traces local and privacy-reviewed; committed summaries redacted;
- before/after commit IDs and reproducible commands;
- no win declared inside measurement noise; and
- a versioned local evidence manifest with checksums, privacy status, raw retention
  deadline, and redacted-summary pointer.

## Definition of done

The program is complete only when:

- ownership boundaries are reflected in source topology and architecture docs;
- unsupported products do not construct or ship heavyweight capabilities;
- platform shells and player presentations are independently reviewable while
  shared policy remains shared;
- giant coordinators have typed responsibility seams without weakening state
  machines;
- duplicated request, cache, decode, polling, persistence, and presentation work
  is removed or justified by evidence;
- the simplified app has a current optimized-build performance baseline;
- measured bottlenecks meet ratcheted budgets with no behavior regressions;
- all available physical gates pass and unavailable two-device gates are marked
  hardware-blocked; and
- current docs, testing checklist, evidence indexes, and plan lifecycle are
  reconciled.
