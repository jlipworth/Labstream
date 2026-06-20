# 18 — Offline chapters, trickplay, and subtitles

Status: investigation for issue #74. This is not yet implemented behavior.

## Current online behavior

### Plex

- Chapters and intro/credits markers are decoded on full metadata requests (`Chapter` and
  `Marker` elements). The player surfaces chapters through the custom Chapters tab because
  visionOS does not expose the native navigation-marker APIs used on other platforms.
- Plex trickplay uses the selected `Part.indexes` field. When `indexes` contains `sd`,
  `PlexBIFTrickPlayThumbnailProvider` fetches `/library/parts/{partID}/indexes/sd` once and
  serves scrub previews from the in-memory BIF.
- Subtitle/audio tabs use `Part.Stream` metadata plus AVFoundation media-selection groups when
  the stream exposes them. Server-burned subtitle choices reopen the stream with a selected
  subtitle stream.

### Jellyfin

- Full item requests include `Chapters`; PMSKit maps them into the shared `Chapter` model with
  synthetic chapter-image keys.
- Jellyfin trickplay is image-tile based: an image-only HLS playlist plus JPEG tile sheets. The
  online provider fetches the playlist, then only the tile sheet needed for the current scrub
  target.
- Subtitle selection is negotiated through PlaybackInfo / stream reopen. Static or transcoded
  download files are not currently paired with separately persisted subtitle assets.

## Current offline behavior

Offline playback reconstructs a `MediaItem` from `OfflineMetadata`. As of this branch, that
snapshot preserves text chapter markers, library/display fields, resume, source identifiers, and
poster path, but it does **not** persist:

- intro/credits markers,
- chapter image bytes,
- Plex BIF index bytes,
- Jellyfin trickplay playlists/tile sheets,
- subtitle stream metadata or sidecar subtitle files.

As a result, downloaded playback has the same base player chrome, resume, speed, stats, local file
playback, and text chapter navigation. It should not be expected to show online-equivalent
trickplay scrub previews or server-equivalent subtitle choices; embedded local-file subtitle tracks
may still appear when AVFoundation exposes them.

## What must be captured at download time

### Chapters

Implemented as the Phase 1 low-risk slice for both Plex and Jellyfin: text chapter metadata is
stored in `OfflineMetadata` at enqueue time and restored into the local `MediaItem`. Chapter images
are not cached yet.

Suggested minimum fields per chapter:

- stable id / synthesized id,
- title/tag,
- start/end offsets in milliseconds,
- optional local thumbnail relative path.

### Trickplay

#### Plex BIF

Feasible for original and optimized downloads when the source/selected part advertises a standard
BIF index. Cache the BIF bytes once at download time and point the offline player at a local BIF
provider.

Open question: optimized Plex output may be a new server-rendered Part. Prefer the downloaded
output's own BIF if PMS exposes one; otherwise source BIF timestamps should usually remain useful
for same-duration optimized copies, but this needs live verification.

#### Jellyfin tiles

Feasible but larger and more complex than Plex BIF. Cache the trickplay playlist plus referenced
JPEG tile sheets under the download assets directory. Count these bytes against the download's disk
usage because tile sheets can be non-trivial for long movies.

Open questions:

- Whether tile URI sets are stable across server versions and media-source IDs.
- Whether transcoded downloads preserve the exact source timeline for source trickplay tiles.

### Subtitles

Subtitles need feature/backend split; do not treat them as a single checkbox.

- **Original downloads:** external/sidecar text subtitles are the best first target if the backend
  exposes a stable file URL. Store local subtitle files beside the media and surface only locally
  available tracks in the offline picker.
- **Optimized/transcoded downloads:** server may burn subtitles, omit them, or require a selected
  subtitle stream at render time. A downloaded MP4 is a single finished file, so post-download
  subtitle selection only works if we separately cache compatible sidecar subtitles.
- **Image subtitles:** PGS/VobSub are not good first offline sidecar targets for AVPlayer. Prefer
  burn-in at download time or defer.

Implementation note (#80): VisionPlay now caches only compatible external text sidecars (`srt`,
`subrip`, `vtt`/`webvtt`) for original downloads. Cached subtitle metadata stores display
label/language/codec plus a Downloads-relative path only; token-bearing server URLs are never
persisted. Offline playback shows an `Off` row plus tracks whose local sidecar parsed into cues;
selecting one renders an app-owned subtitle overlay against the local media clock. Embedded tracks
remain whatever AVFoundation can discover in the downloaded file. Image subtitles, missing/failed
sidecars, and optimized/transcoded burn-in choices are documented as unavailable for post-download
selection rather than shown as selectable offline rows.

## Proposed storage layout

Keep media files and metadata under the existing Downloads cache. Example for rating key `1234`:

```text
Application Support/VisionPlay/Downloads/
  index.json
  1234.mp4
  1234.poster.jpg
  1234.assets/
    metadata.json              # optional richer offline sidecar manifest
    chapters.json              # chapter/marker snapshot if not embedded in index.json
    chapters/
      0.jpg
      1.jpg
    trickplay/
      plex-sd.bif
      jellyfin-playlist.m3u8
      tiles/
        0.jpg
        1.jpg
    subtitles/
      42.eng.forced.srt
      43.spa.srt
```

All paths stored in `index.json` / sidecar manifests should be relative to the Downloads base
directory, matching the existing media/poster convention so sandbox moves do not break them.

## Recommended implementation split

1. **Offline text chapters:** done in this branch for newly-created downloads. Existing downloads
   can gain chapters only if re-downloaded or migrated later.
2. **Plex offline BIF:** cache `sd` BIF where available; add a local-file BIF provider.
3. **Jellyfin offline trickplay tiles:** cache playlist + tile sheets with storage accounting.
4. **Subtitle sidecars:** start with external text subtitles for original downloads only; later
   decide burn-in policy for optimized downloads.

## Validation tasks

- Download a Plex original and optimized item with chapters + BIF; verify local chapter tab and
  scrub preview timing after network is disabled.
- Download a Jellyfin item with chapters + trickplay tiles; verify cached tile sheet addressing and
  timing after network is disabled.
- Test a media item with external SRT and image-based subtitles; confirm which tracks are locally
  available and how the picker labels missing/burned-in cases.
- Measure asset byte sizes and include them in storage-limit decisions before enabling automatic
  trickplay/subtitle caching by default.
