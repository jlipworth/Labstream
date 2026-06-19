# Downloads and offline playback

Downloads must produce a static local file. The app should not treat a live streaming transcode as a durable offline transfer.

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
- Downloads reject truncated/error bodies and invalid final files.

## Reconcile and resume

On launch, `DownloadManager` reconciles the persisted `DownloadStore` with in-flight transfer tasks and local files.

- Static original transfers are network-bound and can reconnect/retry as file downloads.
- Plex optimizer jobs have two phases: server preparation, then static rendered-part download. Server-prep state is represented separately so the UI can say “Preparing on server…” and poll progress where possible.
- Failed items keep metadata so retry can re-probe and choose the correct current route.
- Canceled/deleted downloads should clean up local files and app-owned queue state; Plex optimizer cleanup must avoid deleting protected/current jobs.

## Offline playback metadata

Offline playback uses the stored metadata snapshot for title, artwork, resume, duration, episode hierarchy, and selected source identifiers. Server metadata may be stale while offline; refresh on later online browse/download actions rather than blocking local playback.
