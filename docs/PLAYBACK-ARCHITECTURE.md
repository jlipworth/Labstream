# Playback architecture

## Plex playback

The Plex path runs through `PlaybackController.start()`:

1. Build a `TranscodeRequest` for the selected quality.
2. For Direct Play / Maximum, probe the decision endpoint first.
3. Open the resulting `start.m3u8` URL in AVPlayer.
4. Start heartbeat/progress reporting and runtime diagnostics.
5. Stop the PMS session explicitly during teardown or before intentional restarts.

The `X-Plex-Client-Profile-Name=Generic` parameter in `TranscodeRequest` is load-bearing. Keep it. `Safari` was tried and regressed high-bitrate 4K HEVC/MKV cases by forcing video transcodes even when Direct Play / Maximum should copy or direct-stream. Unknown profile names can return a bare PMS HTTP 400.

`MediaSessionProxy` is not the active Plex playback path. Plex playback uses PMS URLs directly plus targeted final-target rebuilds and stop-before-restart guards.

## Jellyfin playback

Jellyfin playback is resolved by `JellyfinBrowseService.playbackOpen`. The service returns:

- the selected stream URL
- required headers
- source metadata for diagnostics
- a `RemoteStreamReopener` closure used for quality/audio/subtitle/adaptive restarts

Jellyfin HLS may still use an app proxy handle where needed for header or playlist behavior. That is a backend-specific implementation detail; do not assume Plex proxy behavior applies.

## Local/offline playback

Offline playback uses the custom player with a local file URL. There is no server session, PMS timeline, Jellyfin active-encoding cleanup, or remote stream reopener. Resume information comes from the offline metadata/record model.

## Restart/reopen matrix

| Trigger | Plex | Jellyfin | Local/offline |
| --- | --- | --- | --- |
| Quality change | Stop current PMS session, then request a new stream | Use `RemoteStreamReopener` | Not applicable |
| Audio/subtitle change | Stop current PMS session, then request a new stream | Use `RemoteStreamReopener` | Local track switching only if supported by the local asset |
| Explicit Retry | Rebuild through the normal start path; resets restart budget | Reopen through the remote stream path | Reopen local file |
| Final-target deep seek | Debounced rebuild after final target; throttled by `SeekRestartBudget` | Reopen/seek through remote stream path when available | Seek local file |
| Adaptive down/up shift | Rebuild capped Plex stream when policy allows | Reopen lower/higher Jellyfin stream when policy allows | Disabled |

Silent auto-retry was removed. A failing stream should surface failure instead of hiding a retry loop.

## Server cleanup invariant

Plex HLS gives PMS no reliable end-of-playback signal. Always call the stop endpoint for active Plex transcode sessions, including before same-session restarts. This prevents stacked FFmpeg jobs and the OOM pattern documented in [`PLEX_AVP_TRANSCODE_OOM_REPORT.md`](PLEX_AVP_TRANSCODE_OOM_REPORT.md).
