# Downloads and offline playback

Labstream downloads are designed to end in a local file the current device can play, plus enough metadata to show the item in the offline library and resume safely.

```mermaid
flowchart TD
  Request[User taps download] --> Inspect[Inspect backend media options]
  Inspect --> Route{Best route?}
  Route --> Original[Direct original file]
  Route --> Existing[Existing server version]
  Route --> Rendered[Server-rendered compatible copy]
  Original --> Transfer[Transfer and verify]
  Existing --> Transfer
  Rendered --> Transfer
  Transfer --> Store[Offline index + side assets]
  Store --> Offline[Offline library]
  Offline --> Player[Local playback]
```

## Core rules

- A completed download must have a local playable file and a durable offline record.
- Direct original downloads are offered only when Labstream expects the file to play locally.
- Server-rendered or server-prepared routes are used when the original is not a safe local target.
- Transfers must reconcile cleanly on relaunch. Static/original and server-prepared
  static routes should resume from durable checkpoints when possible; live-forward
  remux/transcode streams may become retryable and restart from the beginning
  rather than claiming unsafe byte-offset resume.
- Offline records must never contain access tokens. They do persist the minimum backend
  context needed to resume and clean up a job, which currently includes the owning backend,
  server base URL/server ID, MediaBrowser user ID where applicable, media/play-session IDs,
  and route/checkpoint state. Treat `index.json` as private app data, not a shareable profile.

## Backend routes

| Backend | Download choices |
| --- | --- |
| Plex | Compatible original, explicit existing version, and completed optimizer output all hand off to a static file transfer. |
| Jellyfin | Original is static/range-resumable. Compatible remux and capped transcode are live forward-only streams. |
| Emby | Original, reusable existing version, and completed Convert output are static. Compatible remux is live forward-only; a requested transcode is normally rerouted through persistent Convert-then-static. |

## Transfer lifecycle

```mermaid
stateDiagram-v2
  [*] --> Queued
  Queued --> Preparing: server prep needed
  Queued --> Transferring: static route
  Preparing --> Transferring: prepared source ready
  Transferring --> Paused
  Paused --> Transferring
  Transferring --> Verifying
  Verifying --> Complete
  Verifying --> Failed
  Failed --> Queued: retry
  Complete --> [*]
```

## Background downloads and sleeping devices

Downloading while the app is backgrounded, suspended, or the device is locked/asleep is
fundamentally constrained by the platform, not by the server or the app:

- **Only system-owned transfers keep running.** True background `URLSessionDownloadTask`s owned
  by the system daemon (`nsurlsessiond`) may continue; app-side work (server-prep polling,
  keepalives, timers) is frozen while the app is suspended.
- **Background transfers are deprioritized.** The OS gives interactive networking and power
  management priority over background bulk transfers, so throughput can be several times slower
  than the same download with the app active.
- **Background app wake-ups are rate-limited.** Each time the system relaunches the app for a
  background-session event, it may delay the next opportunity to do app work. Any design that
  needs an app wake-up per bounded transfer therefore stalls after a handful of handoffs
  regardless of transfer size.
- **Transfers started while backgrounded are treated as discretionary** — the system schedules
  them at its own pace regardless of configuration.

Labstream's static byte-range lane is shaped around these limits and follows the simplest
Apple-standard architecture we can make stable:

- **A pre-queued train of closed-range segment tasks for known-size static files.** The
  current compile-time regime is `.segmentTrain` on visionOS, iOS/iPadOS, and macOS.
  Static Plex/Jellyfin/Emby file routes enqueue up to `maxQueuedSegments` (8) background
  `URLSessionDownloadTask`s ahead of the durable checkpoint, each a closed
  `Range: bytes=<offset>-<offset+segmentBytes-1>` request of `segmentBytes` (512 MiB) —
  roughly 4 GiB of unattended runway per file. `StaticRangeSegmentQueuePolicy` is the pure
  planner: given the durable offset, the expected total size, and the segment offsets
  already live in the session, it emits the closed ranges still needed, up to the queue
  depth. When the expected total size is unknown, the planner falls back to a single
  open-ended `Range: bytes=<durableOffset>-` plan — the same shape used before segmentation,
  so that fallback is a zero-regression path rather than a special case.
  `StaticRangeTransferRegime` (`Labstream/Downloads/StaticRangeTransferRegime.swift`) is a
  compile-time switch between `.segmentTrain` (current, all platforms) and
  `.openEndedRemainder` (the prior single-task shipping behavior); flipping a platform back
  is a one-line change, and both regimes recover from the same durable-partial checkpoint,
  so switching regimes across launches is safe.
- **Segments are marked and stashed, then assembled in order.** Each segment task's
  `taskDescription` carries `lbs-segment:v1:<offset>` combined with the download's
  ratingKey via a U+001F separator, so a relaunch or reattach can identify which live
  tasks belong to which download and at what offset without any other bookkeeping.
  `StaticRangeReattachPolicy` adopts closed-range tasks bearing a valid, offset-matching
  marker; a closed-range task with no marker (or a stale/mismatched one) is still dropped
  as legacy, the same #231 safety behavior as before segmentation. When a segment task
  finishes, its body is stashed by offset; `StaticRangeSegmentAssemblyPolicy` — a pure
  assembler — decides, given the durable offset and the set of stashed finished bodies,
  which stashes form the maximal contiguous run starting exactly at the durable offset
  (appended now), which are held (a later segment finished out of order, waiting on a gap),
  and which are discarded (fully behind the checkpoint, or overlapping but not
  offset-aligned — the same non-negotiable append-alignment invariant as the pre-segment
  design). Appending a run advances the durable checkpoint and refills the train back up
  to the queue depth.
- **URLSession resume data is still first-class, but deliberately row-scoped.** The store
  has one resume-blob slot per download row. When pausing a segment train, Labstream captures
  the row-level display watermark once as durable bytes plus the sum of all live segment
  bodies, asks only the **head segment** (the segment whose base offset equals the durable
  checkpoint) for resume data, and plain-cancels the off-head siblings. Those sibling blobs
  would be guaranteed stale against the durable checkpoint and would only race for the one
  slot. The head blob is registered back into the static range lane, not the opaque
  whole-file lane.
- **Adopting a closed head blob restores a real segment.** Its original closed `Range`
  recovers the segment length, the store's exact static source size restores the total when
  the caller cannot derive it from progress, and the planner refills the train behind the
  resumed head. A stale/malformed blob is discarded together with its display watermark.
- **A failed live segment can retry in place from its own blob.** That in-process path
  validates the blob against the failed segment's base offset, replaces only that offset,
  and leaves sibling segments running. It is distinct from manual/relaunch head adoption,
  which rebuilds the train from the durable checkpoint.
- **The durable partial is the fallback.** If resume data is missing, invalid, stale, or refers to a
  temp file the system has deleted, Labstream clears/discards the blob and re-plans the train
  from the durable partial's current file size.
- **HTTP safety checks still guard the append.** Completed bodies are validated for
  `Content-Range` start alignment, pinned validator mismatches, HTTP `200` full-body
  replacement/restart behavior, `416` total validation, temp disappearance fallback, and safe
  resume-blob adoption/clearing. A strangely-resumed transfer should waste bandwidth or fall back
  to the durable partial, never corrupt the file.
- **Why segments, not one task:** a visionOS wake bounce can silently restart the body of an
  in-flight custom-`Range` request with no error and no resume-data callback (see the verified
  platform finding in `docs/DEVELOPMENT.md`). With one open-ended task, that restart forfeits
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
  foregrounding the app resets the system's background rate limiter and gives Labstream a chance
  to process completed tasks or recover from a failed resume blob.
- Plex optimize and Emby convert have a server-preparation phase that needs the
  app awake; after they hand off to a static file, the byte transfer can use the
  static recovery path.
- Jellyfin optimized/compatible-remux downloads, and Emby compatible-remux
  downloads, can be live-forward encoder streams. They may continue as
  system-owned transfers while the OS allows it, but they are not durable
  byte-range checkpoints and can require retry/restart after interruption.
- Cellular downloads are off by default where cellular data is available.
  Settings ▸ Downloads ▸ **Use cellular data for downloads** applies to newly
  created request-based transfer tasks; active tasks and tasks resumed from OS
  resume data keep the policy they were created with.

## Module ownership

| Component | Owns |
| --- | --- |
| `DownloadManager` | Main-actor queue coordination and user-visible state. |
| Backend-specific manager extensions | Plex/Jellyfin/Emby route setup and server-prep polling. |
| `BackgroundDownloadSession` | URLSession tasks, segment-train enqueue/refill, transfer callbacks, finalization. |
| `DownloadStore` | Offline index persistence and file-side effects. |
| PMSKit download policies | Pure route, retry, row-display, and recovery decisions, including the segment-train planner and assembler. |

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
sources.

Side assets such as posters, chapters, and compatible external text subtitles are cached next to the download record when available. They are treated as convenience metadata; the main playable file remains the durable core of the download.

## Reconcile and resume

On launch, Labstream compares the offline index, files on disk, and any active transfers. It should:

- resume or retry recoverable transfers;
- surface failed items clearly;
- avoid deleting user data unless the user asked for cleanup;
- keep orphan detection conservative;
- preserve completed downloads even when the source server is temporarily unavailable.
