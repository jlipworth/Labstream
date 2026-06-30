# Playback architecture

## Plex playback

The Plex path runs through `PlaybackController.start()`:

1. Build a `TranscodeRequest` for the selected quality.
2. For Direct Play / Maximum, probe the decision endpoint first.
3. Open the resulting `start.m3u8` URL in AVPlayer.
4. Start heartbeat/progress reporting and runtime diagnostics.
5. Stop the PMS session explicitly during teardown or before intentional restarts.

The `X-Plex-Client-Profile-Name=Generic` parameter in `TranscodeRequest` is load-bearing. Keep it. `Safari` was tried and regressed high-bitrate 4K HEVC/MKV cases by forcing video transcodes even when Direct Play / Maximum should copy or direct-stream. Unknown profile names can return a bare PMS HTTP 400.

`MediaSessionProxy` is not the active Plex playback path and no longer owns a Plex `open`/decision flow. Plex playback uses PMS URLs directly plus targeted final-target rebuilds and stop-before-restart guards; the proxy is only a stream-level loopback/playlist forwarder for already-resolved HLS URLs.

## Jellyfin playback

Jellyfin playback is resolved by `JellyfinBrowseService.playbackOpen`. The service returns:

- the selected stream URL
- required headers
- source metadata for diagnostics
- a `RemoteStreamReopener` closure used for quality/audio/subtitle/adaptive restarts

Jellyfin HLS may still use an app proxy handle where needed for header or playlist behavior. That is a backend-specific implementation detail; do not assume Plex proxy behavior applies.

## Emby playback

Emby playback is implemented in the parallel Emby lane (`EmbyBrowseService.playbackOpen` + `EmbyPlayback` in PMSKit) and live-validated against a real Emby server. The lifecycle mirrors Jellyfin but is an explicit, separate lane:

1. **PlaybackInfo.** `POST /Items/{Id}/PlaybackInfo?UserId=…` with `UserId` in **both** the query and the body, the full constraint set, and a visionOS `DeviceProfile`. `AutoOpenLiveStream` is `false` (Jellyfin used `true`). POST is required so the device profile and constraints are sent.
2. **Stream resolution (`EmbyPlayback.resolveStream`).** Preference order: the server-generated `TranscodingUrl` (HLS), then `DirectStreamUrl`, then a synthesized `stream.{container}` direct-play URL. Server-generated URLs are **relative** (`/videos/{id}/master.m3u8`, lowercase) and are joined onto the server base URL, preserving any `/emby` base path.
3. **Stream auth.** The server-generated HLS URL carries the token as `api_key=` in the query, so AVPlayer's child playlists/segments inherit auth automatically — **do not inject a per-child `Authorization` header.** For the direct-stream fallback, when `AddApiKeyToDirectStreamUrl` is true the token is appended to the URL; when false, the token is attached via the `X-Emby-Token` header instead. `RequiredHttpHeaders` from the response are always carried through.
4. **Progress.** Report now-playing/progress/stopped/ping through `POST /Sessions/Playing`, `/Sessions/Playing/Progress`, `/Sessions/Playing/Stopped`, and `/Sessions/Playing/Ping?PlaySessionId=…`, sending the correct `PlayMethod` (`DirectPlay`/`DirectStream`/`Transcode`).
5. **Encoder cleanup.** When the resolved source uses server-side encoding (`EmbyPlaybackOpenResult.usesServerEncoding`, set for the transcode/HLS path), call `DELETE /Videos/ActiveEncodings?DeviceId=&PlaySessionId=` on stop via `EmbyBrowseService.stopActiveEncoding`. `/Sessions/Playing/Stopped` is session/progress state and does **not** terminate the encoder.

The Emby lane does not reuse Jellyfin's `MediaBrowser` auth/header builder: Emby uses its own `Emby` auth scheme (`EmbyAuth.authorizationHeader`) plus `X-Emby-Token` on authenticated calls. (The live server happened to accept the `MediaBrowser` header too, but the Emby lane sends the canonical `Emby` scheme.) Redact the token and any `api_key`/`X-Emby-Token` value from logs.

## Local/offline playback

Offline playback uses the custom player with a local file URL. There is no server session, PMS timeline, Jellyfin/Emby active-encoding cleanup, or remote stream reopener. Resume information comes from the offline metadata/record model.

## Restart/reopen matrix

| Trigger | Plex | Jellyfin | Emby | Local/offline |
| --- | --- | --- | --- | --- |
| Quality change | Stop current PMS session, then request a new stream | Use `RemoteStreamReopener` | Use the Emby remote stream reopener; stop active encoding when leaving a server-encoded source | Not applicable |
| Audio/subtitle change | Stop current PMS session, then request a new stream | Use `RemoteStreamReopener` | Use the Emby remote stream reopener; preserve `RequiredHttpHeaders`/token handling from `PlaybackInfo` | Local track switching only if supported by the local asset |
| Explicit Retry | Rebuild through the normal start path; resets restart budget | Reopen through the remote stream path | Reopen through the Emby playback-open path | Reopen local file |
| Final-target deep seek | Debounced rebuild after final target; throttled by `SeekRestartBudget` | Reopen/seek through remote stream path when available | Reopen/seek through remote stream path when available | Seek local file |
| Adaptive down/up shift | Rebuild capped Plex stream when policy allows | Reopen lower/higher Jellyfin stream when policy allows | Reopen lower/higher Emby stream when policy allows | Disabled |

Silent auto-retry was removed. A failing stream should surface failure instead of hiding a retry loop.

## Server cleanup invariant

Plex HLS gives PMS no reliable end-of-playback signal. Always call the stop endpoint for active Plex transcode sessions, including before same-session restarts. This prevents stacked FFmpeg jobs and the server-side OOM pattern that arises when Plex is repeatedly forced into software HEVC transcodes for the same item within a short window.

The same class of invariant applies to Emby: `POST /Sessions/Playing/Stopped` reports session/progress state but does **not** stop a server-side encoder. For any Emby source that used server-side encoding (`usesServerEncoding`), the encoder must be stopped explicitly with `DELETE /Videos/ActiveEncodings?DeviceId=&PlaySessionId=` on teardown. Do not collapse `Stopped` and active-encoding cleanup into one call.
