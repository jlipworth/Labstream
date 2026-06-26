# Downloads and offline playback

Downloads must produce a static local file. The app should not treat a live streaming transcode as a durable offline transfer.

For the current AVP compatibility research matrix — source-route gates, final-artifact validation, and headless vs. physical-device proof — see [Offline playback compatibility on Apple Vision Pro](research/offline-playback-compatibility.md).

## Plex routes

### Direct original

The sheet offers **Download original** only when both gates pass:

1. the Plex decision response says the whole file is direct playable, and
2. the source container is locally playable as a raw local file (`mp4`, `m4v`, or `mov`).

This is intentionally stricter than streaming. A file can stream through direct stream/remux while still being a poor byte-for-byte offline file target. Most MKV originals therefore do not get the raw-original option.

When original is selected, the manager runs a delayed muted AVPlayer preflight against the source path before committing. Failure falls back to a compatible original-quality optimizer route.

### Compatible original quality

**Original video quality** means “keep source video quality in a compatible offline file.” It uses the Plex optimizer/static rendered-part path with no meaningful video cap, so containers/audio can be repackaged or transcoded for local playback without intentionally lowering video quality.

This should usually be much faster than a capped video encode when PMS can copy video and only remux/transcode audio, but it is still server work and can be slow if PMS decides a video transcode is required.

### Bitrate presets

Numeric presets request explicit lower-resolution/lower-bitrate compatible files through the optimizer route. Do not expose generic Plex labels such as “Optimized for TV” in the user-facing sheet; use the app’s concrete bitrate/resolution labels.

## Jellyfin routes

Jellyfin download support mirrors the same offline goal:

- original only when the source is locally playable as a static file
- otherwise a compatible static MP4/transcoded request for the selected quality
- required Jellyfin headers preserved on requests

As of this docs pass, Jellyfin download behavior has unit/request-path coverage but has not had the same live headset validation as Plex downloads. Do not describe it as fully live-proven until that check happens.

## Transfer sessions

- Device builds use background `URLSession` for durable transfers.
- Simulator builds use a foreground session where background download behavior is not reliable.
- Downloads reject HTTP error bodies and invalid final files. Very small files are not rejected by byte size alone; they still must pass local AVFoundation playback validation.

### Off-head behavior (observed on hardware)

The static-file transfer (`nsurlsessiond` background `URLSession`) keeps making progress with the
headset off the head and connected to power, but **not indefinitely**. Observed: transfers continue
for roughly the first ~30 minutes off-head, but over a span of hours they stop progressing — the
system stops scheduling the suspended app's background transfer in deep standby, and being on power
does not make it unbounded.

Practical guidance: small/medium downloads off-head are fine; the "queue a large download, set the
headset down for hours, come back to a finished file" workflow is **not reliable**. For large
downloads, keep the headset on (or pick it up periodically to re-wake the session — reconciliation
re-kicks reconnectable transfers on resume).

Note this is the **Phase B** (byte-transfer) limit. It is separate from, and milder than, the Plex
**Phase A** server-prepare poll: that poll runs in-process, so a long server render queued and then
immediately set down may not even *start* its Phase B transfer until the headset is worn again.

## Reconcile and resume

On launch, `DownloadManager` reconciles the persisted `DownloadStore` with in-flight transfer tasks and local files.

- Static original transfers are network-bound and can reconnect/retry as file downloads.
- Plex optimizer jobs have two phases: server preparation, then static rendered-part download. Server-prep state is represented separately so the UI can say “Preparing on server…” and poll progress where possible.
- Jellyfin/Emby compatible downloads are live transcode streams, not durable server-prep jobs. When they are canceled, fail, or complete, VisionPlay sends active-encoding cleanup for the download play session where the backend exposes it.
- Failed items keep metadata so retry can re-probe and choose the correct current route.
- Canceled/deleted downloads should clean up local files and app-owned queue state; Plex optimizer cleanup must avoid deleting protected/current jobs.

## Offline playback metadata

Offline playback uses the stored metadata snapshot for title, artwork, text chapters, resume, duration, episode hierarchy, and selected source identifiers. Server metadata may be stale while offline; refresh on later online browse/download actions rather than blocking local playback.

### Cached side assets

Beyond the metadata snapshot, a download persists several binary side assets so the
offline experience matches online playback without any server access. Each is stored
as a path **relative to the Downloads base directory** (the sandbox container path is
not stable across installs/devices) and re-resolved to an absolute URL when the record
is hydrated:

- **Poster / backdrop.** The cached poster (`posterRelativePath`) feeds the offline
  library rows; the original `thumb`/`art` keys are kept so the image can be re-fetched
  if the local cache is missing and the server is reachable again.
- **Chapter images.** Per-chapter thumbnails (`chapterImageRelativePaths`) are fetched
  at download time from each backend's chapter-image endpoint and keyed by chapter index
  (not a flat array — chapter indices are not always contiguous). They power the offline
  Chapters menu rail with real thumbnails and give the Emby offline scrubber a coarse
  chapter-granularity preview source. Empty when no chapter carried an image. The text
  chapter markers themselves (`chapters`) are stored separately so the Chapters tab works
  even when no images were captured.
- **Plex trick-play index.** For Plex parts that advertise a standard-definition BIF, the
  index (`plexBIFRelativePath`) is cached for offline scrubbing.
- **Jellyfin trick-play.** The Jellyfin trickplay playlist (`jellyfinTrickPlayPlaylistRelativePath`)
  and its tile sheets (`jellyfinTrickPlayTileRelativePaths`) are cached. The cached playlist
  is **sanitized**: tile lines are rewritten to local filenames and never contain
  token-bearing server URLs.
- **Offline text subtitles.** External text subtitle tracks (`offlineTextSubtitles`) are
  downloaded for offline selection. Embedded subtitles remain discoverable through
  AVFoundation directly; image/burned-in/unavailable tracks are intentionally not
  represented here.

### Side-asset disk accounting

A record tracks the bytes occupied by its sidecar assets (poster, trickplay, subtitles)
separately from the media file in `sideAssetBytes`. This value is computed by the app store
when records are hydrated (it is not persisted in the media row itself) so the Offline tab
can account for the full on-disk footprint of a download, not just the video file.
