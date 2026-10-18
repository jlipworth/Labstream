# Downloads and offline playback

Labstream downloads are implemented for the visionOS, iOS/iPadOS, and macOS targets and are designed
to end in a local file the current device can play, plus enough metadata to show the item in the
offline library and resume safely. The same engine is present in the [macOS target](MACOS.md), where
background recovery remains a pre-release acceptance gate rather than a reliability promise. The
[tvOS target](TVOS.md) compiles no Downloads capability or Offline surface.

```mermaid
flowchart TD
  accTitle: Static and live-forward download routes
  accDescr: User and recovery requests share admission. Backend inspection selects a static source, server preparation, or live-forward stream. Completion captures and validates the body before publication as complete or unverified. Both local launch surfaces use one exact-attempt factory and event sink.
  Request[Tap, season, resume or recovery] --> Admission[Shared admission window]
  Admission --> Inspect[Inspect backend media options]
  Inspect --> Prep[Plex optimize or Emby Convert]
  Prep --> Static
  Inspect --> Static[Static original, existing, or prepared file]
  Inspect --> Live[Live-forward remux or transcode]
  Static --> Train[Closed-range segment train and durable partial]
  Live --> Forward[One forward-only transfer]
  Train --> Validate[Completion and local playback validation]
  Forward --> Validate
  Validate --> Store[Published complete or unverified file and index]
  Store --> Offline[Offline library and Detail]
  Offline --> Factory[Exact-attempt launch factory after orientation]
  Factory --> Player[Local player and event sink]
```

The admission window is shared by user actions and recovery. Server preparation hands a completed
render to the static lane; live-forward streams cannot claim static byte resume. Finalization
captures an attempt-owned body, rewrites HEVC tags and validates before publication. Probe-inconclusive
and repeated-truncation files remain playable as unverified. Detail and Offline use the same local
launch factory, with position saving and actual-playing verification as separate events.

## Core rules

- A completed download must have a local playable file and a durable offline record.
- Direct original downloads are offered only when Labstream expects the file to play locally.
- Server-rendered or server-prepared routes are used when the original is not a safe local target.
- Transfers reconcile on relaunch. Static/original and server-prepared static routes
  resume from durable checkpoints when their persisted authority remains valid; live-forward
  remux/transcode streams may become retryable and restart from the beginning
  rather than claiming unsafe byte-offset resume.
- Offline records must never contain access tokens. They do persist the minimum backend
  context needed to resume and clean up a job, which currently includes the owning backend,
  server base URL/server ID, MediaBrowser user ID where applicable, media/play-session IDs,
  and route/checkpoint state. See [Persistence](PERSISTENCE.md#app-container) for the complete
  on-disk and credential boundary. Treat `index.json` as private app data, not a shareable profile.

## Backend routes

| Backend | Download choices |
| --- | --- |
| Plex | Compatible original, explicit existing version, and completed optimizer output all hand off to a static file transfer. |
| Jellyfin | Original is static/range-resumable. Compatible remux and capped transcode are live forward-only streams. |
| Emby | Original, reusable existing version, and completed Convert output are static. Compatible remux is live forward-only; a requested transcode is normally rerouted through persistent Convert-then-static. |

## Transfer lifecycle

Each download row persists a **lifecycle** and an **attempt history**. Every change to them goes
through one pure reducer, `DownloadLifecycleReducer`. The serialized `DownloadStatus` that the
UI, diagnostics and older app versions read is derived from the lifecycle.

```mermaid
stateDiagram-v2
  accTitle: Download lifecycle
  accDescr: A row is planned or admitted, may prepare on the server, transfers bytes, and enters finalizing once a complete body exists. Finalizing ends complete or unverified after publication, or failed. Interruptions pause a row with a recorded cause; errors fail it with a recorded reason. Retry modes choose where a paused or failed row resumes.
  state "planned" as Planned
  state "admitted" as Admitted
  state "serverPrep" as ServerPrep
  state "transferring" as Transferring
  state "finalizing" as Finalizing
  state "paused" as Paused
  state "failed" as Failed
  state "complete" as Complete
  state "unverified" as Unverified
  [*] --> Planned
  [*] --> Admitted
  Planned --> Admitted: admission granted
  Admitted --> ServerPrep: Emby Convert
  Admitted --> Admitted: Plex optimize preparation
  ServerPrep --> Admitted: prepared source handed off
  Admitted --> Transferring: transfer starts
  Transferring --> Finalizing: complete body at the working path
  Finalizing --> Complete: validated and published
  Finalizing --> Unverified: published; probe inconclusive or repeated truncation
  Finalizing --> Failed: validation fails
  Transferring --> Paused: interruption (cause recorded)
  Transferring --> Failed: transfer fails (reason recorded)
  Paused --> Admitted: resume or retry
  Paused --> Transferring: resume blob
  Paused --> ServerPrep: prep reattach or Convert resume
  Failed --> Admitted: retry
  Unverified --> Complete: eligible actual playing or revalidation
  Complete --> [*]
  Unverified --> [*]
```

This diagram shows lifecycle destinations; admission and retry routing still depend on durable
facts. Plex preparation retains admitted/queued compatibility, while Emby Convert uses serverPrep.
Finalizing is not paused by cancelling its validator. Only eligible actual-playing evidence or
successful revalidation can clear an unverified warning; playing the start of a known truncated file
cannot prove its tail exists.

| Lifecycle | Serialized status |
| --- | --- |
| `planned`, `admitted` | `queued` (a `planned` row is waiting for an admission lane) |
| `serverPrep` | `preparing` for Emby Convert; Plex optimizer rows stay `admitted`/`queued` until the handoff |
| `transferring`, `finalizing` | `downloading` |
| `complete`, `unverified`, `paused`, `failed` | the same name |

**Attempt history** records what no status can:
- truncation strikes;
- the reason a row is `unverified`;
- the last failure;
- why a row paused (user, queue paused, system interruption, awaiting a session, storage,
  deferred resume).

Rules that follow from this:

- **Progress never promotes a paused, failed or finalizing row.** It only records the bytes
  (B09).
- **`finalizing` is persisted** as soon as a complete body reaches the attempt working path. A
  relaunch before validation re-finalizes that body instead of deleting it (B10). A forward-only
  body exists at the working path only once its whole transfer finished, so the same rule covers
  a finished forward-only body whose task was lost.
- **Truncation strikes persist** with the row and survive a relaunch.
  - A Retry of the same server, account, item, source and profile inherits them, and a replayed
    validation outcome is not counted twice.
  - The second strike keeps the body as `unverified` and publishes it.
  - Revalidating a published body never fails or deletes it for truncation (B54).
- **Relaunch reconciliation** applies the reducer to each row's facts: route, durable checkpoint,
  body, pending artifact intents, deletion state and live task. Any file deletion it decides runs
  outside the store lock.

Finalization still rewrites HEVC `hev1` to `hvc1` before validation, and both terminal success
states keep the local file. The opaque and static-range pipelines share the completion path.

### Truncation and checkpoint authority

A failing truncation verdict permanently condemns that attempt's working body. A best-effort rename
removes it from the working path before persistence waits; the persisted condemnation fence also
blocks checkpoint reads, recovery finalization and Retry cloning if rename/removal fails. Replacing
an attempt inherits only same-source truncation strikes, never condemnation or unrelated failure
state. A condemned Retry starts at zero even if its backend becomes available later. Replayed body
outcomes do not count another strike. A second-strike published body remains unverified and playable
across relaunch; neither position updates nor actual playing erase that warning.

### Bounded background completion

OS completion handlers are timestamped at registry receipt, including before session construction.
One non-sliding wake budget covers finish-events, identified operations and the captured index plus
artifact boundary: 25 seconds overall, 20 seconds for operations and a 5-second persistence reserve.
Normal release requires finish-events, settled required operations and persistence covering their
resulting boundary. Expiry is an explicit timeout, not successful durability or physical cancellation.
Exact handler tokens release once; an old timer or operation end cannot release a later generation.

Blocked-before-transport, activation-in-progress and failed-after-transport remain distinct. A
blocked dormant session can release a late handler; an existing healthy transport retains its owned
holds. Expiry also fences later activation, refill and probing until foreground or a new authorized
wake. Dirty index work, artifact intents and worker-owned path leases survive a waiter's timeout.
No AVPlayer validation probe starts while inactive; foreground revalidation remains recoverable.
These are app-side bounds, not proof of OS scheduling or background continuation on hardware.

## Background downloads and sleeping devices

The Downloads header reports aggregate speed only when every transferring attempt has fresh
delegate observations over one common interval within the last four seconds. It shows
**Updating speed…** while that evidence is incomplete; queued, preparing and finalizing rows do
not count as transfers. Foreground, a background-session wake, or a gap of six seconds in an
attempt's callbacks discards the old batch window. Each attempt's first callback establishes a
new watermark, with four seconds of baseline replacement to exclude buffered catch-up bytes
(#224), before the shared window can produce a total. Staggered callbacks are interpolated
inside their observed overlap, never extrapolated or silently omitted. Observed quiet intervals
contribute zero; a silent attempt makes the total unavailable once the common window expires.
All measurement state is memory-only.

For the shared pre-overhaul transport crawl reported in #409, static closed ranges have a
bounded foreground experiment. After authoritative reconciliation and ten seconds of settling,
one 60-second continuously active counter window can select a known `background_wake` task
below 128 KiB/s with more than ten minutes remaining at that rate. Zero progress uses the same
window. A task with at most 256 MiB of nondurable body may be plain-cancelled and reissued on the
same session; a fresh counter must still meet the cap immediately before cancellation. Exactly
256 MiB is allowed. One exact attempt gets at most one recovery per process, with one operation
in flight globally. The 30-second result observations overlap subsequent rows' recoveries, so
both rows in the two-row/two-task crawl can reissue around seconds 70–80 after reconciliation.
Unknown relaunch provenance is observed and diagnosed without reissue. Eligibility starts at the
baseline boundary: connectivity restored during settling does not invalidate the subsequent
window; an interruption inside measurement produces a deferred result.

The selected task alone loses its nondurable body. The attempt, durable checkpoint, held tail,
healthy sibling, resource validator, train epoch and 512 MiB/depth-two sizing survive. Checkpoint
failure leaves the original task running. Inactivity or P6 winding-down at the real persistence-to-
resume edge parks the replacement with an exact-attempt refill intent. Renewed foreground
reconciliation runs the gap planner even beside a live sibling, without spending another recovery.
Temporary refill or resume failures also retry within the same activation, at one-second intervals
for at most three retries, then hand off to ordinary request recovery. These retries preserve the
sibling and spend no additional health-recovery budget. Finished bodies remain planner coverage
throughout the delegate-to-assembly handoff, including before they become held; an invalidated
train's pending bodies retain cleanup ownership but cannot cover replacement requests. Expired
physical workers retain their leases and defer recovery. No health state or revocation history is
persisted, so a kill loses provenance and the experimental budget; normal reattachment may adopt
the old task.

Diagnostics extend `downloads.range_start` with creation context, session kind and registration
phase, and distinguish actual `downloads.range_resume`. One `downloads.range_health_reissue`
candidate event is paired with `downloads.range_health_result` after about 30 active seconds
or at the actual pause, cancel, error, completion or inactive edge. Results use that stop's elapsed
interval and outcome, and repeat provenance, exact pre/post counters and rates,
old/new task IDs and discarded bytes. `downloads.range_health_foreground` records aggregate
activity edges. Terminal-attempt budgets and obsolete connectivity entries are retired; pauses
retain the one-shot budget. There are no periodic healthy verdicts. Persistent OS scheduling
treatment is a hypothesis; paired device evidence and hardware acceptance remain pending.

Downloading while the app is backgrounded, suspended, or the device is locked/asleep is
fundamentally constrained by the platform, not by the server or the app:

- **Only system-owned transfers keep running.** True background `URLSessionDownloadTask`s owned
  by the system daemon (`nsurlsessiond`) may continue; app-side work (server-prep polling,
  keepalives, timers) is frozen while the app is suspended.
- **Background transfers are deprioritized.** The OS gives interactive networking and power
  management priority over background bulk transfers, so throughput can be substantially slower
  than the same download with the app active.
- **Background app wake-ups are rate-limited.** Each time the system relaunches the app for a
  background-session event, it may delay the next opportunity to do app work. Any design that
  needs an app wake-up per bounded transfer therefore stalls after a handful of handoffs
  regardless of transfer size.
- **Background scheduling remains system-controlled.** Labstream asks for non-discretionary
  transfers, but the OS still decides when background work runs and how much network/power budget
  it receives.

Labstream's static byte-range lane is shaped around these limits and follows the simplest
Apple-standard architecture we can make stable:

```mermaid
sequenceDiagram
  accTitle: Static segment-train data flow
  accDescr: The background transfer owner reads one exact-attempt durable checkpoint, asks a pure policy for up to two closed ranges, and enqueues marked URLSession tasks. Completed bodies are stashed by offset, the maximal contiguous run is appended, the checkpoint is persisted, and the queue is refilled.
  participant BGS as BackgroundDownloadSession
  participant Store as DownloadStore
  participant Policy as Segment policies
  participant URL as URLSession

  BGS->>Store: read exact attempt, durable offset, and total size
  BGS->>Policy: plan missing closed ranges
  Policy-->>BGS: at most two marked segment plans
  BGS->>URL: enqueue background download tasks
  loop each delivered completion
    URL-->>BGS: completed body and segment offset
    BGS->>Policy: classify stashed bodies at durable offset
    Policy-->>BGS: append run, hold later bodies, discard invalid bodies
    BGS->>Store: append contiguous run and persist checkpoint
    BGS->>Policy: refill from new durable offset
  end
```

- **A pre-queued train of closed-range segment tasks for known-size static files.** The
  same segment-train engine runs on visionOS, iOS/iPadOS, and macOS; Mac background recovery
  remains a platform-specific release-acceptance gate.
  Static Plex/Jellyfin/Emby file routes enqueue up to `maxQueuedSegments` (currently 2) background
  `URLSessionDownloadTask`s ahead of the durable checkpoint, each a closed
  `Range: bytes=<offset>-<offset+segmentBytes-1>` request of `segmentBytes` (512 MiB) —
  roughly 1 GiB of queued runway per file. The two-task cap is intentional: one head plus
  one look-ahead preserves overlap without multiplying several visible downloads into
  dozens of concurrent transfers. `StaticRangeSegmentQueuePolicy` is the pure
  planner: given the durable offset, the expected total size, and the segment offsets
  already live in the session, it emits the closed ranges still needed, up to the queue
  depth. When the expected total size is unknown, the planner falls back to a single
  open-ended `Range: bytes=<durableOffset>-` plan — the same shape used before segmentation,
  so that fallback is a zero-regression path rather than a special case.
  `StaticRangeTransferConfiguration` owns only the segment size and queue-depth constants;
  transfer shape remains planner-owned so the unknown-total open-ended fallback follows the
  same attempt and durable-checkpoint rules as the closed train.
- **Segments are attempt-marked and stashed, then assembled in order.** Each new segment
  task's `taskDescription` combines the rating key and current
  `lbs-segment:v3:<offset>:<attemptID>` marker with a U+001F separator. Relaunch/reattach
  therefore requires both the row and exact attempt, not merely a reused rating key.
  Old V1/V2 segment markers, V1 opaque markers, bare descriptions, and URL-derived identity are
  no longer parsed or adopted. `StaticRangeReattachPolicy` accepts only a current,
  offset-matching task for the row's exact attempt; every unmarked, malformed, stale-attempt, or
  mismatched task is cancelled.
  When a segment task
  finishes, its body is stashed by offset; `StaticRangeSegmentAssemblyPolicy` — a pure
  assembler — decides, given the durable offset and the set of stashed finished bodies,
  which stashes form the maximal contiguous run starting exactly at the durable offset
  (appended now), which are held (a later segment finished out of order, waiting on a gap),
  and which are discarded (fully behind the checkpoint, or overlapping but not
  offset-aligned — the same non-negotiable append-alignment invariant as the pre-segment
  design). Appending a run advances the durable checkpoint and refills the train back up
  to the queue depth.
- **URLSession resume data remains first-class only for the single open-ended fallback.**
  The store has one resume-blob slot per download row. When an unknown-size static source uses
  `Range: bytes=<durableOffset>-`, pausing can preserve that task's OS temp progress and display
  watermark in a blob. Adoption requires the blob's original open-ended Range offset to equal the
  current durable partial.
- **Closed train segments never persist or adopt URLSession resume data, including the head.**
  CFNetwork can replay a resumed closed request past its original end, so pausing a segment train
  clears any old blob/watermark and plain-cancels unfinished segments. The app-owned durable partial
  remains authoritative. Completed held bodies are durably manifested and may be rehydrated across
  relaunch only when their exact attempt, length, and validator checks still match; mismatches fail
  closed and re-fetch. Unfinished ranges are planned again on Resume.
- **The durable partial is the fallback.** A rejected old-format closed-range blob, or an open-ended blob that is
  missing, malformed, stale, exhausted, or backed by a deleted temp file, is rejected and cleared
  together with its display watermark. Recovery then re-plans from the durable partial's current
  file size rather than appending unvalidated bytes.
- **Free-space admission follows the physical append timeline.** Start, continuation, blob Resume,
  and automatic storage-full parking charge the remaining network bytes, the largest upcoming
  append copy, uncached side-asset estimate, and headroom. Durable checkpoints and held bodies
  already on disk are counted once.
  A blob refused for space keeps its resume authority and display watermark; it reports storage
  exhaustion without treating the blob as corrupt or restarting the transfer.
- **Transient Range retries are bounded by durable progress.** Optimistic URLSession progress does
  not reset the retry budget. Positive appends, including held-body drains, reset it; explicit user
  start/Resume resets it too. Transport drops get four retries with delays of 1, 2, 4, and 8 seconds. Delayed retries hold the background completion
  gate through successor registration and check attempt, train epoch, and restart generation.
  Pause/Resume invalidates old timers while preserving already finished bodies.
- **Stash sweeps respect in-process ownership.** Both temporary and durable held bodies are claimed
  before their rename and remain protected through queued append or manifest publication until
  consumption/discard. The final claim check and orphan deletion share one lock boundary.
- **HTTP safety checks still guard the append.** Completed bodies are validated for
  `Content-Range` start alignment, pinned validator mismatches, HTTP `200` full-body
  replacement/restart behavior, `416` total validation, temp disappearance fallback, and safe
  resume-blob adoption/clearing. A strangely resumed transfer is rejected, restarted, or
  falls back to the durable partial rather than appending unvalidated bytes.
- **Why segments, not one task:** a visionOS wake bounce can silently restart the body of an
  in-flight custom-`Range` request with no error and no resume-data callback (see the
  [verified platform finding](DEVELOPMENT.md#verified-platform-findings)). With one open-ended task, that restart forfeits
  every un-appended byte transferred off-head, unbounded overnight. With a segment train,
  nsurlsessiond executes pre-queued segments with the process dead — no per-continuation app
  wake is required — and a wake-time bounce can only restart the one segment that was mid-flight
  (at most `segmentBytes`). Markers allow surviving tasks and delivered completions to be
  mapped back to their row and offset after reattach, but do not assume the OS will always
  redeliver a completion that occurred while the process was dead. Only bodies actually
  recovered through the background-session lifecycle are adopted; otherwise the durable
  partial remains authoritative and the missing range is re-planned and re-fetched.

Simulator caveat: Labstream intentionally uses a foreground/default `URLSession`
in simulator builds because the background transfer daemon is unreliable there.
Simulator passes can validate routing, progress UI, and retry policy, but not
real background continuation, lock/off-head scheduling, or cellular policy.

User-facing expectations worth setting (the "downloads disclaimer"):

- Very large background downloads are best-effort. Keeping the device on power helps; briefly
  foregrounding the app gives Labstream a chance to process delivered completions or recover
  app-owned work, without guaranteeing any change to the OS scheduler.
- Plex optimize and Emby Convert are server-side preparation jobs. Their app-side polling and
  handoff cannot run while the app is suspended; Emby Convert job identity is persisted so polling
  can resume after relaunch. Once either route hands off to a static file, the byte transfer can use
  the static recovery path.
- Fresh and resumed Plex optimize jobs inspect metadata before creating work. They reuse an
  existing render only when it is a server-optimized part (under
  Plex's "Plex Versions" path) that matches the requested tier: resolution as a bounding box
  within ±16 px and container bitrate within ×1.10 of the video cap plus 768 kbps, and
  original-quality requests must land at the source height. `OptimizedVersionMatch` owns this
  rule, so a 1080p/8 Mbps retry never silently reuses an older 720p render.
- Plex queue inspection distinguishes a present item, proven absence, and unavailable inspection.
  Only proven absence plus a successful metadata inspection can create a job. Immediately before
  dispatch, the row durably records a 3-minute visibility grace. Relaunch preserves that timestamp:
  absence during the grace keeps inspecting without another create; proven absence after it fails
  server preparation if no matching version is visible. An HTTP 400 duplicate rechecks adoption;
  other create errors fail promptly. The separate 120-second completion/indexing grace, 24-hour
  prep deadline and authentication failure budget remain in force. Static handoff uses the live
  server lane on which the rendered Part was observed.
- Fresh Plex and Emby preparation starts return after registering their poller tasks. Delete
  cancels those tasks. Emby reuse and completed conversions share one handoff that detaches its
  own poller before releasing prep bookkeeping, then starts the existing-version static lane.
  Pause All parks Emby Convert through the same cancellation path as a row Pause.
- Jellyfin optimized/compatible-remux downloads, and Emby compatible-remux
  downloads, can be live-forward encoder streams. They may continue as
  system-owned transfers while the OS allows it, but they are not durable
  byte-range checkpoints and can require retry/restart after interruption.
- Cellular downloads are off by default where cellular data is available.
  Settings ▸ Downloads ▸ **Use cellular data for downloads** also governs
  constrained networks (Low Data Mode) and expensive networks such as a personal
  hotspot: while it is off, downloads wait for an unconstrained, inexpensive
  network. It applies to newly created request-based transfer tasks and side-asset
  fetches; active tasks and tasks resumed from OS resume data keep the policy
  they were created with.

## Module ownership

| Component | Owns |
| --- | --- |
| `DownloadManager` | Main-actor queue coordination and user-visible state. |
| `DownloadKeepaliveCoordinator` | Exact-attempt Jellyfin/Emby keepalive task ownership and credential-generation quarantine. A keepalive runs only while the session tracks a live transfer for that attempt. Emby sends Ping only; Jellyfin currently sends Playing/Progress at a fixed position of 0 instead of the transfer's byte fraction. This is an interim containment: it stops downloads from reporting advancing positions, but it is not proven to leave watch state untouched. The live Ping-only A/B decides the final shape, and the watch-state check stays open until it does. |
| Backend-specific manager extensions | Plex/Jellyfin/Emby route setup and server-prep polling. |
| `BackgroundDownloadSession` | URLSession tasks, segment-train enqueue/refill, transfer callbacks, finalization, and wake-release effects. |
| `BackgroundDownloadWakeCoordinator` and wake budget contract | Exact-token completion gate, receipt-based absolute deadline, identified operations, deferred revalidation and rebuild grace generations. |
| `DownloadManager+SeasonPlanner` and `SeasonDownloadPlannerSheet` | Immutable season drafts, one atomic Store commit of planned rows plus retry intents, and the refreshed, source-validated first start. |
| `DownloadAdmissionCoordinator` and `DownloadManager+Admission` | The one admission window: observed lane occupancy, supervised starts, durable waiting requests, backoff and the Pause All row exemption. |
| `DownloadOptionsModel` | Typed per-item option resolution for the download sheet; it does not own season planning. |
| `DownloadVolumeFreeSpace` | Purgeable-inclusive free-space measurement used by storage-full parking. |
| `DownloadStore`, async contract and path leases | Schema-v5 index state, exact-attempt work/mutation admission, bounded submit/resolve, off-lock filesystem observations and physical path exclusion. |
| `DownloadArtifactLifecycleCoordinator` and file-effect seams | Order attempt-scoped resume/checkpoint/promotion/deletion work with its terminal persistence outcome. |
| `DownloadWorkRegistry` | Attempt-scoped side-cache and encoder-task ownership. |
| `DownloadCleanupIntentJournal` | Independent durable, credential-free server-cleanup authority for all three backends: Jellyfin/Emby encoders, Emby Convert jobs and Plex optimize queue items. |
| `DownloadCleanupIntentRunner` | The only executor of journaled cleanup: eligibility, ownership recheck, bounded concurrency and per-intent backoff with its own wake-up. |
| `EmbyConvertCleanupJournal` | Legacy Emby Convert tombstones, read only to migrate them into the cleanup journal at launch. |
| PMSKit download policies | Pure route, retry, row-display, and recovery decisions, including the segment-train planner and assembler. |

## Server cleanup

Every server resource a download stops needing is recorded in the cleanup journal before
anything cancels it. That covers a Jellyfin/Emby encoder (`activeEncoding`), an Emby Convert
job (`knownJob`, or `ambiguousCreate` when the create response was lost) and a Plex optimize
queue item (`plexOptimize`). The journal lives in an authority directory outside the versioned
media root. Each write uses the index's commit protocol: temp file, full fsync, rename and
directory sync. A write whose final sync fails is reported as a failure, never proven by
re-reading the file. The directory and every file are excluded from backup and data-protected.

Each intent records why it exists:

| Provenance | Written by | Runs when |
| --- | --- | --- |
| Row deletion | Delete, before the row is removed | the row's removal has committed |
| Terminal release | Launch/backend-switch sweep for a terminal row's handles | the row is terminal and not protecting the job for Retry, or the row is gone |
| Abandonment | Superseded negotiations, stale creates, duplicate jobs, the 24-hour Convert expiry, abandoned Plex seeds, stale optimize-job sweeps | whenever the ownership recheck passes |

The runner executes nothing while a row's deletion is staged, in flight, or failed. Just before
each server call it re-checks ownership: another row's PlaySessionId, Convert job, queue title,
or a job that row's crash-window recovery would adopt keeps the resource. Convert cleanup and
Convert crash-window recovery are serialized per server. Claims are scoped to persisted server
and MediaBrowser user, never the currently visible browse lane. After each awaited inspection,
claims and eligibility are reread immediately before cancellation. An originating Convert/Plex
attempt still claims a resource while its persisted reference remains; a failed abandonment write
cannot take its job. For a nonresumable encoder, the origin claims only while its transfer is active,
allowing interrupted release to replay safely.

The runner coalesces producer/recovery/session triggers, executes at most two intents at once and
schedules its own earliest retry. Per-intent backoff ranges from 30 seconds to 30 minutes, with
a two-minute local eligibility recheck for waiting work. Legacy import/quarantine barriers run
before every pass; unreadable authority is never an empty queue.

Plex queue responses are classified explicitly:

- a completed render is kept (deleting the queue item would delete the version);
- a malformed list, a duplicate title or an unknown state keeps the intent;
- an absent item retires the intent only once the create PUT is known to have landed.

An unresolved create is retried, slowly after a day, and retired with a diagnostic after a week.
One race is accepted: a render that completes between the queue read and the DELETE is
deleted, because PMS has no conditional cancel. The delete confirmation therefore says
in-progress preparation is cancelled "where possible".

Abandonment producers submit journal I/O to a worker and await a bounded durability result.
A stale Plex title sweep commits its discoveries in one transaction. A failed or expired
observation does not authorize a superseded-encoder stop or an Emby stale-create cancel;
late durable intents remain replayable by the cleanup runner. Producers recheck captured
server identity and exact row authority after suspension before dependent handoffs.
Sign-out pauses rows rather than deleting them. Active encoders still need a journaled release
captured before credential revocation; see [Local playback and row presentation](#local-playback-and-row-presentation).

## Offline metadata

Offline records keep enough information to display and play the item without a live server:

- backend and item identity;
- title/metadata needed for the offline library;
- local file URL and byte counts;
- selected media characteristics;
- optional poster and side-asset references;
- resume/progress state where applicable.

Paths in the JSON index are one-level paths relative to the Downloads directory and are
re-hydrated against the current sandbox at load time. Absolute container paths are not
stable across installs. URLSession resume data is stored as a protected, backup-excluded
sibling artifact and referenced by relative path; it is only valid for static/range-resumable
sources. The storage and backup boundary is detailed in [Persistence](PERSISTENCE.md#app-container).

Side assets such as posters, chapters, and compatible external text subtitles are cached next to the download record when available. They are treated as convenience metadata; the main playable file remains the durable core of the download.

Posters are offered as soon as an owned row is queued, including season plans and restored
active rows when their matching backend session becomes available. This poster-only pass runs
independently of media admission and server preparation; BIF, trickplay, chapters and subtitles
keep their normal later scheduling. It uses the existing paced, authenticated side-asset transport
and respects Pause All and network preferences. Each attempt/source gets one early offer per
launch; a failed fetch is non-fatal and remains eligible for normal later side-asset hydration.
Validation, attempt/source-fenced staging and promotion, `sideAssetBundleOwner`, and
`posterGeneration` are unchanged. Cached poster bytes count as side-asset storage, survive
relaunch, and feed the shared Offline row artwork on visionOS, iOS/iPadOS and macOS. Rows
without artwork retain the placeholder glyph; tvOS has no Downloads capability.

## Local playback and row presentation

Detail's Play Offline and the Offline library admit the exact rendered attempt after orientation.
One manager-owned factory rechecks ownership, deletion, terminal state and the local file, then
captures local resume/rewind, metadata-owned backend/assets and an attempt/session-bound event
sink. The shared player consumes that sink: actual playing can verify eligible unverified rows,
while repeated-truncation warnings remain. Position updates coalesce behind bounded asynchronous
P6 persistence, including a terminal close sample; no synchronous close flush or rating-key save
adapter remains. Positions are local only: watched/progress sync-back and offline Up Next remain
separate work.

Sign-out parks rows immediately and captures exact encoder-cleanup authority before credentials
are revoked. Encoder-release journal work uses a P6 worker submission and bounded asynchronous
resolution. Only a durable journal result permits compare-clearing that exact play-session handle;
failure or expiry retains its row/transient authority, and an old completion cannot erase a newer
handle. Recovery must replay retained exact releases after journal failure or timeout.

Offline offers embedded subtitles and downloaded text sidecars together with one Off choice.
Opening the menu does not parse sidecars. Selecting embedded, sidecar or Off revokes the other
selection; item/session/selection generations reject late parses. Emby converted downloads retain
an independent original text-subtitle source. Historically ambiguous origins skip repair safely
and keep existing cached subtitles and playable media.

Library and current-download sheets share lifecycle-driven rows. Waiting/paused and route/context
are neutral, verified completion green, caution amber, and failures/destructive controls red.
All text lines share a leading edge without status icons; poster badges remain. Finished rows show
one tail-truncated summary: `Downloaded • 1080p • 5.7 Mbps avg • 1.6 GB + 12 MB extras` or
`Not verified • 1080p • 6.1 Mbps avg • 1.8 GB`. Resolution, local media average bitrate and size
are omitted when unknown; extras appear only when present. Finished rows have no separate quality
line. Other states retain requested quality, progress and captions. Context and status stay
single-line with full accessibility values; VoiceOver adds “Downloaded and verified” or
“Downloaded; playback not verified” to the full summary. Error details expand.
Server indexing, preparation and verification remain distinct, and preterminal progress never
claims 100%. Delete captures exact attempt identities and explains supported unfinished server-job
cancellation while retaining finished server versions.

Availability is a generation-tagged off-MainActor scan, refreshed at publication, foreground and
recovery boundaries. Body/progress reads do not stat files. Readable blocked recovery permits
terminal playback with mutations disabled; opaque unsupported/unreadable indices cannot open
Offline. Restricted Offline consumes Cinema returns and acknowledges their identity before
Reconnect, preventing normal Root from replaying an old return.

## Reconcile and resume

On launch, Labstream compares the offline index, files on disk, active transfers, persisted
artifact reservations, and durable cleanup intents. Current reconciliation:

Startup first installs all transfer callbacks and registers the still-dormant session with the
background-completion registry. When the Store admits a healthy current index, the initial
transport submission crosses one bounded MainActor turn and retains the manager until that
submission occurs. A retry before that turn cancels the deferred edge and owns the one immediate
submission, so retry cannot overtake it or submit activation twice.

A readable load that finishes after the startup deadline still publishes rows and Offline
availability, even if its background wake has expired. Transport, probes and queue refill stay
dormant until foreground or a new background wake authorizes recovery; older load generations
cannot overwrite a newer recovery attempt.

- **Unsupported schemas** keep their explicit reset path.
- **Unreadable indexes and malformed current ownership** remain fail-closed.
- **A v4 index** runs the one-time upgrade pass (see PERSISTENCE) before `.ready` is published.

**Delete** stops exactly its attempt: tracked tasks, any OS task carrying that attempt's marker,
prep pollers and keepalive. It never stops a replacement attempt.

A row being deleted, whether behind a row-deletion barrier or as a capsule, admits no new work:
- transfer start, resume and finalization;
- retry continuation;
- season admission;
- Plex optimize polling and creation.

Recovery also:

- adopts only current task markers whose exact attempt matches the durable row;
- keeps current malformed/ownerless active rows fail-closed rather than guessing ownership;
- resumes/retries recoverable transfers and surfaces terminal failures in the row. A row whose
  last failure was storage-full is not automatically redriven: every automatic static-range
  redrive (rebuilds, backend-ready drains, launch recovery) first re-measures free space —
  counting iOS purgeable space, matching the Settings storage gauge — and, if the volume still
  cannot hold the remaining network bytes, largest append copy, uncached side assets and headroom,
  parks the row as a pending resume instead of retrying. A user-initiated Retry can reattempt immediately, but still passes admission and storage preflights;
- migrates legacy Emby tombstones and pre-upgrade quarantined Plex intents into the cleanup
  journal, then runs required server cleanup through the cleanup runner (see
  [Server cleanup](#server-cleanup));
- inventories and repairs missing posters, subtitles, chapters, Plex/Emby BIF, and Jellyfin
  trick-play playlists/tiles for completed rows without re-downloading playable media. Work runs
  off-main, validates image/BIF/text payloads before promotion, and batches metadata publication.
  Retry authority is exact attempt + source + resource kind and is charged only when an eligible
  waiter actually admits transport; coalesced cancellation or a stale waiter hands authority to the
  next eligible waiter. The worker inventories every owned side asset even after finding a missing file, so playlist
  repair retains later existing tiles when their server requests would fail. Successful promotion,
  including a same-path replacement, advances the side-asset generation so byte accounting and
  storage-cap snapshots cannot retain stale cache values;
- keeps completed media available without requiring the source server to be reachable;
- keeps a failed Emby Convert row's server job when Retry would resume it: the launch and
  backend-switch cleanup sweep cancels Convert jobs only for completed, deleted or abandoned rows,
  using the same predicate as the retry gate. Forward-only encoders of failed rows are still
  stopped, because they cannot resume;
- parks a static row at its durable checkpoint when the system (not the user) cancels its
  background task, and fails a forward-only row as retryable in the same case;
- fails a Jellyfin download or retry with "version no longer available" when the requested
  MediaSource has disappeared, instead of silently fetching another edition;
- treats sign-out of a backend as a resumable pause of that backend's active rows. Records
  and files stay; `DownloadManager.pauseDownloadsForBackendSignOut` runs while credentials
  still exist so encoder teardown can use the right session. This is not cancel or delete.

If the selected saved session cannot be restored because its server or network is temporarily
unreachable, launch finishes in a restricted Offline surface when at least one completed media
file is still present. This surface exposes only the local library/player plus reconnect,
sign-in, Settings, resume-position, and deletion controls; it does not fabricate an authenticated
browse session. Missing or explicitly invalid credentials continue to show sign-in instead, and
tvOS never enters this path because it does not ship downloads.

Admission is decided from a typed selected-session restore outcome that Plex, Jellyfin, and Emby
all report through `AuthManager.sessionRestoreOutcome` (PMSKit `SessionRestoreOutcome`):

| Outcome | Produced by | Saved credential | Launch surface |
| --- | --- | --- | --- |
| `restored` | live lane published | kept | browse |
| `missingCredential` | no saved credential, or explicit sign-out | absent | sign-in |
| `invalidCredential` | HTTP 401 (Emby: probe reports another user); a Plex 401 on inactive download hydration also classifies here but keeps the token | retired | sign-in |
| `unconfirmedCredential` | HTTP 403, or Jellyfin 2xx probe for a different user | kept | sign-in/retry |
| `temporarilyUnavailable` | transport, DNS, TLS, timeout, Plex discovery, HTTP 429/5xx or any other non-401/403 status (a reverse proxy can answer 404 while its upstream is down), or an unreadable reply such as a captive portal | kept | Offline if a completed local file exists, otherwise sign-in/retry |

`OfflineLaunchAvailability.admitsOfflineLaunch` is the pure gate. Reconnect re-runs the selected
restore in place; a successful restore flips `isBrowseReady` and `BrowseUIGate` mounts the normal
root.

Season confirmation captures one immutable draft containing new rows and exact retry attempts. The
Store validates every owner and commits insertions plus retry admission intents in one
snapshot before any lane starts; stale ownership, a normal persistence failure, and an indeterminate
atomic-write outcome remain distinct, with the last case pausing download admission. Offline list
snapshots contain scalar presentation/action identity only; full records resolve at exact-attempt
action or playback edges. Storage presentation separates known, unknown, and not-applicable bytes
instead of turning unknown side assets or reservations into false zeroes.

Every download start goes through one admission window (`DownloadAdmissionPolicy`, driven by
`DownloadAdmissionCoordinator`): single taps, season rows, Resume All, a row's Resume or Retry,
automatic static range resumes and stalled-stream restarts. Settings ▸ Downloads ▸
**Simultaneous downloads** sets the total cap from 1 to 5 (default 3). The static-file lane is
`max(1, total - 1)`; server preparation (Plex optimize or Emby Convert) and live-forward streams
each remain capped at 1. The pure policy takes limits supplied by the manager-owned coordinator,
which reads the persisted preference at every gate, including relaunch recovery. Explicit row
actions are served before automatic ones; the origin orders requests and never lifts a cap.

Lowering the setting never cancels running transfers: existing work is grandfathered, and no
new row enters until total and lane occupancy are below their limits. Raising it wakes an
admission pass so waiting rows start as soon as the applicable lanes have room. The setting is
available on visionOS, iOS/iPadOS and macOS; tvOS has no Downloads settings.

- **Occupancy is observed.** A row uses its lane while its persisted lifecycle is `admitted`,
  `serverPrep` or `transferring`, it is not being deleted, and live work backs it (a start slot,
  a registered prep poller or a session-owned transfer). Pause, failure, finalizing and delete
  free the lane without any release call. A Plex row that hands its render off to the static
  transfer moves from the server-prep lane to the static lane; static occupancy can then exceed
  its configured cap, and nothing new enters the static lane meanwhile.
- **Starts are supervised.** A granted start is fenced by a generation until its async work
  finishes. A start that ends without work (no session, a refresh outage) waits again with
  backoff of 1, 5, 15, 30 and then 60 seconds instead of failing; a definitive refusal (signed
  out, source gone, storage) stays a visible failure. Pause and delete end the supervision, so a
  granted continuation never starts a paused or deleted row.
- **Waiting is durable.** A season episode, or a tap that finds every lane full, waits as a
  `planned` row carrying its exact source binding, route, preset and audio choice, and starts
  through the refreshed, source-validated first-start path. Resume All and a capacity-delayed row
  Resume or Retry keep the row paused or failed with a `retryRequested` intent, so its retry
  routes from its own facts (checkpoint, resume blob, Emby job, Plex queue item). Waiting rows read
  **Waiting for a download slot…**, or **Waiting — downloads paused** during Pause All.
- **Bulk controls** show **Pause All** whenever any row is active, preparing, retrying or
  waiting for admission, including paused/failed rows with a pending retry request. Mixed idle,
  completed or failed rows never hide Pause All. With no running or requested work, paused/failed
  rows or a paused queue offer **Resume All**. The label and icon follow each published snapshot;
  the control is disabled until startup recovery is ready.
- **Pause All** closes the admission gate, withdraws waiting retry requests and pauses active
  rows, including Emby Convert preparation via the same cancellation path as a row Pause.
  This cancels local preparation pollers; remote conversion jobs retain their existing resumable
  ownership, with supported remote-job cleanup belonging to Delete.
  Finished bodies already being verified are allowed to finish. A row's own Resume or Retry
  during Pause All is exempt for that row only; its pending or active work offers Pause All
  again, and the next Pause All revokes every exemption.
- **Barriers.** Nothing is granted before startup recovery has reattached tasks and pollers (work
  the OS still owned counts first, even over a cap), or while a season commit is proving
  durability.
- **Lane changes.** A start that turns into server-prep work (a Plex original that failed its
  preflight, an Emby negotiation rerouted to Convert) needs room in that lane first; otherwise it
  ends without work and waits.

Emby itself processes Convert jobs from its *Convert Media* scheduled task, which Emby staff have
described as one conversion at a time. A second Labstream Convert can therefore wait as
server-side `Queued` even outside Labstream's own lane cap. Static downloads need no conversion
and are not tied to that server queue.

Storage uses one rule for every gate (`DownloadStorageAdmissionPolicy`, P5):

- **Storage limit.** Every row counts once: the bytes it holds plus its cached side assets.
  Admitted, preparing and transferring rows also reserve their known remaining bytes. A retry or
  re-download replaces its own row's contribution instead of adding to it. The same rule checks
  the download sheet, every backend start, the season commit (including retried episodes) and the
  Plex fallback before it asks the server to render.
- **Unknown sizes stay unknown.** Known side assets never turn an unknown media size into an
  "extras-only" number. The download sheet says the size is unknown and that the download is not
  counted toward the limit; the season sheet asks for confirmation. Jellyfin and Emby items now
  carry their source size, so originals are rarely unknown.
- **Cap limitation.** Starts that pass checks concurrently before publishing their sizes are not
  protected by a new atomic reservation transaction. Admission caps bound concurrency, but the
  limit can temporarily overshoot; later checks and reactive ENOSPC remain backstops.
- **Free space** follows the file's physical timeline. The transfer still needs the network bytes
  not yet on disk, plus the largest body it will append (that copy briefly exists twice), plus
  the duration/chapter-based side-asset estimate less bytes already cached (floored at zero),
  plus 500 MB of headroom. Only usable, nonoverlapping held bodies beyond the checkpoint reduce
  future network bytes; consumed bodies receive no further credit. The measurement counts
  purgeable space, as the Settings gauge
  does, and an ENOSPC during a transfer still fails the row with the storage-full affordance.

A planned row with no in-flight slot is waiting, not transferring. All current-download surfaces
use the shared waiting caption; an admitted row may show **Queued…** and a server-prep row
**Preparing on server…**.
**Downloading optimized** is the static transfer of an existing or converted version. When it reads
0% with a spinner, the row is active but URLSession has delivered no body bytes yet. Common reasons
are the window before the first byte, OS scheduling, and the per-host connection limit, since each
static row can queue two segment tasks.
