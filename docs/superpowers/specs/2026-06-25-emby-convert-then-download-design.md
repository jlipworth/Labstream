# Emby convert-then-download (server-side prepare → resumable download)

Status: implemented + headless-verified on fix/emby-existing-versions-126 (device test pending)
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

Non-goals: changing direct-play / compatible-remux behavior (those stay); a new quality
picker (the convert lane honors the EXISTING download picker for Plex parity); replacing
Plex's lane.

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
  - `quality:"custom"` + `profile:"tv"` + `bitrate:<int>` is accepted (live-verified: job
    created + Converting). Arbitrary custom bitrates are honored — `bitrate:40000000` was
    accepted and actively transcoding, so there is **NO 8 Mbps cap**. The literal
    `quality:"original"` returns HTTP 500 for this target — never send it (map
    "Original video quality" to a high keep-quality custom bitrate instead).
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

### Quality — honor the existing picker (Plex parity)

`DownloadOptionsSheet` already offers a full quality picker (Original video quality, 4K
40 Mbps, 1080p 20/12/10/8 Mbps, 720p 4/3/2 Mbps, 480p 1.5 Mbps) that drives the Plex
optimize targets. The convert lane honors the **same** picker for parity: each preset's
**bitrate** maps to an Emby convert job. h264/mp4 output (direct-play on visionOS) is the
constant.

Mapping (all live-verified, Emby 4.9.3): every preset → `quality:"custom"` +
`profile:"tv"` + `bitrate:<preset bps>`. Arbitrary bitrates are honored (40 Mbps accepted +
transcoding), so there is **no 8 Mbps cap**. "Original video quality" → a high keep-quality
bitrate (`keepQualityBitrate`, 80 Mbps) because the literal `quality:"original"` token
returns HTTP 500 on `originalmediafolder`.

**Known fidelity limit — the lane caps at 1080p (live-verified).** Emby's convert-job API
has **no per-job resolution field** — output resolution is governed by the `profile`. The
built-in `tv` profile (the highest non-custom) **downscales to 1080p**: a 3840×2160 HEVC
source converted with `profile:"tv"` at 20 Mbps produced **1920×1080** h264 (verified on a
real 4K item). So:

- The picker's resolution tiers (4K/1080p/720p/480p) differ only by **bitrate** in the
  converted output, not by an enforced height; "4K 40 Mbps" yields 1080p @ ~40 Mbps, not
  4K.
- This only affects content that actually needs transcoding. 4K HEVC/H.264 that the device
  can **direct-play stays 4K** via the `.original` lane (the convert lane never triggers
  for it). The 1080p cap is the fallback only for genuinely incompatible sources.
- True 4K conversions would require a server-side **custom** sync profile configured for
  2160p, addressable via `profile:"custom"` — not built today (open decision).

## State & UI

- New `DownloadRecord` status `.preparing` (distinct from `.downloading`) carrying
  server-side `Progress` (0–100). UI: "Preparing on server… N%", then transitions to the
  normal download progress once bytes flow.
- **Cancel = delete the row (Plex parity).** No new cancel UI. The existing
  `delete(ratingKey:)` gesture handles it: for Plex it cancels the transfer and the
  stale-job cleanup removes the optimize queue item; for Emby, because we persist the Sync
  `jobId` in record metadata, `delete` of a `.preparing` row additionally issues
  `DELETE /Sync/Jobs/{id}` to kill the server-side conversion (verified working live).

## Error handling

- Create 4xx/5xx → fail the record with the server message and **offer retry only**. No
  "stream instead" fallback — that would silently reintroduce the non-resumable behavior
  this feature removes. (Failures are realistically network / server-error, so retry is
  the right and only escape.)
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

## Resolved decisions (review pass 2026-06-25)

1. **Quality:** honor the existing picker for full Plex parity (no "later"); map each
   preset to Emby `quality`/`profile`. "Original video quality" → custom profile at source
   bitrate/res (literal `"original"` 500s on `originalmediafolder`).
2. **Create failure:** retry-only; no streaming fallback.
3. **Cancel:** reuse the existing delete-the-row gesture; for Emby it also issues
   `DELETE /Sync/Jobs/{id}` via the persisted job id. No new UI.

## Resolved (implementation-time, live-verified)

- **Custom profile + arbitrary bitrate works.** `POST /Sync/Jobs` with `quality:"custom"` +
  `profile:"tv"` + `bitrate:<int>` is accepted (job created + Converting). Bitrate is **NOT
  capped at 8 Mbps** — `bitrate:40000000` was accepted and actively transcoding, so each
  picker preset now maps to its TRUE bitrate ("4K 40 Mbps" → 40 Mbps, … "480p 1.5 Mbps" →
  1.5 Mbps), and "Original video quality" maps to a high keep-quality bitrate (80 Mbps).
- The literal `quality:"original"` returns HTTP 500 on the `originalmediafolder` target —
  never sent.
- **Resolution** is governed by the `profile`, not a per-job field — that remains a
  documented Emby constraint; there is no resolution field to add.
