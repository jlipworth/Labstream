# Codebase remediation plan

Status: **active implementation plan**

Audit baseline: app/PMSKit code through `edf2d27`; documentation baseline `5d106fd`

Scope: correctness, concurrency, reliability, performance, Swift idioms, testability,
backend sharing, platform sharing, conditional compilation, and build cost.

Companion document: `docs/audits/2026-07-10-downloads-engine-audit-plan.md` is the detailed
downloads-engine audit that feeds `COR-01`/`COR-02`/`COR-03`/`COR-07`; this plan owns the
remediation queue for those findings — do not treat the two documents as independent work
lists. Line references in both documents are as of the audit baseline and may drift a few
lines past it.

## Implementation checkpoint — 2026-07-11 after the downloads audit

The remediation stack was rebased onto `main` at `e757bb1` after auditing the 29 reachable
incoming commits from `6a523cf..e757bb1`. Those commits are overwhelmingly downloads-engine
characterization and hardening. They add useful fault infrastructure and several attempt-aware
guards, but they do not complete the release-blocking persistence/ownership work below.

Current status at this checkpoint:

| Slice | Status | Evidence / remaining boundary |
| --- | --- | --- |
| 0A–0B | Complete | Repeatable compile audit plus nonzero macOS/iOS app test plans are on the rebased branch. |
| 1A | Partial / advanced | The index has a serial revisioned writer, dirty retry, observable failures, bounded background-completion flush, and commit-aware held-body replacement (`0bbcb5d`, `f5ecf95`, `7005fd5`, `e4e4fd4`). Existing mutations still preserve synchronous durability. Held-manifest removal outcomes, tombstone ordering, split temp/replace crash seams, and broader fault/stress coverage remain. |
| 1B | Partial | Existing string attempt tokens, v2 task markers, stale-task rejection, and attempt-bearing held manifests are prior art. A typed `DownloadAttemptID`, schema v3, durable-before-reattach migration, and attempt-conditional store APIs remain. |
| 1C | Partial | Main now has a final-verdict recheck, attempt-matched held bodies/orphan sweeping, and an Emby ambiguous-create tombstone. A work registry, attempt-scoped finalizing, side-asset staging/ownership, broad post-await guards, and compare-and-clear play-session cleanup remain. |
| 1D–1F | Complete | Auth/secure-storage, system-media ownership, and player lifecycle generations survived the rebase unchanged. iPad/Mac physical ownership and lifecycle checks passed; iOS TSAN tests remain green. |
| 2A | Complete | Plex photo coverage, modern Mac decoding, the effective MediaSession clock, and `PERF-01` are complete. The regenerated inventory found and mechanically removed exactly the four original definition-only helpers (`2fb3d00`, `5a5f050`, `cf1f919`, `6bff1c8`); no production deprecation remains. |
| 2B | Open / higher priority | `store.records` uses grew from 38 to 40 and single-row `first`/`contains` uses from 24 to 26. Only `status(for:)` is narrow today. |
| 2C | Complete | Latest-rail execution is bounded and order preserving. |
| 2D | Complete | Optimizer flexible-ID decoding is explicit and the Offline root view is split at behavior-neutral opaque boundaries (`cc516ea`, `43ba92b`). Both cliffs disappeared from the compile audit; extracted Offline boundaries are below 50 ms on all app platforms. |
| 3–4 | Open | Incoming main did not change the MediaBrowser value/request seams or Plex browse execution. Canonical backend work now spans a larger audited download-policy surface. |
| 5E | Higher priority after correctness | `BackgroundDownloadSession` grew from about 4,994 to 5,755 lines, `DownloadManager` from 3,264 to 3,749, and `DownloadStore` from 1,091 to 1,271. Extract mechanically only after 1A–1C. |

The audited engine added two durability domains that 1A–1C must model explicitly:

- attempt-bearing held-range manifests and persisted held response bodies;
- Emby ambiguous-create cleanup tombstones and their retry/clear lifecycle.

Do not serialize only the main download index while leaving these adjacent durable artifacts
unordered relative to terminal/background-completion promises. Likewise, do not introduce a
second attempt authority beside the current server-prep/marker identities; document and test
their relationship during the schema-v3 migration.

### Revised execution order from the incoming diff

1. Record a new post-audit compile/static-reference baseline and regenerate the warning/dead-helper inventory.
2. Land the isolated `PERF-01` filesystem-stat change with a large sparse-file test.
3. Implement 1A revisioned persistence/dirty retry/bounded flush, including background completion and the adjacent held-manifest/tombstone durability boundaries.
4. Implement 1B typed attempt identity and the atomic schema-v3/dual-read migration.
5. Implement 1C attempt-conditional mutations, work registry, side-asset staging, and compare-and-clear cleanup using the new audit fixtures.
6. Add 2B narrow lookups and benchmarks, then land the two 2D compiler fixes as separate measured changes.
7. Start 3A canonical backend identity with compatibility aliases and legacy row/system-entry fixtures; continue through 3B–3E and Phase 4 only after the release-blocking download work is green.
8. Move the download portion of 5E ahead of broad platform presentation decomposition, but keep each extraction behavior-neutral and separately reviewed.

### Implementation journal

#### 2026-07-11 — `PERF-01` filesystem-stat boundary

- **Status:** complete.
- **Commit:** `3378211` (`Use file metadata for HTTP error body size`).
- **Changed boundary:** failed HTTP download diagnostics now obtain the temporary body's logical
  byte count from filesystem attributes instead of allocating the entire body. HTTP handling,
  failure transitions, privacy-safe bucketing, raw-body handling, lifecycle ownership, and
  persisted schemas are unchanged. A stat failure still produces `body_bytes=unknown`.
- **Regression evidence:** app tests create a 16 GiB sparse file and prove its exact logical size
  reaches the existing `10GB+` bucket without materializing its contents. Zero-byte, missing,
  denied, malformed, negative, overflowing, fractional, non-finite, and boolean attribute shapes
  are also covered.
- **Validation:** focused stat tests passed 5/5; the complete macOS and iPadOS app plans passed
  42/42 each, with Thread Sanitizer enabled on iPadOS. Clean Mac, iOS Simulator, and visionOS
  Simulator builds passed. The clean visionOS product matched the installed UUID, launched into
  the signed-in Home surface, returned HTTP 200 during startup, and had no crash, assertion, or
  sanitizer signature in the smoke log. PMSKit passed 1,399 tests across 170 suites, and the
  repository hygiene gate plus its 20 Python tooling tests passed.
- **Known remaining boundary:** the post-audit dead-helper/warning inventory remains part of 2A;
  it is not coupled to this production fix.

#### 2026-07-11 — Phase 1A durability discovery

- **Status:** characterized; implementation open.
- **Current index boundary:** `DownloadStore.persist()` snapshots under `NSLock`, then encodes and
  atomically writes outside the lock with no revision, serialization, dirty retry, result,
  diagnostic, or flush. Eleven mutation paths call it. Subtitle repair writes the index directly
  and swallows failure, bypassing that path.
- **Background completion boundary:** `BackgroundDownloadCompletionGate` waits for in-memory
  range I/O/finalization only. `urlSessionDidFinishEvents` can therefore release the OS handler
  without proving that the required index revision reached disk.
- **Adjacent durability boundaries:** held bodies are moved before their manifests mutate, but a
  successful `persistHeldRangeSegment` currently means only an in-memory mutation; callers cannot
  know that the manifest committed before replacing an older body. Emby cleanup tombstones use a
  separate synchronous JSON file under the store lock; add failure is visible, remove failure is
  silent, and decode failure is currently treated as an empty collection.
- **Existing evidence/seams:** schema-v2 and legacy/corrupt-row coding have PMSKit coverage, and
  the completion gate has in-memory tests. There is no index write/encode/replace fault seam or
  deterministic stale-write, dirty-retry, fresh-store restore, terminal/delete durability, or
  completion-versus-flush app test.
- **Next commit boundary:** introduce a fault-injectable, revision-fenced index writer plus app
  characterization tests, route normal persistence and subtitle repair through it, preserve
  schema v2, retain the newest failed snapshot as dirty, and expose a bounded internal flush.
  Background-completion integration, held-manifest tickets, and tombstone semantics remain
  separate follow-up commits.
- **Unable to determine without an explicit implementation choice:** whether index and tombstones
  share one revision domain or aggregate separate tickets; whether held-manifest calls block or
  return tickets; the exact revision terminal/delete/background completion must await; flush
  timeout and timeout-handler policy; corrupt tombstone quarantine policy; delete ordering;
  shutdown handling for dirty revisions; and the public result shape for terminal/delete failures.

#### 2026-07-11 — Phase 1A revisioned-writer primitive

- **Status:** primitive complete; production integration open.
- **Commit:** `0bbcb5d` (`Add revisioned persistence writer primitive`).
- **Changed boundary:** added a generic internal full-snapshot writer with synchronous revision
  acceptance, one serial encode/atomic-commit worker, pending-snapshot coalescing, dirty retention,
  later-mutation/flush retry, privacy-safe encode-versus-commit failures, and bounded async flush.
  It is deliberately not wired into `DownloadStore` yet, so this commit cannot weaken the current
  synchronous index-write or background-completion behavior by itself.
- **Regression evidence:** deterministic tests cover coalescing while an older encode is suspended,
  late obsolete submission, commit and encode failure, dirty retry, newer-snapshot supersession,
  timeout without abandonment, and invalid timeout values. The focused seven-test suite passed
  repeatedly on macOS and passed under Thread Sanitizer on iPadOS.
- **Reviewed invariant:** a revision superseded before its opaque atomic commit is skipped. If a
  newer revision arrives only after an atomic commit has begun, the older operation may finish,
  but the single worker guarantees the newer accepted snapshot is the final replacement.
- **Next commit boundary:** add the app-level index I/O seam, assign revisions with the store lock,
  route all index persistence and subtitle repair through this writer while retaining synchronous
  durability at existing call sites, and prove fresh-store restore plus schema-v2 compatibility.
  Only after that characterization is green should ordinary mutations become asynchronous and
  explicit terminal/delete/background-completion tickets own the required flushes.

#### 2026-07-11 — Phase 1A download-index integration

- **Status:** main index integration complete; lifecycle and adjacent durability work remains.
- **Commit:** `f5ecf95` (`Serialize download index persistence`).
- **Changed boundary:** all eleven existing `DownloadStore.persist()` paths now assign a revision
  and capture their full snapshot together under the store lock, then serialize schema-v2 encoding
  and atomic commit outside that lock. Load-time subtitle repair uses the same writer instead of a
  failure-swallowing direct write. A failed newest snapshot remains dirty and a later mutation or
  bounded flush retries it; diagnostics retain only stage, revision, and error type.
- **Compatibility decision:** existing mutation methods still wait without a timeout for their
  submitted write attempt to commit or fail. This preserves the pre-integration contract for held
  manifests and other synchronous callers. The bounded async flush exists separately and will be
  used only after lifecycle APIs own explicit durability tickets.
- **Regression evidence:** app tests prove fresh-store restoration with schema version 2, recovery
  from an injected first atomic-write failure by a later full-state mutation, durable subtitle
  repair through the injected writer, and that a mutation cannot return while its atomic write is
  deliberately suspended. Together with the writer cases, the focused persistence suites passed
  11/11; the complete macOS and iPadOS plans passed 53/53, with Thread Sanitizer enabled on iPadOS.
- **Runtime validation:** clean Mac, iOS Simulator, and visionOS Simulator builds passed. The clean
  visionOS product matched the installed UUID, launched to the signed-in populated Home surface,
  and produced no crash, assertion, or sanitizer signature in the smoke log.
- **Known remaining boundary:** mutation APIs do not yet surface the private persistence ticket,
  so background completion cannot name an exact required revision. Held manifest/body replacement
  promises and Emby tombstones remain separate durability domains. The injected atomic-write seam
  also cannot distinguish temp-write, replace, and cleanup crash stages.
- **Next commit boundary:** surface exact tickets from the terminal/delete transitions that require
  durability, then make background-session completion await a bounded flush through the required
  ticket before releasing the OS handler. Timeout/failure must be diagnosed without abandoning the
  dirty snapshot. Ordinary progress writes remain synchronous until that lifecycle path is proven.

#### 2026-07-11 — Follow-up rebase onto download fix `640c906`

- **Status:** rebased cleanly onto local `main`; no remediation patch changed according to
  `git range-diff`. Safety ref: `codex/remediation-nondownloads-pre-main-20260711-190118`.
- **Incoming boundary:** main now retains off-head static-range progress, counts persisted held
  bodies in live progress, and keeps zero-byte paused static-range rows manually restartable. Its
  only `DownloadStore` edit is the new reconciliation input; it does not alter the writer, index
  schema, completion gate, or persistence lifecycle. The in-memory live-progress overlay must not
  become index state or a persistence revision source.
- **Compatibility evidence:** the incoming reconciliation call and all revisioned persistence code
  survived together. PMSKit passed 1,401 tests across 170 suites; the full macOS and iPadOS app
  plans passed 53/53, with Thread Sanitizer enabled on iPadOS.
- **Newly elevated pre-existing risk:** `persistHeldRangeSegment` currently reports only that its
  row mutated, not whether the synchronous manifest write committed. The caller can then delete the
  previously referenced body even though disk still contains the old manifest. Because a failed
  newest snapshot remains dirty, deleting the new body as rollback is also unsafe: a later retry
  could commit a manifest pointing to that deleted body. Main's smaller held segments increase the
  frequency of this durability boundary even though they did not create it.
- **Adjusted next boundary:** before making ordinary index mutations asynchronous, make held-body
  replacement commit-aware. Retain the new body because a dirty snapshot may commit it; delete the
  previous body only after the replacement revision commits; on failure retain both and diagnose.
  Add replacement/removal failure injection plus a store-level zero-byte static-pause reload and
  reconcile test. Then gate background completion by capturing the exact latest store revision when
  the in-memory completion gate becomes ready and performing a bounded retry/flush before firing.
- **Known bound limitation:** while mutations preserve the old unbounded synchronous write attempt,
  a truly hung initial atomic write can prevent the gate from becoming ready before the later bounded
  flush runs. A literal end-to-end bound requires a separate migration of lifecycle mutations to
  nonblocking ticket-returning submissions; merely returning a ticket after the current wait does
  not solve that case.

#### 2026-07-11 — Phase 1A held-manifest replacement ownership

- **Status:** replacement failure/cancel ownership complete; removal-result semantics remain.
- **Commit:** `7005fd5` (`Keep held range bodies valid across manifest failures`).
- **Changed boundary:** held-manifest persistence now distinguishes an accepted in-memory mutation
  from a committed revision. A failed replacement keeps the new body because the dirty snapshot may
  later commit it, and retains same-run ownership of every predecessor because disk may still name
  the old generation. Predecessors are deleted only after a committed replacement, or together with
  the current body during remove/purge/cancel. Orphan sweeping protects both current-map and retained
  generations across the non-atomic store/session ownership transition.
- **Cancel race:** the post-persistence halt check and live-map install are now one session-lock
  decision. A cancel that lands during the synchronous manifest attempt refuses reinstall, submits
  a superseding removal, and owns the new, persisted-previous, live-map, and retained body URLs.
  Pause remains preservative.
- **Regression evidence:** a production-used pure ownership policy covers failed replacement,
  later committed cleanup, cancel disposition, per-offset removal, and key purge across multiple
  generations. Store tests prove failed replacement leaves disk on the old manifest while a later
  mutation commits the new manifest, with both bodies valid throughout. A new store-level fixture
  also proves main's zero-byte static pause survives reload/reconcile while a live-forward row still
  fails closed. The complete macOS and iPadOS plans passed 59/59, with Thread Sanitizer enabled on
  iPadOS.
- **Runtime validation:** clean Mac, iOS Simulator, and visionOS Simulator builds passed. The clean
  visionOS product matched the installed UUID, launched to the signed-in populated Home surface,
  and produced no crash, assertion, or sanitizer signature in the smoke log.
- **Known remaining boundary:** manifest removal/take still return values without a commit outcome;
  a failed removal therefore remains a diagnosable lost-work/refetch case rather than a proven
  transactional delete. Background completion still fires without the explicit bounded retry/flush.
- **Next commit boundary:** capture the exact latest store ticket when the in-memory background
  completion gate becomes ready, bounded-flush/retry through it, diagnose committed/failed/timeout,
  and always release the OS handler. Keep the hung-initial-synchronous-write limitation explicit;
  nonblocking lifecycle mutations are a separate migration.

#### 2026-07-11 — Phase 1A background-completion persistence barrier

- **Status:** exact accepted-revision retry/flush before OS handler release complete.
- **Commit:** `e4e4fd4` (`Flush persistence before background completion`).
- **Changed boundary:** when the in-memory completion gate drains, the session captures the
  store's exact latest accepted revision and performs one bounded five-second retry/flush before
  releasing every ready background-session handler. Committed, failed, and timeout outcomes are
  privacy-safely diagnosed and all release the OS handler; failed/timed-out snapshots remain dirty.
- **Replay safety:** `BackgroundDownloadCompletionGate` now ignores finish events without an
  awaiting handler. Duplicate or stale callbacks therefore cannot launch a delayed barrier that
  consumes a future handler using the same fixed session identifier.
- **Regression evidence:** PMSKit gate tests cover absent and duplicate finish events. App tests
  block a real dirty retry and prove no release before commit, exercise a real bounded timeout,
  verify observation-before-release ordering, and prove the timed-out dirty revision can still
  commit later. PMSKit passed 1,403 tests across 170 suites; complete macOS and iPadOS app plans
  passed 62/62, with Thread Sanitizer enabled on iPadOS.
- **Runtime validation:** clean Mac, iOS Simulator, and visionOS Simulator builds passed. The clean
  visionOS product matched the installed UUID, launched to the signed-in populated Home surface,
  and produced no crash, assertion, or sanitizer signature in the smoke log.
- **Explicit limitation:** five seconds bounds the persistence flush wait, not synchronous
  diagnostic-sink latency. More importantly, a write already hung inside an ordinary synchronous
  mutation can prevent the in-memory gate from draining before this barrier begins. Making that
  end-to-end lifecycle literally bounded requires a separately reviewed nonblocking mutation/ticket
  migration rather than disguising a large download-engine refactor inside this slice.
- **Next 1A boundary:** make held-manifest remove/take results commit-aware, then resolve Emby
  tombstone corruption/removal ordering and add explicit temp-write/replace crash seams. If those
  require broad mutation API conversion, leave the remainder incomplete for consultation.

#### 2026-07-11 — Phase 2D compiler-cliff removal

- **Status:** complete.
- **Commits:** `cc516ea` (`Simplify optimizer item ID decoding`) and `43ba92b`
  (`Split Offline library view type-check boundaries`).
- **Optimizer boundary:** replaced the nested throwing optional/coalescing expression with explicit
  String-then-Int decoding while preserving nil for null, malformed, and missing IDs. The flexible
  ID fixture covers every accepted/rejected shape. A clean PMSKit build with 50 ms thresholds emits
  no `OptimizeRequest.Item` expression or initializer warning, down from about 2,084/2,090 ms.
- **Offline boundary:** split rows/empty state, scroll/navigation behavior, platform presentation,
  row actions, and deletion confirmation into opaque helper boundaries without moving state or
  changing modifier order. Independent review found navigation, toolbar, focus, row identity,
  swipe/delete, Mac presentation, full-screen cover, and dialog behavior unchanged. Clean Mac,
  iOS, and visionOS builds with 50 ms thresholds report no extracted boundary over 50 ms; only the
  pre-existing row renderer reports 73–81 ms, below the 300 ms acceptance target. The old root body
  measured about 2,073 ms.
- **Build evidence:** the three-run arm64 audit at
  `build/compile-audit/phase2d-43ba92b/summary.md` records clean medians of 14.85 s Mac, 12.29 s
  mobile, 12.21 s visionOS, and 5.16 s PMSKit. Against the same-machine pre-fix checkpoint these are
  improvements of roughly 11%, 13%, 21%, and 26%, so no clean-build regression was introduced.
- **Validation:** PMSKit passed 1,404 tests across 170 suites. Complete macOS and iPadOS app plans
  passed 62/62, with Thread Sanitizer enabled on iPadOS. A clean visionOS build matched the installed
  UUID, launched to the signed-in populated Home surface, and produced no crash/assertion/sanitizer
  signature in its smoke log.

#### 2026-07-11 — Phase 2A warning and dead-helper closeout

- **Status:** complete.
- **Commits:** `2fb3d00`, `5a5f050`, `cf1f919`, and `6bff1c8` remove the four
  original private definition-only helpers one at a time. Static reference checks prove each
  symbol now has zero production occurrences; their active snapshot, retry-attempt, and polling
  primitives remain in use.
- **Warning inventory:** the current production corpus has no `String(cString:)`, deprecated
  declaration, or deprecated-call occurrence. Parsing every raw Phase 2D compile-audit warning
  found no ordinary source compiler/deprecation warning; the remaining messages are exclusively
  custom type-check review triggers. The `DetailView` trigger overlaps Phase 2B's narrow lookup
  rather than representing unfinished 2A cleanup.
- **Validation:** the complete macOS plan passed 62/62. The complete iPadOS plan passed 62/62
  with Thread Sanitizer enabled. A clean visionOS build matched the installed UUID, stayed alive,
  reached the signed-in populated Home surface, and emitted no crash, assertion, or sanitizer
  signature. The deletions change no reachable behavior, schema, persistence, or download state
  transition.

The three-run arm64 checkpoint at rebased commit `cf21073` is recorded locally under
`build/compile-audit/post-main-e757bb1/` (raw logs remain ignored because they contain local
paths). Median clean builds were 15.37 s visionOS, 14.10 s mobile, 16.73 s Mac, and 7.02 s
PMSKit; no-op medians were 1.51 s, 1.19 s, 1.26 s, and 0.57 s respectively. The measurement
confirms both 2D cliffs rather than merely carrying forward the old estimate:

- `OfflineLibraryView.body` took about 2,073 ms to type-check;
- `OptimizeRequest.Item.init(from:)` took about 2,090 ms, with its ID expression about 2,084 ms.

The app clean lanes also reported smaller review-trigger warnings in `AppServices`,
`ContentView`, `DebugPlexDownloadProbe`, `DetailView`, and `SettingsView`. Treat these as the
new warning inventory; do not conflate them with the original four dead private helpers.

Two pending feature branches need explicit integration review rather than blind conflict
resolution. Saved sessions must preserve 1D's fail-closed client identity, transactional secret
semantics, and post-await auth-attempt checks; same-server/different-profile changes must also
invalidate the new download pollers/keepalives by profile identity. Music-experience changes are
mostly additive, but must retain the 1E lease and 1F lifecycle guards and rerun their ownership,
repeat/shuffle, and Up Next tests.

This plan turns the July 2026 whole-repository audit into independently reviewable work.
It is intentionally staged: correctness and test seams come before broad deduplication,
and package/target restructuring happens only after measurements show that it is useful.
Current behavior remains documented in the active architecture pages; this file describes
future work and is not itself a statement of shipped behavior.

## Outcomes

The program is complete when:

1. stale asynchronous work cannot mutate a newer auth, download, player, or media-control
   session;
2. download persistence is ordered, observable, and recoverable under concurrent writes
   and filesystem failures;
3. app-owned stateful code has deterministic tests rather than relying only on simulator
   or device checks;
4. Jellyfin and Emby share value semantics and request machinery where their contracts are
   genuinely identical, while wire and lifecycle differences stay explicit;
5. Plex browse execution has the same service boundary quality as the MediaBrowser lanes;
6. platform presentation code is separated enough that conditional compilation is
   understandable and reviewable;
7. measured type-check and incremental build hotspots are removed without behavior drift;
8. every change has a focused rollback boundary and a named validation matrix.

## Non-goals and guardrails

- Do not create one universal Plex/Jellyfin/Emby protocol.
- Do not merge Jellyfin live-forward download orchestration with Emby persistent Convert.
- Do not redesign player, Offline, login, or Mac UI while extracting implementation seams.
- Do not change request paths, query casing, headers, token placement, request bodies,
  cleanup semantics, or persisted raw values without focused compatibility tests.
- Do not move framework effects into PMSKit merely to make them easier to test.
- Do not split PMSKit or Xcode target membership for directory aesthetics; keep a split only
  when ownership and measured incremental-build results improve.
- Preserve the `Generic` Plex client profile and current profile-extra behavior.
- Keep diagnostics privacy-safe: no hosts, tokens, titles, filenames, paths, or raw device IDs.

## Audit register

Every finding is assigned to a phase below.

| ID | Finding | Priority | Planned phase |
| --- | --- | --- | --- |
| `COR-01` | Old download finalization can mutate/delete a replacement attempt. | P0 | 1B–1C |
| `COR-02` | Concurrent `DownloadStore` snapshots can commit out of order. | P0 | 1A |
| `COR-03` | Delayed encoder cleanup can clear a newer `PlaySessionId`. | P0 | 1C |
| `COR-04` | Plex PIN / Quick Connect continuations can authenticate after cancellation. | P0 | 1D |
| `COR-05` | Music teardown can remove video remote-command targets and Now Playing state. | P0 | 1E |
| `COR-06` | Queued player/music callbacks can run after teardown. | P1 | 1F |
| `COR-07` | Side-asset tasks can write after delete/retry or attach stale assets. | P1 | 1C |
| `REL-01` | Some Keychain identity/backend writes fail silently. | P1 | 1D |
| `REL-02` | Stateful app orchestration has no app unit-test target. | P1 | 0B |
| `REL-03` | `PlexPhotoTranscode` has production call sites but no direct coverage. | P1 | 2A |
| `PERF-01` | HTTP error handling allocates the whole temporary body just to count bytes. | P1 | 2A |
| `PERF-02` | Single-row download lookups hydrate and sort the whole Offline library. | P1 | 2B |
| `PERF-03` | Up to eight independent MediaBrowser latest rails load sequentially. | P1 | 2C |
| `BUILD-01` | `OfflineLibraryView.body` takes about 1.49–1.97 s to type-check. | P1 | 2D |
| `BUILD-02` | Optimizer item decoding takes about 1.84–1.91 s to type-check. | P1 | 2D |
| `BUILD-03` | One deprecation warning, four unused helpers, and a dead clock parameter remain. | P2 | 2A |
| `ARCH-01` | Jellyfin, Emby, and neutral playback carriers duplicate the same values. | P1 | 3C |
| `ARCH-02` | MediaBrowser progress request construction is repeated in three layers. | P1 | 3D |
| `ARCH-03` | MediaBrowser identity/auth result/server URL value types are duplicated. | P2 | 3B |
| `ARCH-04` | Shared device-profile facts live twice and Emby reaches into Jellyfin helpers. | P1 | 3E |
| `ARCH-05` | Jellyfin/Emby library request builders are about 62% structurally similar. | P2 | 4A |
| `ARCH-06` | Jellyfin/Emby app browse services are about 68% structurally similar. | P2 | 4B |
| `ARCH-07` | Plex browse builders/execution remain scattered through app code. | P2 | 4C–4D |
| `ARCH-08` | Three isomorphic three-case backend enums plus one two-case progress enum require conversion switches. | P2 | 3A |
| `ARCH-09` | 708 app conditional directives are concentrated in mixed platform views. | P2 | 5A–5C |
| `ARCH-10` | All targets receive the full source group, including Debug probes/platform files. | P3 | 5D |
| `ARCH-11` | PMSKit is one broad module with roughly 360 public declarations. | P3 | 6 |
| `ARCH-12` | The 833-line phantom-generic MediaBrowser DTO graph may add needless specialization. | P3 | 6 |
| `ARCH-13` | Core coordinators are 3,000–5,500-line review and recompilation hotspots. | P2 | 5E |

## Program rules

Each pull request or local commit series must:

- start with a failing regression or characterization test where feasible;
- contain one behavior change or one mechanical extraction, not both;
- name the exact hermetic, build, simulator, live-server, and physical-device gates it needs;
- remain independently revertible, except where a reviewed schema/task-marker compatibility
  window explicitly requires dual-read support or quiescing active work before rollback;
- keep persistence and wire formats unchanged unless migration is the sole reviewed purpose;
- avoid unrelated formatting or documentation churn;
- preserve the regression fixture and assertion if an implementation is reverted. If the old
  implementation still fails it, keep it explicitly skipped/marked as a known failure linked to
  the reopened issue rather than weakening or silently deleting it.

Normal production changes should aim for fewer than roughly 300 changed lines. A larger
mechanical move is acceptable only when behavior is unchanged and reviewed separately from
logic changes.

## Phase 0 — baseline and testability foundation

### 0A. Check in repeatable measurements

Add an opt-in compile/performance audit script using isolated DerivedData and a fixed
architecture. Record:

- PMSKit cold, no-op, and test builds with coverage and peak RSS;
- clean, no-op, and representative one-file incremental builds for visionOS,
  `LabstreamMobile`, and `LabstreamMac`;
- `-showBuildTimingSummary`, function/expression type-check timings, warning inventory,
  app/Mach-O sizes, and compiled-file/link fanout;
- representative edits to a PMSKit policy, a shared app leaf, and a current coordinator.

Use the median of three comparable runs on the same Mac/Xcode. Label generic dual-architecture
results separately. Initial thresholds are review triggers, not flaky CI failures:

- function/body type-check over 300 ms;
- expression type-check over 200 ms;
- clean-build median regression over 10%;
- representative incremental median regression over 15%;
- peak RSS or binary-size regression over 10%.

### 0B. Add app-owned deterministic tests

Add a `LabstreamTests` unit-test target, initially runnable on the macOS host and with an
iOS Simulator test action for platform-specific cases. Keep the hybrid boundary:

- PMSKit continues to own pure request, model, and policy tests;
- app tests own Keychain adapters, download index/filesystem behavior, background delegate
  orchestration, auth coordination, AVPlayer lifecycle, and MediaPlayer ownership.

Introduce only narrow injectable seams:

- index/filesystem writer, stat, move, replace, and removal operations;
- auth request executor, secure credential store, clock/sleeper, and attempt-ID source;
- Now Playing store and remote-command registrar;
- request executor for Home rails and side assets.

Tests must be able to suspend and resume I/O/network continuations deterministically and
must not need a live Keychain, media server, UI session, or real sleep.

Add a shared scheme/test plan that runs a nonzero expected test count on both the macOS host and
an iOS Simulator destination. Treat a green invocation that discovers zero app tests as failure.

### Phase 0 acceptance

- Baseline commands and privacy-safe summaries are reproducible.
- Existing tests/builds remain green before production behavior changes.
- The new target proves that controlled concurrent writes and delayed async completions can
  be exercised deterministically.

## Phase 1 — correctness and lifecycle safety

Phase 1 is the release-blocking portion of this plan.

### 1A. Serialize download-index persistence (`COR-02`)

Add a serial, revisioned persistence executor:

1. assign a monotonically increasing revision while holding the store lock;
2. submit `(revision, snapshot)` to one writer;
3. coalesce obsolete progress snapshots and never commit a revision older than the newest
   submitted/committed revision;
4. keep slow encoding and filesystem I/O outside `NSLock`;
5. expose redacted write/encode failures;
6. provide a bounded `flush()` (required, not optional) plus explicit terminal/delete/session
   durability for lifecycle transitions that promise disk persistence. The background-session
   completion-handler path depends on `flush()`: because I/O stays outside the lock and
   snapshots coalesce, awaiting a bounded flush is the only way that path can honor the
   "no durable-completion signal before the required revision commits or fails observably"
   rule below.

A failed newest revision remains dirty and retries on a later mutation/flush; it is never marked
committed or abandoned merely because no newer mutation exists. The last valid index must remain
readable throughout temp-write/replace failure.

Deterministic tests must block revision N, commit N+1, release N, create a fresh store, and
prove N+1 is restored. Add concurrent progress/status/metadata/delete stress and fault
injection for encode, write, rename, permission, disk-full equivalent, and removal failures.
Add crash points before temp write, after temp write/before replace, and after replace. The app
must not invoke the background-session completion handler or otherwise advertise durable
completion before the required revision has committed or failed observably.
This phase does not change the index schema.

### 1B. Introduce a durable download-attempt identity (`COR-01`)

Add `DownloadAttemptID: Codable, Hashable, Sendable` and make it the ownership key for a
single download attempt.

Prior art: `DownloadManager+EmbyConvert` already tracks per-Convert attempt UUIDs. That
tracking must be absorbed by (or explicitly keyed to) `DownloadAttemptID` in this phase —
do not leave two parallel attempt-identity mechanisms on the same row. If Convert keeps an
inner job identity, document its relationship to the row's attempt ID and cover the pairing
in the migration tests.

- Persist it on every newly created row through terminal cleanup; only migrated legacy completed
  rows with provably no asynchronous work may remain without one.
- Extend opaque task identities and static segment markers to include rating key, attempt ID,
  and segment offset where applicable.
- Carry it in all in-memory transfer/finalization entries.
- Add attempt-conditional store APIs for status, progress, metadata, remove, and ownership
  checks.
- Reject attempt-A callbacks after attempt B owns the same rating key.

This change must land atomically across marker parsing, reattach, and store mutation guards.
Use download-index schema v3 so a missing attempt ID is distinguishable as legacy data rather
than a malformed new write. Legacy rows decode with an optional attempt ID. On upgrade, assign
one stable ID to each legacy active row and **durably commit it before** background-session
callbacks are admitted or tasks are rebound. Test termination between assignment, index commit,
task rebinding, and the first callback. Completed legacy rows with no asynchronous cleanup need
no active task identity.

Keep dual-read support for old and new task markers during the rollout. Once new markers are live,
an operational rollback must retain the new parser/schema reader or first quiesce, reconcile, and
cancel/drain all new-format tasks; a blind code revert is unsafe.

### 1C. Scope every asynchronous download tail (`COR-01`, `COR-03`, `COR-07`)

Add a `DownloadWorkRegistry` keyed by `(ratingKey, attemptID)` for finalizers, side caches,
and teardown ownership.

- Cancel finalizers and side-cache work on delete, retry, or supersede.
- Do **not** cancel required Jellyfin/Emby encoder DELETE merely because the row is deleted.
  Persist a cleanup intent/tombstone keyed by attempt, backend, server identity, and expected
  session ID; clear it only after confirmed teardown. Old cleanup may finish while attempt B runs,
  but must never mutate B.
- Recheck ownership after every suspension and immediately before file move/delete or store
  mutation.
- Use attempt-specific staging paths, committing to stable filenames only after validation.
- Make `finalizing` bookkeeping attempt-scoped.
- Add `clearPlaySessionID(ratingKey:expectedID:attemptID:)` compare-and-clear semantics.
- Require expected attempt IDs for poster, subtitle, BIF, trick-play, and chapter metadata.
- Reconcile and sweep unreferenced attempt-specific staging files on startup. Test hard kill at
  write → validate → move → metadata boundaries.

Regression tests cover delete/re-add while old finalization, encoder DELETE, and each side-cache
type are suspended. Attempt A must never affect attempt B, suppress B finalization, clear B's
encoder ID, or leave an unowned asset.

### 1D. Unify auth-attempt generations and Keychain failure semantics (`COR-04`, `REL-01`)

Create one ephemeral authority generation/`AuthAttemptID` model and guarded commit path for Plex
PIN, Jellyfin credentials/Quick Connect, Emby credentials/Connect, saved-session restore, and
post-auth discovery.

Prior art: `AuthManager` already guards the Jellyfin/Emby credential and Connect flows with
per-flow `active*AttemptID` UUID checks after awaits. This phase replaces those ad-hoc fields
with the unified model rather than adding a second layer; the audit gaps are the flows those
fields do not cover (Plex PIN, saved-session restore, post-auth discovery) and the
commit-atomicity/Keychain-failure semantics.

- Begin/cancel one current attempt per visible auth operation.
- Check identity and cancellation after every await and before Keychain, AppModel, selected
  server/backend, or UI state mutation.
- Retain/cancel the UI task as well as polling tasks.
- Never publish authenticated runtime state if secure persistence fails.
- Make stable client-identifier and selected-backend persistence failures observable rather
  than silently manufacturing a new identity on the next launch.
- Perform network discovery with attempt-local credentials, then make one non-suspending guarded
  Keychain/AppModel/state commit. If a flow cannot commit atomically, define and test rollback;
  checking identity before multiple separated mutations is insufficient.

Tests hold responses at every suspension point, switch backend or start attempt B, then release
attempt A and assert zero stale state or credential writes. Include sign-out/backend switch during
saved-session restore and post-auth discovery. Attempt IDs are not persisted, so this phase needs
no migration.

### 1E. Coordinate system-media ownership (`COR-05`)

Introduce an `@MainActor SystemMediaSessionCoordinator` that issues a lease/owner UUID.

- Both music and video update or clear Now Playing only while their lease is current.
- Music retains every token returned by `addTarget` and removes only its own targets; never
  call `removeTarget(nil)`.
- Centralize command enabled-state and preferred-interval save/restore.
- Reject delayed artwork/state updates from an old owner.

Land coordinator adoption for music and video together. Tests cover music → video → music,
music stop while video owns controls, rapid ownership changes, stale artwork, double teardown,
and failure recovery. Physical iPad and Mac validation cover Control Center/lock screen,
headphones/media keys, route interruptions, and background/foreground transitions.

### 1F. Add player lifecycle generations (`COR-06`)

Video and music each receive a lifecycle generation incremented on configure/start, item
replacement, and stop. Every KVO, periodic-time, notification, artwork, and audio-session
callback captures and validates it inside its actor continuation. Remove unnecessary
unstructured main-actor hops when delivery is already safe.

Tests queue old `.playing`, marker, heartbeat, artwork, interruption, and route callbacks,
tear down or replace the item, then release them. No old callback may resurrect playback,
mutate markers, report after final stopped, resume audio, or touch Now Playing.

### Phase 1 acceptance

- Thread Sanitizer passes targeted download/auth/ownership stress suites.
- No old attempt/generation can mutate a newer one.
- Relaunch restores the newest durable download state.
- Existing partial/completed downloads survive migration and background tasks reattach.
- Exactly one media owner controls Now Playing/remote commands.
- A cancelled auth attempt can never later authenticate or persist credentials.

## Phase 2 — focused reliability, performance, and compiler wins

These are small, independently revertible changes and may proceed in parallel after Phase 0,
provided they do not touch Phase 1 code under active review.

### 2A. Coverage and low-risk cleanup

- Add `PlexPhotoTranscode` table tests for absolute/relative paths, escaping, existing query,
  token, dimensions, min-size/upscale, and invalid input (`REL-03`).
- Replace error-body `Data(contentsOf:).count` with filesystem stat and prove memory is
  independent of file size using a large sparse fixture (`PERF-01`).
- Replace deprecated `String(cString:)` with the modern decoding API.
- Remove the four verified unreferenced private helpers, one per mechanical commit.
- Either thread `MediaSessionProxy`'s injected clock into its restart budget or remove the
  misleading parameter (`BUILD-03`).

### 2B. Add narrow Offline lookups (`PERF-02`)

Add locked `record(for:)`, metadata, duration, and ownership accessors. Replace callback/retry
paths that currently hydrate and sort all records. Keep `records` for UI snapshots.

Benchmark 10, 100, and 1,000 rows. A single-key lookup must not sort, stat, or hydrate unrelated
rows, and must remain semantically equivalent to the former lookup.

### 2C. Bound MediaBrowser latest-rail concurrency (`PERF-03`)

Use a bounded task group (initial cap 3–4) for up to eight independent latest-library requests.
Preserve library display order and degraded/error accounting regardless of completion order.
Tests assert max in-flight count, cancellation, reverse-completion ordering, and partial failure.

### 2D. Remove type-check cliffs (`BUILD-01`, `BUILD-02`)

- Split `OfflineLibraryView.body` into concrete empty/list content, platform presentation,
  toolbar, and deletion-confirmation pieces without changing state ownership or visuals.
- Rewrite optimizer item decoding with explicit locals or a small flexible-ID decoder rather
  than nested `try?`/optional-coalescing expressions.

Acceptance targets:

- no extracted Offline body over 300 ms;
- optimizer decoder below 150 ms, preferably below 50 ms;
- no clean-build regression over 5% for the view extraction;
- identical optimizer decode behavior for string/integer/null/malformed IDs and missing fields.

## Phase 3 — neutral MediaBrowser value and playback seams

Each subsection is a separate wire-compatible change.

### 3A. Canonical backend identifier (`ARCH-08`)

Introduce a PMSKit `MediaBackendID` with the unchanged `plex`, `jellyfin`, and `emby` raw values.
Preserve old names as aliases/extensions during migration and remove one-to-one conversion
switches. Legacy download rows and system-entry identifiers must decode unchanged. Establish this
tag first because neutral playback carriers and progress dispatch depend on it.

### 3B. Shared identity/auth/server URL values (`ARCH-03`)

Introduce common MediaBrowser client identity, authenticated user/result, and validated server
URL primitives. Preserve backend names temporarily with typealiases. Auth flows, authorization
schemes, Connect/Quick Connect, and token placement remain backend-specific.

### 3C. One neutral playback boundary (`ARCH-01`)

Make `MediaBrowserPlayMethod`, `MediaBrowserPlaybackSourceMetadata`, and
`MediaBrowserPlaybackOpenResult` the sole app-facing results of Jellyfin and Emby stream
resolution. Replace separate app remote-playback state with one backend-tagged value while
retaining explicit `usesServerEncoding` cleanup semantics. Keep compatibility aliases/wrappers
until all call sites migrate.

### 3D. Shared progress request plan (`ARCH-02`)

Introduce a common progress payload, endpoint, and request plan parameterized only by URL/auth
dialect and real Emby deltas. Existing Jellyfin/Emby public request functions delegate during
transition. Golden tests cover backend × Playing/Progress/Paused/Stopped: method, endpoint,
headers, body keys, ticks, play method, and token redaction.

### 3E. Shared MediaBrowser device-profile facts (`ARCH-04`)

Move common direct-play, streaming-transcode, compatible-remux, and Dolby Vision conditions
into MediaBrowser helpers. Parameterize subtitle policy; keep Emby static-download restrictions
separate. First retain existing dictionary shapes, then consider typed `Encodable` DTOs only in
a later byte-equivalence-tested change.

### Phase 3 acceptance

- Backend request/fixture suites and all target builds pass.
- Existing public wrapper names remain source-compatible during transition.
- No playback source metadata/header or cleanup behavior is lost.
- Secret-gated Jellyfin and Emby playback/timeline probes pass; SKIP is not treated as proof.
- Clean and incremental build measurements remain within Phase 0 thresholds.

## Phase 4 — request factories and capability services

### 4A. Shared MediaBrowser library request factory (`ARCH-05`)

Build on the existing path/query dialect and share the 21 identical request concepts: views,
items/paging/search, album artists, playlists, resume, next up, latest, metadata, watched state,
artwork/chapters, subtitles/audio, and active-encoding stop. Adapters retain backend path/query
casing, auth, and error mapping. Existing public backend methods delegate first.

Table-driven golden tests compare method, base-path-preserving URL, ordered percent-encoded query
items (including duplicate keys), headers, and body. Treat ordering as irrelevant only when a
focused test and server contract explicitly prove that it is. Emby Convert/download and Jellyfin
live-forward routing stay outside.

### 4B. Shared MediaBrowser browse core (`ARCH-06`)

Share response decoding, DTO mapping, page construction, search fanout, and common metadata/
watched behavior behind thin backend facades. Prototype a flavor-generic core and a closure/value
adapter; choose the clearer option with lower type-check/API cost rather than maximizing deleted
lines. Preserve Home/search/paging ordering and degraded behavior.

### 4C. Move Plex browse builders to PMSKit (`ARCH-07`)

Move pure sections, paging, character counts, hubs, On Deck, search, children, and metadata
request shapes into PMSKit. Keep the app `BrowseAPI` as a forwarding wrapper during migration
and prove request equivalence.

### 4D. Add a Plex browse service and narrow capabilities (`ARCH-07`)

Add an app service that owns current Plex session resolution, execution, decoding, and normalized
outputs. Migrate direct sends out of SwiftUI/paging/intents/music. Share only real UI capabilities
such as metadata loading, watched mutation, library paging, search, and Home. Plex `/hubs` remains
native rather than being forced through MediaBrowser Home.

Baseline roughly 29 `BrowseAPI` references and 30 direct Plex sends. Acceptance is zero direct
Plex execution from SwiftUI, paging, intents, and music, excluding intentional Debug/live probes.

### Phase 4 acceptance

- No unexplained wire diff or new 4xx/decode/base-path failure.
- Live Plex/Jellyfin/Emby browse probes pass for touched lanes.
- Home/search ordering and backend-specific capabilities remain unchanged.
- No broad download/backend protocol is introduced.

## Phase 5 — platform presentation and coordinator decomposition

### 5A. Extract platform-only leaf types (`ARCH-09`)

Mechanically move iOS styles/route picker, Mac window/fullscreen helpers, visionOS Cinema
adjustment UI, and platform player-layer representables into whole-file platform guards.
No logic or visual changes.

### 5B. Split player chrome by platform (`ARCH-09`)

Create shared chrome state/actions plus `VisionPlayerChrome`, `MobilePlayerChrome`, and
`MacPlayerChrome`, selected by a tiny compile-time root. Platform views own layout/material/
keyboard/PiP/AirPlay/fullscreen concerns; shared playback behavior stays common.

Target: reduce the top three files' conditional directives from 274 to under 100 without
runtime type erasure or build regression.

### 5C. Replace layout-only conditionals with metrics (`ARCH-09`)

Use injected/environment layout metrics for repeated login/control sizing and materials.
Keep conditionals where platform APIs or feature availability truly differ.

### 5D. Evaluate Debug probe and target membership isolation (`ARCH-10`)

First extract value-only probe plans/results and retain a thin app coordinator. Create a separate
Debug module or target-membership exceptions only if normal Debug incremental builds improve,
production linkage remains absent, and app internals do not become public.

### 5E. Extract coordinator responsibilities (`ARCH-13`)

Incrementally extract along existing seams, not as rewrites:

- playback HLS/recovery and audio/subtitle selection coordinators;
- static-range transfer/finalization coordinator;
- indexed store gateway;
- shared chrome menu/presentation models.

Every extraction is a mechanical move followed by separately reviewed behavior changes.

### Phase 5 acceptance

- visionOS, iPhone, iPad, and Mac builds/smokes pass.
- Player layout, menus, scrub, Cinema, PiP/AirPlay, keyboard/fullscreen, and media ownership
  keep explicit platform validation.
- Conditional density and representative incremental-build fanout improve measurably.

## Phase 6 — optional PMSKit/module decomposition

Start only after Phases 0–5 reduce and stabilize public seams.

1. Decide/benchmark the phantom `MediaBrowserFlavor` generic before freezing module boundaries.
   Compare it with one raw DTO graph plus an explicit backend/reference factory; retain the
   generic unless API simplicity or measured compile results improve.
2. Produce a dependency graph and public API inventory classifying models, policies, wire
   builders/decoders, runtime networking/proxy, filesystem/storage, diagnostics, and security.
   Pin the public-surface metric first: the "roughly 360 public declarations" figure counts
   top-level public types/functions (a raw `public`-keyword line count is ~2,400 including
   members). Record the exact measurement command in the Phase 0A script so before/after
   comparisons for the split's "reduces the reviewed public surface" gate are reproducible.
   Explicitly classify `MediaBrowserRequestExecutor`, `MediaSessionProxy`, HEVC/file helpers,
   credential storage, and UserDefaults-backed library visibility.
3. Use API-digester output to decide whether the split is an intentional breaking change or
   preserves a supported `PMSKit` facade before migrating roughly 99 app importers or external
   `import PMSKit` users.
4. Extract runtime effects first where cycles permit, keeping most stable models/policies in
   PMSKit initially.
5. Evaluate a final `PMSModels` / `PMSPolicies` / `PMSWire` / `PMSRuntime` shape and use Swift
   `package` visibility for internal cross-target helpers.
6. Partition hermetic and live tests with their owning modules.

Keep a module split only if it has no cycles, does not regress clean builds, reduces the reviewed
public/dependency surface as designed, and improves a representative one-file incremental build
by at least 20%. Avoid underscored re-export imports as the long-term facade.

## Validation matrix

### Required for every production PR

- `cd PMSKit && swift test`
- focused `LabstreamTests`
- `scripts/ci-hygiene.sh`
- strict MkDocs build when docs change
- warning-free affected target build after `BUILD-03`

The shared test plan must execute the expected nonzero app-test count on macOS and iOS Simulator.
Phases 3–6 also require the existing Linux XCTest and Swift Testing CI lanes, while macOS remains
required for `canImport(Network)`/MediaSession behavior excluded on Linux.

### Shared app changes

- clean build/install/launch/log/screenshot on the worktree visionOS simulator;
- iPhone and iPad `LabstreamMobile` builds, with both simulator smokes for UI/platform changes;
- `scripts/validate-macos-228.sh` and bounded Mac host smoke;
- serialized simulator leases and worktree-scoped DerivedData as required by `CLAUDE.md`.

### High-risk lifecycle changes

- targeted Thread Sanitizer tests before merge;
- controlled force-quit/relaunch/reattach and filesystem-failure tests;
- signed physical validation **before merge or before enabling a guarded path**: iPad/Vision Pro
  for marker migration, reattach, background completion, and lock/off-head transfer; iPad/Mac for
  media ownership; affected hardware for audio/player lifecycle;
- iPhone hardware when compact form factor or iPhone-only behavior differs;
- touched Plex/Jellyfin/Emby live-server probes, with absent credentials reported as SKIP.

Simulator success cannot waive physical gates for background transfer, lock/off-head behavior,
Control Center/media keys, PiP/AirPlay, HDR/DV rendering, or Custom Cinema.

Physical gates depend on user-performed device installs (signing and headset/iPad access are
the user's half), so Phase 1 must not serialize on hardware availability. While a device gate
is pending: the slice may land only behind a guarded/disabled path with the gate recorded as
an open blocker on its tracking entry, or the next slice may be stacked unmerged on top of it.
Enabling the guarded path, or merging an unguarded slice, still requires the completed gate.

Before Phase 5/6 completion and before any release milestone, require unsigned Release/archive-
equivalent builds for `Labstream`, `LabstreamMobile`, and `LabstreamMac`, plus PMSKit release build.
This catches whole-module optimization, `#if DEBUG`, probe linkage, availability, and membership
failures that Debug smokes cannot.

## Rollout and rollback

- Land Phase 1 safety work before architecture refactors.
- Stage high-risk changes to internal/device builds and exercise background/relaunch cycles before
  widening use.
- Use DEBUG shadow comparison for shared request builders where practical.
- A runtime kill switch may temporarily protect bounded Home concurrency. A media-ownership switch
  may only fail closed into a safe degraded mode (for example disabling system remote commands);
  it must never restore `removeTarget(nil)` or unowned Now Playing writes. Do not ship a fallback
  that re-enables unordered persistence.
- Keep the download index schema unchanged for Phase 1A; any attempt-ID migration gets its own
  forward/backward compatibility review.
- Once attempt-bearing markers exist, rollback must preserve dual-read parser/schema support or
  first quiesce/cancel/reconcile every new-format task. The generic immediate-revert rule does not
  apply to Phase 1B/1C.

Immediate revert triggers:

- index decode failure, corruption, or state rollback;
- lost/duplicated background task or incomplete-file completion;
- stale auth completion, credential overwrite, or unexpected sign-out;
- duplicate/lost remote commands or wrong Now Playing owner;
- unexplained request golden/live mismatch;
- new crash, hang, playback/startup regression, or unbounded request concurrency;
- unexplained compile, RSS, or binary-size threshold regression.

Revert the individual slice and revise the implementation; do not roll back unrelated completed
phases. Retain its fixture and assertion as a passing test under a safe alternate implementation,
or explicitly mark it as the known failure tied to the reopened issue when the reverted code still
violates it.

## Suggested commit/PR sequence

1. Baselines and `LabstreamTests`/fakes only.
2. `PlexPhotoTranscode` coverage.
3. Deprecation fix, each dead-helper removal, error-size stat, and MediaSession clock cleanup as
   separate tiny commits.
4. Serialized `DownloadStore` persistence and fault tests.
5. Download attempt model, marker migration, and attempt-aware store APIs.
6. Attempt-scoped finalization, persisted teardown intent, and side assets.
7. Keychain failure semantics, then auth-generation coordination.
8. System-media ownership coordinator.
9. Player/music callback generations.
10. Narrow Offline lookups, bounded Home rails, and compiler hotspots as separate
   small changes.
11. Canonical backend ID, then MediaBrowser value/carrier/progress/profile slices.
12. MediaBrowser request/browse core, one vertical capability at a time.
13. Plex builders/service migration.
14. Platform chrome and coordinator mechanical extractions.
15. PMSKit module decision gate and optional split.

## Tracking discipline

When implementation begins, create one issue or checklist entry per audit ID/phase slice. Each
entry records:

- owning finding IDs;
- exact files/APIs in scope;
- failing regression/characterization test;
- migration and rollback notes;
- required simulator/live/device lanes;
- before/after build or runtime measurement where relevant;
- final evidence and commit/PR.

Close a finding only when its acceptance criteria and required evidence are complete; deleting
duplicate lines or making a build green is not sufficient proof.
