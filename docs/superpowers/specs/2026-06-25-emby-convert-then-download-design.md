# Emby convert-then-download (server-side prepare → resumable download)

Status: design, awaiting review
Date: 2026-06-25
Issue: extends #126 (Emby existing-version reuse); companion to Plex #112/optimize lane

## Problem

For non-direct-play Emby content, VisionPlay's download path currently does a **live
streaming transcode**: Emby renders bytes on the fly and we stream them to the headset.
Nothing is persisted server-side. That has one fatal property for large media:

- **It cannot be resumed.** `BackgroundDownloadSession` already implements
  `URLSession` resume (captures `NSURLSessionDownloadTaskResumeData`, persists it via
  `store.setResumeData`, restarts with `downloadTask(withResumeData:)` —
  `BackgroundDownloadSession.swift` ~588–610, 663–679). But resume data is only
  honorable when the server resource is a **stable static file** that supports HTTP
  `Range`/`If-Range`. A live transcode session is ephemeral with no stable byte range,
  so a dropped connection means starting over. Multi-GB transcodes effectively never
  finish.

Plex avoids this: its download path triggers a server-side **Optimize** that renders and
persists a real file, then downloads it (resumable). #126 already taught VisionPlay to
**reuse** an existing Emby converted version (the resumable `.original` static lane). The
missing half is **creating** that artifact on demand — the true parity with Plex.

## Goal

Make convert-then-download the **default** lane for non-direct-play Emby downloads:
trigger an Emby Convert Media job → poll until the converted file exists → download it via
the existing resumable `.original` static lane. **Keep** the converted file (reusable, so
#126's reuse lane serves the next download/resume for free).

Non-goals: changing direct-play / compatible-remux behavior (those stay); a quality-tier
picker UI (default a sane quality; picker can come later); replacing Plex's lane.

## Verified server facts (live, Emby 4.9.3)

Empirically confirmed against a live Emby server during design (job ids/source ids below
are placeholders):

- **Create job:** `POST /Sync/Jobs`, `Content-Type: application/json`, body keys are
  **lowercase camelCase** (PascalCase returns HTTP 500):
  ```json
  {"userId":"<id>","itemIds":["<itemId>"],"category":null,"parentId":null,
   "targetId":"originalmediafolder","quality":"8000000","profile":"mobile",
   "bitrate":null,"name":"<job name>","unwatchedOnly":false,
   "syncNewContent":false,"itemLimit":null}
  ```
  - `targetId:"originalmediafolder"` = "next to original files" (persistent, non-device).
    (`originalmediafolderreplace` is destructive — never use.)
  - `quality` must be a **bitrate string** (`"8000000"`/`"4000000"`/`"1500000"`).
    `"original"` returns HTTP 500 for this target — next-to-original conversions are
    bitrate-capped at the offered tiers (max 8 Mbps).
  - `profile:"mobile"` yields an **h264 / mp4** file (broadly direct-play-able on
    visionOS). `tv` / `custom` also exist.
- **Poll:** `GET /Sync/Jobs/{id}` → `Status` (`Queued` → `Converting`/`Transferring` →
  `Completed` / `Failed`/`Cancelled`) and `Progress` (0–100).
- **Result discovery:** once `Completed`, the converted source appears as a **second
  `File` MediaSource** on the same item (distinct `Id`). PlaybackInfo **filters by
  MediaSourceId** (supplying an id returns only that source) — so enumerate with the
  unfiltered call, exactly as #126 already does.
- **Lifecycle:** deleting the Sync job does **not** delete the converted file (verified:
  deleting a second convert job left the first job's converted source intact). So "keep
  the file" is its natural state; we never auto-delete it.
- The static download of the converted source is the already-shipping `.original` lane:
  `GET /Videos/{itemId}/stream.{ext}?static=true&MediaSourceId={id}` → HTTP 206,
  `Content-Range` total == `MediaSource.Size` → resumable.

## Architecture

### 1. PMSKit: `EmbyConvertRequest.swift` (new)

Pure request builders + response models (mirrors `OptimizeRequest.swift`):

- `createConvertJobRequest(server:token:identity:userId:itemId:quality:profile:name:) -> URLRequest`
  — POST `/Sync/Jobs` with the camelCase body above.
- `convertJobStatusRequest(server:token:identity:jobId:) -> URLRequest` — GET
  `/Sync/Jobs/{id}`.
- `deleteConvertJobRequest(server:token:identity:jobId:) -> URLRequest` — DELETE
  `/Sync/Jobs/{id}` (used only to cancel a job the user abandons; never on success).
- `EmbyConvertJob: Decodable` — `id`, `status` (enum), `progress`.
- `EmbyConvertJobStatus` enum mapping the server strings, with `isTerminal` /
  `didSucceed` helpers.

Unit-tested with fixtures (decode status payloads; body-shape assertion that keys are
camelCase). No live calls in the hermetic suite.

### 2. DownloadManager: `triggerConvertAndDownload(item:…)` (new)

Mirrors `triggerOptimizeAndDownload` (DownloadManager.swift ~2708):

1. **Snapshot** existing `File` MediaSource ids for the item (to identify the new one
   later).
2. **Create** the job with `name = "<title> [VisionPlay <uuid8>]"` (same marker
   discipline as Plex, so any future cleanup only ever touches our own jobs).
3. **Seed** a 0% `DownloadRecord` with a new `.preparing` state; persist the `jobId` in
   record metadata so an app relaunch **resumes polling** instead of restarting (the
   conversion runs server-side and survives app death — a strict improvement over live
   transcode, which dies with the session).
4. **Poll** `GET /Sync/Jobs/{id}` with backoff; surface `Progress` as "Preparing on
   server… N%". On `Failed`/`Cancelled` → mark the record failed with a clear message.
5. On `Completed`: fetch **unfiltered** PlaybackInfo, pick the `File` source whose id is
   **not in the snapshot** (the freshly converted one); fall back to the
   h264/mp4/non-primary heuristic if the diff is ambiguous.
6. **Hand off** to existing `downloadEmby(…, mediaSourceIDOverride: newSourceId)` → the
   `.original` static lane → resumable download.
7. **Keep** the job + converted file (no cleanup on success).

### 3. Routing: make it the default

In the Emby download decision (DownloadOptionsSheet / `downloadEmby`): when the resolved
decision for an item would be a **streaming transcode** (`.optimize`/`.transcode`),
redirect to `triggerConvertAndDownload` instead. Unchanged:

- Original is direct-play-able → `.original` / `.compatibleRemux` as today.
- A converted version already exists (#126) → reuse it directly, skip conversion.

Net: every Emby download that isn't already a direct copy becomes a prepare-then-download,
hence resumable.

### Quality default

Default `profile:"mobile"` + `quality:"8000000"` (highest non-`original` tier → h264/mp4,
max compatibility, ~8 Mbps cap). Surfacing a quality picker and the 8 Mbps cap caveat to
the user is a follow-up, not part of this spec.

## State & UI

- New `DownloadRecord` status `.preparing` (distinct from `.downloading`) carrying
  server-side `Progress` (0–100). UI: "Preparing on server… N%", then transitions to the
  normal download progress once bytes flow.
- Cancel during `.preparing` → DELETE the job (it's ours, via the marker) and drop the
  record.

## Error handling

- Create 4xx/5xx → fail the record with the server message; do not silently fall back to
  streaming transcode (that would reintroduce the non-resumable behavior we're removing —
  but offer a retry).
- Job `Failed`/`Cancelled` server-side → fail the record, keep the marker job for
  diagnostics, surface "server conversion failed."
- Converted source not found after `Completed` → fail with a diagnostic; do not download
  the wrong source.
- App relaunch mid-prepare → re-hydrate from persisted `jobId`, resume polling.

## Testing

- PMSKit unit tests: status decoding, terminal/success helpers, camelCase body assertion.
- Existing #126 enumeration tests unchanged.
- Headless smoke on the worktree `$SIMID` (build/install/launch/log/screenshot) — the
  default close-out.
- Device test (user's half): on the headset, download a non-direct-play Emby item, watch
  "Preparing on server… N%" → download → kill mid-download → confirm it **resumes** →
  confirm offline playback. Verify the converted file persists for a second instant
  (reuse) download.

## Open questions for review

1. Quality default — ship `mobile`/8 Mbps now, picker later? (recommended) Or block on a
   picker?
2. On create failure, retry-only vs. offer a one-time "stream instead" escape hatch
   (non-resumable)?
3. Should `.preparing` jobs be cancelable from the existing downloads UI, or is
   swipe-to-delete enough?
