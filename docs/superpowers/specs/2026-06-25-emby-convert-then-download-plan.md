# Implementation plan — Emby convert-then-download

Spec: `2026-06-25-emby-convert-then-download-design.md`. Branch:
`fix/emby-existing-versions-126`. Build/test/smoke per project CLAUDE.md.

## Layer 1 — PMSKit (file-disjoint from app; `PMSKit/Sources/PMSKit/Emby/`)

New file `EmbyConvertRequest.swift`:

- `public enum EmbyConvertJobStatus: String, Sendable` — cases for the observed server
  strings (`Queued`, `Converting`, `Transferring`, `Completed`, `Failed`, `Cancelled`,
  plus a `.unknown` default via a failable/needed init); `var isTerminal: Bool`,
  `var didSucceed: Bool`.
- `public struct EmbyConvertJob: Decodable, Sendable` — `id` (Int, `"Id"`),
  `status` (`EmbyConvertJobStatus`, `"Status"`), `progress` (Double?, `"Progress"`).
- `public enum EmbyConvertRequest`:
  - `static func createJobRequest(server:URL, token:String, identity:ClientIdentity,
    userId:String, itemId:String, quality:String, profile:String, bitrate:Int?,
    name:String) -> URLRequest` — `POST {server}/Sync/Jobs`, `application/json`, body is
    **lowercase camelCase**: `{userId,itemIds:[itemId],category:null,parentId:null,
    targetId:"originalmediafolder",quality,profile,bitrate,name,unwatchedOnly:false,
    syncNewContent:false,itemLimit:null}`. Standard Emby auth header/query via existing
    helpers.
  - `static func jobStatusRequest(server:token:identity:jobId:Int) -> URLRequest` —
    `GET {server}/Sync/Jobs/{jobId}`.
  - `static func deleteJobRequest(server:token:identity:jobId:Int) -> URLRequest` —
    `DELETE {server}/Sync/Jobs/{jobId}`.
  - `static func decodeJob(from:Data) throws -> EmbyConvertJob`.
- Quality mapping helper (preset label → `(quality:String, profile:String, bitrate:Int?)`):
  bitrate presets → `quality:"custom"`, `bitrate:<bps>` (or the matching named tier when
  it lines up), `profile:"tv"`. "Original video quality" → highest bitrate + `profile:"tv"`
  (never the literal `"original"` token — it 500s on `originalmediafolder`).

Tests `EmbyConvertJobTests.swift`: decode each status payload; `isTerminal`/`didSucceed`;
assert `createJobRequest` body is camelCase with `targetId:"originalmediafolder"` and the
expected keys (no PascalCase). Hermetic — no live calls. `cd PMSKit && swift test` green.

## Layer 2 — App integration (`VisionPlay/Downloads/`, `VisionPlay/UI/`)

1. `DownloadManager.triggerConvertAndDownload(item:targetName:metadata:session:)` — mirror
   `triggerOptimizeAndDownload`:
   - snapshot existing `File` MediaSource ids; create job (name carries
     `"<title> [VisionPlay <uuid8>]"`); seed a 0% record in new `.preparing` status with
     `jobId` persisted in metadata.
   - poll `jobStatusRequest` (reuse `optimizePollInterval`, no wall-clock timeout); surface
     `Progress` through the existing `optimizeProgress`/`optimizeState` plumbing
     ("Preparing on server… N%"). `Failed`/`Cancelled` → fail record (retry-only).
   - on `Completed`: unfiltered PlaybackInfo; pick the `File` source id not in the snapshot
     (fallback: h264/mp4 non-primary). Hand off to
     `downloadEmby(…, mediaSourceIDOverride: newId)` (existing resumable `.original` lane).
   - keep job + file (no success cleanup).
2. Routing: where the Emby download decision would yield a streaming transcode
   (`.optimize`/`.transcode`), route to `triggerConvertAndDownload`. Unchanged: direct-play
   / compatible-remux, and #126 reuse when a converted source already exists.
3. `DownloadRecord` status `.preparing` (distinct from `.downloading`); persist `jobId` in
   metadata for relaunch re-hydration (resume polling, not restart).
4. Cancel: extend `delete(ratingKey:)` so a `.preparing` Emby row also fires
   `EmbyConvertRequest.deleteJobRequest` for its `jobId` (Plex parity — kill the
   server-side job on row delete). No new UI.
5. UI (`DownloadOptionsSheet` / downloads list): show "Preparing on server… N%" for
   `.preparing`; the existing quality picker drives the convert quality (parity).

## Verification (gate)

- `cd PMSKit && swift test` green (existing 613 + new).
- App builds (`CODE_SIGNING_ALLOWED=NO`) with the link-skip / stale-binary guards.
- Headless smoke on the worktree `$SIMID`: install (UUID match), launch, log clean,
  screenshot reaches the Plex browse UI (golden sim is Plex — convert lane isn't exercised
  here; that's the device test). Process stays alive, no crash/assert.
- Device test (user): non-direct Emby download → "Preparing…" → download → kill mid-way →
  **resumes** → offline playback; second download of same item reuses the kept file.

## Notes / constraints

- Never commit tokens/client ids/real host/media titles (repo goes public).
- `originalmediafolderreplace` is destructive — never use; only `originalmediafolder`.
- No Anthropic/Claude co-author trailers.
