# VisionPlay Downloads / Offline Subsystem Audit (GH #135)

Backend-agnostic dedup + robustness + de-godding plan for `VisionPlay/Downloads/DownloadManager.swift` (4939 lines) and collaborators. All anchors are `file:line`.

> Produced by a read-first multi-agent audit (9 parallel readers → capability matrix → staged plan → adversarial critique). It is the audit + plan deliverable for #135; the refactor lands as the staged PRs in §4.

## Implementation status

Landed on `refactor/downloads-dedup-135` (each a separate commit, each verified by `swift test`
+ an app build + a sim/headless smoke). PMSKit `@Test` count 672 → 705.

- **✅ Stage 2 — unify the completion/validation pipeline.** Both the opaque
  (`didFinishDownloadingTo`) and byte-range (`didCompleteWithError`) completion paths now funnel
  through one `BackgroundDownloadSession.finalizeTransferredFile`, with the decidable rules in the
  pure, tested `PMSKit.DownloadCompletionValidation`. Fixes verified **H1** (static lanes never ran
  `HEVCTagFixup` → `hev1` MP4 black-screen, despite the #127 comment), **H2** (no truncation guard on
  the range path), **H3** (range probe-miss condemned to `.failed` vs the #98 `.unverified`
  leniency). Verified E2E: a real Plex static download ran through the shared finalize to `.complete`
  on the sim.
- **✅ Stage 1a — `OptimizedVersionMatch`.** The Plex optimized-version matcher (±16px box / ×1.10+768
  kbps) moved to a pure PMSKit unit + 12 tests; the WxH parser deduped into
  `DownloadResolutionLabel.dimensions(forVideoResolution:)`; dead `resolutionHeight` deleted.
- **✅ Stage 1b/1c — `TranscodeSizeEstimator` + `DownloadDisplayClassifier`.** The Content-Length-less
  transcode size estimate and the #123 live-transcoder "/s"-suppression rule moved to pure PMSKit
  units + 6 tests.
- **✅ Stage 3 (first cut) — byte-range transfer hardening.** **H4**: evict from only the session that
  owns the task (the opaque and app-range sessions have independent id spaces) instead of both maps.
  **H5**: delete the poisoned partial on a non-2xx range response so a resume can't append after the
  error-page body. Verified live: a simulated mid-transfer drop produces a clean `.paused` with the
  partial + offset preserved.
- **✅ Stage 1e — `BackendURLIdentity` / persisted-server matching.** `BackendSession.matchesPersistedServer`
  + the scheme/host/port/path identity moved to PMSKit with 5 tests; the two `backendSessionMatchesPersistedServer`
  call sites delegate to it.
- **✅ Stage 5a — `EmbyDownloadRouter`.** The three-way Emby route decision (#112/#126 existing-version
  + #83 compatible-remux, all against the authoritative negotiated verdict) moved out of `downloadEmby`
  into a pure PMSKit unit + 9 branch-exhaustive tests, pinning the routing semantics before the larger
  Stage 5 move. Behavior-preserving; verified by `swift test` + an app build + a Plex browse smoke.
- **✅ Stage 5b — transfer-start tail unified.** The repeated `downloads.start` diagnostic +
  `session.start` + start-failure triad across all three `download*` twins collapsed into one
  `beginBackgroundTransfer(…, start:)` helper (the lane's own `session.start` overload + pre-start side
  effects pass as a closure). The one real per-lane difference (JF/Emby release the in-flight slot on a
  start failure; Plex static relies on the terminal `.failed`) is carried by `releaseInFlightOnFailure`.
  `DownloadManager.swift` 4939 → 4779 lines across the landed stages.
- **✅ Stage 5c (first two cuts) — per-backend subsystems split into their own files.** The headline
  de-godding, applied incrementally: each cohesive lane subsystem moves verbatim into a
  `DownloadManager+<Lane>.swift` extension (a `@MainActor`-class extension inherits the class's
  isolation, so the bodies are unchanged), and the only production change is promoting the shared
  lane services those methods reach from `private` to `internal` (module-scoped).
  - **`DownloadManager+EmbyConvert.swift`** — the Emby "Convert Media" server-prep lane
    (triggerConvertAndDownload → poll → finish + the #126 reuse-preflight helpers). ~620 lines.
  - **`DownloadManager+PlexOptimize.swift`** — the Plex server-side optimize kickoff/render/queue
    half (triggerOptimizeAndDownload → triggerOptimize → startOptimizedPartDownload + queue hygiene).
    ~550 lines.
  - **`DownloadManager+Jellyfin.swift`** — the Jellyfin download entry points (downloadJellyfin's
    static-original + server-rendered optimize/compatible lanes + downloadJellyfinOriginal + the
    trickplay cache). ~340 lines.
  - Net: `DownloadManager.swift` **4939 → 3271 lines (−34%)**; all three backends now own a dedicated
    lane file. Each cut is a separate commit, verified by a clean build + a UUID-matched install +
    launch (no crash, Plex browse UI). Remaining 5c cuts (same pattern): the Plex-optimize
    metadata-polling half, the Emby `downloadEmby` entry point + retry/resume drivers, and the
    side-cache cluster (overlaps Stage 7).

**Cross-backend verification harness** (kubectl port-forwards → live Plex/Emby/Jellyfin): Plex via
the headless `swift test` route probe + the in-process sim download probe (E2E to `.complete`); Emby
via the in-process dry-run probe (`route=transcode`, #133 refresh + existing-source enumeration both
green). Jellyfin has no dedicated download probe yet (shares the Emby lane code) — a follow-up.

- **Remaining:** Stage 1f (record-key leaves — deferred; entangled with the `isJellyfinRecordKey`/
  `isEmbyRecordKey` lane-routing predicates at 5 sites), **Stage 4** (`ServerPrepEngine` collapsing the
  Plex-optimize / Emby-convert duplication + Jellyfin stale guard), **Stage 5c** (the headline
  de-godding — relocate the Plex/Jellyfin/Emby request-resolution + side-cache bodies out of
  `DownloadManager` into separate `DownloadStrategy` types behind a coordinator context; **note** the
  blocker is Swift `private` visibility — a clean file/type split first requires downgrading the
  ~25 shared `private` members `DownloadManager` exposes to its lanes to `internal`, so this is a
  larger focused pass best done on its own), Stage 6 (persistence: schemaVersion + per-row decode
  isolation, H8/H9), Stage 7 (side-cache unification + parity), Stage 8 (UI/probe dedup). Real DAG:
  Stage 5c depends on the Stage 2/4 engines — ship in order.
  - Stage 5a/5b have already taken the *safe* slices of Stage 5 (the route decision is now pure +
    tested; the transfer-start tail is unified), shrinking the twins and de-risking 5c.

---

## 0. Scope & collaborators

| File | Role | LOC |
|---|---|---|
| `VisionPlay/Downloads/DownloadManager.swift` | Orchestration god-object: route decisions, per-backend lanes, retry/pause/resume/relaunch drivers, side-cache, ETA/rate, optimize/convert polling | 4939 |
| `VisionPlay/Downloads/BackgroundDownloadSession.swift` | Transfer layer: two parallel pipelines (opaque bg task + app-managed range dataTask), completion/validation | 1193 |
| `VisionPlay/Downloads/DownloadStore.swift` | `index.json` persistence, `reconcile`, side-asset cleanup | ~600 |
| `PMSKit/.../Downloads/OfflineDownloadModels.swift` | Codable model: `DownloadStatus`, `DownloadLane`, `DownloadResumeMode`, `OfflineMetadata`, reconciliation table (pure, tested) | — |
| `PMSKit/.../Downloads/OfflineDownloadDecision.swift` | Container/eligibility/remux gates (pure, tested) | — |
| `PMSKit/.../Downloads/{DownloadRateEstimator,DownloadProgressDisplay,DownloadResolutionLabel,HEVCTagFixup,OfflineTextSubtitles,BackendSession}.swift` | Pure units, tested | — |
| `VisionPlay/UI/DownloadOptionsSheet.swift` (1062), `OfflineLibraryView.swift` (602) | UI; currently host live probe IO + lane→label mapping + preset ladders | — |
| `VisionPlay/Debug{Plex,Emby}DownloadProbe.swift` | DEBUG-only exercisers that re-implement route logic | — |

---

## 1. Lane inventory (consolidated, 13 effective lanes + 2 transfer mechanisms)

**Plex**
- **P1 plex-original** — byte-for-byte source. `download(.original)` runs `directPlayProbe` (`DownloadManager.swift:437-478`) + a *second* live `preflightOriginalPlayback` muted-AVPlayer gate (`:744-818`) with transparent optimize fallback. Tail `startStaticPlexPartDownload` (`:634-688`), `byteRangeCheckpoint:true`.
- **P2 plex-existing-version (#112)** — server-generated Version picked by `mediaIndex`; **skips both** probe gates; offline-gated only by `existingVersionPlayableOffline` (`OfflineDownloadDecision.swift:101-107`). Rides lane `.original` (`downloadLane(for:)` maps `.existingVersion→.original`, `:2435`). Same static tail (`:596-615`).
- **P3 plex-optimize** — server render then static download. `triggerOptimizeAndDownload`/`triggerOptimize`/`pollForOptimizedPart`/`startOptimizedPartDownload` (`:3126-3345, :3384-3454, :3873-3998`). Phase-1 has no URLSession task (held `.queued`+`optimizeTargetName`); phase-2 is a range download of the rendered Part.

**Jellyfin**
- **J1 jellyfin-original** — URL built directly from `itemId`+`mediaSourceID`, no PlaybackInfo probe; `.existingVersion` treated as plain original (`:890-903`). Static range.
- **J2 jellyfin-transcode (.optimize)** — PlaybackInfo POST, live encoder stream, `transcodeSourcedDownloads`, `byteRangeCheckpoint:false`, `liveForwardOnly` (`:905-943`).
- **J3 jellyfin-compatible-remux (#83)** — re-probe + `compatibleRemuxEligibility`; copy-video/AAC stream, forward-only (`:945-1004`).
- **J3b jellyfin-remux→transcode fallback** — when not copyable, mutates lane in place to `.optimize` (`:988-1001`), dropping compatible intent.

**Emby**
- **E1 emby-original / emby-existing-version (#126)** — authoritative download PlaybackInfo POST → route `(directPlay && containerGate) ? .original : .transcode` (`:1266-1335`). Static `stream.{container}?static=true`, range-resumable.
- **E2 emby-compatible-remux (#83)** — remux-profile PlaybackInfo; forward-only encoder, `byteRangeCheckpoint:false`, `useServerSession:true` (`:1269-1340, :1434-1447`).
- **E3 emby-transcode reroute** — a live Emby transcode is never downloaded directly: `.optimize*` reroute to convert; `.original/.existingVersion` that negotiate transcode **fail loudly** (`:1354-1414`).
- **E4 emby-convert-then-download (#128 true-4K)** — server Sync "Convert Media" job, `.preparing` row, persistent rendered file, then handoff to E1 `.existingVersion` static. `triggerConvertAndDownload`/`pollAndDownloadEmbyConvertJob`/`finishEmbyConvert` (`:4229-4646`); `EmbyConvertRequest.swift:79-301`.
- **E5 emby existing-version reuse preflight (#126)** — `reusableConvertedSource` reuses a kept converted file instead of re-converting (`:4259-4302, :4768-4828`); #133 refresh-before-reconvert.

**Transfer mechanisms (backend-agnostic, the real fork)**
- **T-A opaque** — `URLSession.downloadTask`, OS-managed temp file, env-branched config (device=background, simulator=default foreground) (`BackgroundDownloadSession.swift:61-89, 215-269`). Completion `didFinishDownloadingTo` (`:602-799`) is the **rich** pipeline.
- **T-B app-range** — separate `rangeURLSession` (always `.default` foreground), `dataTask` writing bytes via `FileHandle` directly into the **final** file, explicit `Range:` header (`:99-111, 277-333, 480-552`). Completion `didCompleteWithError` range branch (`:863-939`) is the **thin** pipeline.

> The single most consequential architectural fact: **ALL static lanes (P1/P2/P3-phase2/J1/E1/E5) use T-B**, but the protections (HEVC fixup, MIME guard, #98 probe-retry, `.unverified` leniency, truncation guard) live **only in T-A**. The two pipelines have drifted; the comment at `:700-709` claims #127 fixed Plex hev1 static black-screens by gating on container — but that fixup is **unreachable** for the very lanes it names.

---

## 2. Capability matrix

Legend: **`=`** duplicated-but-equivalent → *unify*. **`~acc`** divergent but *accidental* (should converge). **`!ess`** divergent and *essential* (preserve, but model explicitly). Cells reference the deciding anchor.

| Lane | source | transfer | checkpoint | retry | cancel | progress | completion | sideCache |
|---|---|---|---|---|---|---|---|---|
| **P1 plex-original** | `!ess` 2 gates+preflight `:564-594,744-818` | `=` range tail `:634-688` | `!ess` strongest, staticByteRange `BGS:277-333` | `=` `resolveStaticRetryTarget` `:1798-1813` | `=` delete/pause `:2341,1596` | `=` real /s (`isLiveTranscoderSourced=false`) `:359-375` | `~acc` thin range pipeline, **no HEVC/trunc/#98** `BGS:863-938` | `!ess` poster/BIF/chapters/subs `:558-656` |
| **P2 plex-existing-version (#112)** | `!ess` skips gates, mediaIndex `:596-615` | `=` same tail | `=` staticByteRange | `=` `:1748-1762` | `=` | `=` | `~acc` same thin pipeline gaps | `=` same as P1 |
| **P3 plex-optimize** | `!ess` render+poll `:3384-3998` | `=` phase-2 range `:3285-3345` | `!ess` serverPrepThenStatic→staticByteRange `:3303-3309` | `~acc` `retryPausedPlexOptimize` + `assertCurrentOptimizeAttempt` (Plex-only guard) `:1815,3354` | `~acc` no server-side render delete; stale-sweep marker `:3537` | `!ess` `/activities` EMA `:4088-4199` | `~acc` thin range pipeline | `~acc` poster/BIF only carried-forward, never re-fetched `:3180` |
| **J1 jellyfin-original** | `~acc` no probe (#90) `:890-903` | `=` range | `=` staticByteRange | `~acc` deliberate no-reprobe (#90) `:1869-1875` | `=` no encoder | `=` real /s | `=` rich T-A pipeline `BGS:602-799` | `=` poster/trickplay/chapters/subs `:1043-1052` |
| **J2 jellyfin-transcode** | `=` PlaybackInfo `:905-943` | `=` opaque | `!ess` liveForwardOnly | `=` restart `:1859-1860` | `!ess` encoder teardown `:2635-2647` | `!ess` live cadence, estimated bytes `:2472` | `=` rich pipeline | `~acc` no subs (only `.original`) `:1049` |
| **J3 jellyfin-compat-remux (#83)** | `=` re-probe+eligibility `:945-979` | `=` opaque | `!ess` liveForwardOnly | `=` `.optimizeCompatible` `:1861-1864` | `!ess` encoder teardown | `~acc` **no estimated fraction** (no optimizeTarget → permanent spinner) `:3756` | `=` HEVC fixup is the gate | `~acc` no subs |
| **J3b remux→transcode fallback** | `!ess` mutate lane in place `:988-1001` | `=` opaque | `!ess` liveForwardOnly | `=` becomes optimize | `=` | `=` | `=` | `=` |
| **E1 emby-original/#126** | `!ess` authoritative route `:1266-1335` | `=` range | `=` staticByteRange | `=` `retryEmby` re-probe `:1922-1933` | `=` no encoder | `=` real /s | `~acc` thin range pipeline (HEVC fixup runs in T-A only; gap on range) | `~acc` poster+chapters only, **no trickplay/subs** `:1492-1498` |
| **E2 emby-compat-remux (#83)** | `=` remux PlaybackInfo `:1269-1340` | `=` opaque | `!ess` liveForwardOnly | `=` `:1936-1939` | `!ess` encoder teardown `:2622-2634` | `!ess` live cadence | `=` HEVC fixup gate | `~acc` poster+chapters only |
| **E3 emby-transcode reroute** | `!ess` fail-loud/reroute `:1354-1414` | n/a | n/a | n/a | `=` releaseInFlight | n/a | n/a | n/a |
| **E4 emby-convert (#128)** | `!ess` Sync job+snapshot `:4229-4387` | `!ess` server render → handoff to E1 | `!ess` serverPrepThenStatic, `.preparing` survives relaunch | `~acc` bespoke `activeJobs` guards (Emby-only) `:4401-4637` | `!ess` DELETE /Sync/Jobs `:2345-2366` | `!ess` pinned-0 indeterminate `:4445-4459` | `=` via E1 handoff | `=` via E1 |
| **E5 emby reuse preflight (#126)** | `!ess` `reusableConvertedSource` exact-tier `:4768-4828` | `=` via E1 | `=` staticByteRange | `=` via E1 | `=` | `=` | `=` | `=` |

**Cross-cutting capability collisions to unify (accidental divergence):**
- **Completion/validation** is `~acc` everywhere static (T-B) vs `=` rich (T-A). Single biggest convergence target (§6 H1–H3).
- **Server-prep modeling** is `~acc`: Plex = `.queued`+`optimizeTargetName`; Emby = `.preparing`+`embyConvertJobID`. Same concept, two statuses, two stale-guards (`assertCurrentOptimizeAttempt` vs hand-rolled `activeJobs` guards), and Jellyfin has **none** — `!ess`-looking but actually accidental.
- **Side-cache parity** is `~acc`: Emby no subs/trickplay; Jellyfin subs gated to `.original` only; Plex optimize never re-fetches poster/BIF.

---

## 3. Target backend-agnostic "job" model

### 3.1 One state machine (replace the implicit `DownloadStatus` graph)

```
                 ┌────────────────────────────────────────────────┐
                 ▼                                                │
 enqueue → QUEUED ──► PREPARING(serverJob) ──► TRANSFERRING ──► VALIDATING ──► COMPLETE
                 │          │  ▲                  │  ▲             │  │
                 │          │  └── poll/relaunch   │  └─ resume     │  └─► UNVERIFIED (file kept, playable)
                 │          ▼                      ▼                ▼
                 └──────► FAILED ◄──────────── PAUSED ◄──────── (probe-miss / short-body)
```

- `QUEUED` → `PREPARING` only if the strategy declares a server-prep phase (Plex optimize, Emby convert). Otherwise straight to `TRANSFERRING`.
- `TRANSFERRING` ↔ `PAUSED` is the only resumable edge; whether resume is **byte-range**, **OS-blob**, or **restart-from-0** is a property of the strategy's `CheckpointPolicy`, not a per-lane special case.
- `VALIDATING` is now an **explicit** state (today it is implicit inside completion handlers), and runs the **same** validator for every transfer mode.
- `UNVERIFIED` is reachable from `VALIDATING` for *every* lane (today only T-A).

### 3.2 Plugged-in backend strategy

```swift
protocol DownloadStrategy {                       // one impl per (backend × lane family)
    func resolveSource(_ ctx: JobContext) async throws -> ResolvedSource
    // ResolvedSource = { request, transferMode(.appRange/.opaque), expectedBytes?,
    //                    resumeMode, validationRequirements, recordKey, sideAssetPlan }
    var serverPrep: ServerPrepStrategy? { get }   // nil = no PREPARING phase
    var keepalive:  KeepalivePolicy?    { get }   // JF transcode, (NEW) Emby remux
    func teardown(_ ctx: JobContext) async         // encoder/Sync-job cleanup
    func retryTarget(from: TerminalFailure, record: DownloadRecord) -> RetryTarget
}

protocol ServerPrepStrategy {                     // unifies Plex optimize + Emby convert
    func start(_ ctx) async throws -> ServerJobHandle
    func poll(_ handle) async throws -> PrepProgress | PreparedSource | .stillPreparing
    func cancel(_ handle) async                    // Plex queue-marker / Emby DELETE /Sync/Jobs
    func reuseExisting(_ ctx) async -> PreparedSource?   // E5 + Plex existing-version
    var staleGuard: AttemptIdentity { get }        // the ONE assertCurrent* / activeJobs guard
}
```

Three shared, backend-neutral engines own the gnarly logic exactly once:
1. **TransferEngine** (today: `BackgroundDownloadSession`) — picks `appRange` vs `opaque` from `transferMode`, but funnels **both** through one `CompletionValidator` (HEVC fixup + MIME guard + #98 retry + truncation + `.unverified`). Per-task bookkeeping via one `registerTask` helper.
2. **ServerPrepEngine** — drives any `ServerPrepStrategy`: start → poll(progress/ETA via a generalized `FractionRateEstimator`) → handoff, with one `staleGuard`, one relaunch-resume driver. Replaces `resumePendingServerPrepDownloads`/`resumePendingOptimizeDownload`/`resumePendingEmbyConvertDownloads` parallel arms.
3. **JobCoordinator** (the slimmed `DownloadManager`) — owns the state machine, the in-flight slot, `releaseInFlight`, `refreshRecords`, pause/queue gates; delegates everything backend-specific to a `DownloadStrategy`.

Backend strategies become small: `PlexStaticStrategy`, `PlexOptimizeStrategy(serverPrep: PlexOptimizePrep)`, `JellyfinStrategy`, `EmbyStaticStrategy`, `EmbyConvertStrategy(serverPrep: EmbyConvertPrep)`. The `download()`/`downloadJellyfin()`/`downloadEmby()` ~300-line near-twins (`:824-1103`, `:1203-1543`) collapse into one `JobCoordinator.start(strategy:)`.

---

## 4. Staged PR decomposition (ordered, each independently shippable, low-risk first)

**Stage 0 — Characterization tests (no production change).** Lock current behavior of the gnarly transitions *before* moving anything: `reconciledStatus` table, `resolvedResumeMode`, range-vs-opaque completion outcomes, optimize-Part matching, retry choice-derivation. Ships as test-only.

**Stage 1 — Extract pure leaf units into PMSKit (mechanical, zero behavior change).** Lowest risk; sets the PR pattern.
- **1a. `OptimizedVersionMatch`** ← `serverOptimizedMedia`/`optimizedDownloadCandidate`/`resolutionDimensions`/`isServerOptimizedPart` (`:3937-4013`). **← recommendedFirstExtraction (see below).**
- 1b. `TranscodeSizeEstimator.bytes(durationMs:videoBitrateBps:)` ← `:3747-3762` (feeds already-tested `DownloadProgressDisplay`/`DownloadRateEstimator`).
- 1c. `DownloadDisplayClassifier.isLiveTranscoderSourced(_:)` ← `:359-375` (pure over `DownloadRecord`, *zero* coupling — moves verbatim).
- 1d. `DownloadResolutionLabel.dimensions(forVideoResolution:)` — dedup the inline parser (`:4004-4008`) against `DownloadResolutionLabel.swift:26-27`; fixes the capital-`X` drift risk.
- 1e. `BackendSession` URL-identity: `sameBackendBaseURL`/`effectivePort`/`normalizedBasePath`/`backendSessionMatchesPersistedServer` (`:278-315`).
- 1f. Record-key builders (`jellyfinRecordKey`/`embyRecordKey`/`jellyfinItemID(fromRecordKey:)`, `:404-426`) co-located with `DownloadBackendKind(ratingKeyPrefix:)`.

**Stage 2 — Unify the completion/validation pipeline (ROBUSTNESS, highest-value correctness).** Extract one `CompletionValidator` (HEVC fixup + MIME guard + #98 probe-retry + truncation guard + `.unverified` leniency) and call it from **both** `didFinishDownloadingTo` (`BGS:602-799`) and the range branch (`BGS:863-939`). Fixes H1/H2/H3 in one shot. Independently shippable; covered by Stage-0 characterization + new tests.

**Stage 3 — Transfer-layer dedup & safety.** One `registerTask` helper (`BGS:255-260/305-318/363-368/1048-1051`); namespace inflight maps by `(session, taskIdentifier)` to kill the cross-session collision (H4); delete the partial on range failure (H5); one paused/interrupted triad helper (`BGS` ~6 sites).

**Stage 4 — `ServerPrepEngine` + `ServerPrepStrategy`.** Collapse the Plex-arm/Emby-arm duplication in `reconcile`, pause, resume drivers; give Jellyfin transcode the same stale-attempt guard. Generalize the optimize ETA EMA (`:4150-4199`) into `FractionRateEstimator` reusing `DownloadRateEstimator`'s proven trust-band.

**Stage 5 — Backend `DownloadStrategy` extraction.** Turn `download`/`downloadJellyfin`/`downloadEmby` (`:499-628, :824-1103, :1203-1543`) and the four copy-pasted start/catch blocks into `JobCoordinator.start(strategy:)` + small strategies. Largest diff; lands after the engines exist.

**Stage 6 — Persistence hardening.** Add `schemaVersion` to `index.json` + per-row decode isolation (H8); single side-asset enumeration source (used by `sideAssetBytes`/`remove`/`reconcile`, `DownloadStore.swift:256-273,531-537,565-573`); fix metadata-nil mutation no-op (H9); fold `reconcile`'s inline resume-mode re-derivation into `resolvedResumeMode`.

**Stage 7 — Side-cache unification + parity.** One `cacheSideAsset(fetch→write→persistRelativePath→refresh)` helper collapsing 8 cachers; per-backend request builders only. Close gaps: Emby subs, Jellyfin remux subs, Plex-optimize poster/BIF re-fetch.

**Stage 8 — UI / probe dedup.** Move per-backend probe orchestration (`DownloadOptionsSheet.swift:139-463`) and lane→label mapping (3 hand-rolled copies) and preset ladders into PMSKit/model; delete the inline `["mp4","m4v","mov"]` allowlist (`:348`); make `Debug*DownloadProbe` read the *real* route from the strategy instead of re-deriving it.

---

## 5. Test-coverage gap list

Already well-pinned (keep): `OfflineDownloadDecision*`, `DecisionResponseDownload`, `DownloadRateEstimator`, `DownloadProgressDisplay`, `DownloadResolutionLabel`, `HEVCTagFixup`, `OfflineTextSubtitle*`, `OfflineDownloadModels` (migration/reconcile table + validation policy), `Emby{Download,Convert,ExistingVersions}`, `CompatibleRemux*`, `BrowseUIGate`.

**Gaps (no test today):**
1. `serverOptimizedMedia`/`optimizedDownloadCandidate` bounding-box match (`:3958-3998`) — load-bearing 16px / ×1.10+768 constants. **(Stage 1a target.)**
2. `isLiveTranscoderSourced` switch (`:359-375`) — incl. the spurious-early-size flip risk.
3. `estimatedTranscodeBytes` (`:3747-3762`) and the compatible-remux `nil`→permanent-spinner case (`:3756`).
4. Optimize ETA EMA `updateOptimizeETA`/`speedBasedTranscodeETA` (`:4150-4199`) — the exact ad-hoc EMA `DownloadRateEstimator` was built to replace.
5. **Range-lane completion** (`BGS:863-939`): missing HEVC fixup, missing truncation guard, `.failed`-vs-`.unverified` divergence — no characterization test exists for the static lanes' completion at all.
6. Cross-session `taskIdentifier` collision (`BGS:856-860`).
7. Poisoned-partial-after-range-failure → resume corruption (`BGS:888-898` no delete).
8. `reconcile` three-predicate routing (`DownloadStore.swift:495-522`): `hasServerPrepCheckpoint`/`hasAppRangeCheckpoint`/`isPlexServerPrepOptimizedJob` interaction, incl. the partial-delete entanglement (`:528-537`).
9. `index.json` whole-array decode-failure → empty-library blast radius (`DownloadStore.swift:581-594`).
10. `updateMetadata` no-op when `row.metadata == nil` (`:413-421`) — silent loss of resume/playSession/jobID.
11. Backend URL-identity matching (`:278-315`) — the encoder/job mis-match hazard.
12. Retry choice-derivation parity: `retryJellyfin` vs `retryEmby` vs generic Plex retry (`:1641-1973`).
13. Debug-probe predicted-route vs real route divergence (`DebugEmbyDownloadProbe.swift:135-137` vs `DownloadManager.swift:1320-1336`).
14. UI `preferredSelection` defaulting incl. the dead `compatibleRemuxAvailable` branch (`DownloadOptionsSheet.swift:881-899`).

---

## 6. Hardening list — the gnarly transitions

- **H1 (correctness, high).** Static lanes (P1/P2/P3-ph2/J1/E1/E5) never run `HEVCTagFixup.rewriteFile`; an hev1-tagged MP4 black-screens / fails the local probe. The #127 fix at `BGS:700-727` is unreachable for the range path. → Stage 2 unified validator.
- **H2.** No truncation guard on the range path (`BGS:900-910`): a server returning 2xx with a short body but `totalBytes>=part.size` passes. Worse when `part.size` is nil/0 (Emby) — the guard is skipped entirely.
- **H3.** Probe-miss outcome inverts by lane: T-A keeps the file `.unverified` & playable (#98, `BGS:789-796`); T-B condemns the identical condition to `.failed`+`onError` without deleting (`BGS:926-935`). Opposite user-visible result.
- **H4.** Cross-session `taskIdentifier` collision: `didCompleteWithError` evicts from **both** `inflight` and `rangeInflight` by bare id (`BGS:856-860`); a range id can equal a bg id, silently dropping the other's completion. Namespace by `(session,id)`.
- **H5.** Range failure writes the error-page body into the **final** file and does **not** delete it (`BGS:888-898`); next `start()` computes a junk offset and a 206 appends real bytes after garbage → corrupt file. Delete on range failure like T-A does.
- **H6.** Range lane doesn't survive suspension: `rangeURLSession` is foreground `.default` and `reattach` queries only the background session (`BGS:99-111,145-146`). Recovery rests entirely on on-disk offset + `hasAppRangeCheckpoint` heuristic; `progress>=0.999` or `bytes==0` won't be recognized resumable.
- **H7.** `pauseQueue`→`resumeQueue` race: pause flips rows async inside `getAllTasks`, resume filters `status==.paused` synchronously (`:1628-1632`) — a still-`.downloading` row is skipped while the gate says unpaused. Also `pause()` of `.downloading` calls `releaseInFlight` synchronously *before* the async blob persist (`:1612-1613` vs `BGS:426-431`): a window with no slot and no blob.
- **H8.** No `schemaVersion` on `index.json`; one malformed row → `try?` nil → **entire** offline library dropped (`DownloadStore.swift:583-584`). Add per-row decode isolation.
- **H9.** `updateMetadata` is a no-op when `metadata==nil` (`:413-421`): a pre-metadata row can never record a resume blob / playSessionID / convert jobID — silently un-recoverable and leaks server encoders/Sync jobs.
- **H10.** Server-prep ambiguity: Plex prep is disambiguated from a fresh static `.queued` *only* by non-empty `optimizeTargetName` (`DownloadStore.swift:510-514`); a static row that somehow carries one is mis-rescued. Model `PREPARING` as an explicit state, not an inferred one.
- **H11.** No wall-clock timeout on either server-prep poll (`pollForOptimizedPart`, `pollAndDownloadEmbyConvertJob` `:4396-4397`); a stuck/unknown job holds the slot and a `.preparing`/`.queued` row forever. Add a bounded escalation.
- **H12.** Emby compatible-remux is a live forward-only encoder stream with **no keepalive** (only Jellyfin has one, `:2528-2593`); a slow Emby remux can be idle-killed mid-stream.
- **H13.** `reconcile` partial-delete only removes media+resume blob, not other side assets (`DownloadStore.swift:531-537`); repeated fail→retry accumulates orphaned posters/BIF/tiles counted by `sideAssetBytes`.
- **H14.** Detached side-cache Tasks aren't cancellation-tied to the row; a `store.setX` can race a `delete` and momentarily re-populate metadata for a removed key.

---

## 7. Dedup hit-list (the per-lane re-implementations #135 targets)

- 4× copy-pasted seed→side-cache→`session.start`→3-way-catch (`:657-687, :3316-3344, :1054-1102`, Emby).
- ~12× start-failure boilerplate (`:1005-1016,1082-1102,1291-1303,1468-1479,1523-1543,4346-4358,...`).
- `downloadJellyfin`/`downloadEmby` ~300-line twins; `retryJellyfin`/`retryEmby` structural twins.
- `ext` resolution dup (`:646-648` vs `:3292-3294`); `downloadURL(partKey:)` rebuilt 3× (`:576,611,3323`).
- mp4-family allowlist expressed 3 ways (`OfflineDownloadDecision.swift:25-27`, `:1320-1321`, `BGS:710`, UI `:348`).
- muted-AVPlayer probe twice (`preflightOriginalPlayback :744-818` vs `validateLocalPlayback BGS:805-851`).
- Resume-class computed 3 ways (`OfflineDownloadModels` `resolved`, `resolvedResumeMode`, `reconcile` inline `:490-494`).
- Two server-prep encodings, two stale-guards; 8 side-asset cachers; 3 lane→label mappings; triplicate preset ladders.

---

*Net: Stages 1–2 deliver most of the robustness wins (H1–H5) and ~250–400 lines out of `DownloadManager`/`BackgroundDownloadSession` at low risk before the structural Stage 4–5 strategy refactor begins.*