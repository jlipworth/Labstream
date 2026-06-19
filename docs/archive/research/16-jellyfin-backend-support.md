# 16 — Jellyfin Backend Support Research

**Research date:** 2026-06-14
**Issue:** #35 — Support Jellyfin as an alternate media server backend.
**Status:** Research + architecture recommendation. Implementation should stay on a separate branch/worktree until the Plex media-session-proxy refactor stabilizes.

## TL;DR

Jellyfin support is feasible and probably a better long-term test of VisionPlay's real architecture goal: a stable visionOS player over a server-specific media-session backend. Jellyfin has a generated official OpenAPI surface for the needed pieces: user auth, library browsing, playback preparation, HLS/server-side transcoding, playback progress, active-encoding cleanup, and direct downloads. The strongest native-client pattern is:

1. Authenticate and send the full `Authorization: MediaBrowser ... Token="..."` header.
2. Browse with `GET /UserViews`, `GET /Items`, and `GET /Items/{itemId}`.
3. Prepare playback with `POST /Items/{itemId}/PlaybackInfo` using a visionOS/AVPlayer `DeviceProfile` and the requested bitrate/start time/streams.
4. Prefer the returned `MediaSourceInfo.TranscodingUrl` when Jellyfin decides HLS/remux/transcode is needed; build direct/static stream URLs only when Jellyfin reports direct play/direct stream support.
5. Report start/progress/stopped with `/Sessions/Playing*` and explicitly stop active encodings with `DELETE /Videos/ActiveEncodings` when replacing or tearing down transcodes.
6. Treat downloads as original-file downloads via `/Items/{itemId}/Download` first. That is not the same as a pre-transcoded VisionPlay-compatible offline asset.

The codebase should **not** make `MediaSessionProxy` generic while #33 is still changing. Start with an app-side backend boundary above PMSKit, keep Plex behavior byte-identical, then add a Jellyfin adapter behind an experimental/default-off backend toggle.

## Official API surface

The current public Jellyfin API browser exposes a generated OpenAPI spec. The stable spec checked during this research identified itself as `Jellyfin API` version `10.11.11` / `x-jellyfin-version=10.11.11`. The docs are useful but mostly generated; live server validation is still required for playback URL shape, HLS quirks, and exact seek behavior.

### Authentication

| Need | Endpoint / shape | Notes |
|---|---|---|
| Username/password login | `POST /Users/AuthenticateByName` (`AuthenticateUserByName`) | Body has `Username` and `Pw`; response `AuthenticationResult` contains `User`, `SessionInfo`, `AccessToken`, and `ServerId`. |
| Auth header | `Authorization: MediaBrowser Client="...", Device="...", DeviceId="...", Version="...", Token="..."` | Use the full MediaBrowser header, not old token-only or query-param styles. Jellyfin has signaled deprecated auth mechanisms will tighten in Jellyfin 12. |
| Quick Connect | SDK-supported flow | Good later UX candidate; not necessary for first live spike. |

### Library and metadata

| Need | Endpoint | Notes |
|---|---|---|
| Library roots | `GET /UserViews` | Query: `userId`, `includeExternalContent`, `presetViews`, `includeHidden`. |
| Browse/search/list | `GET /Items` | Query: `userId`, `parentId`, `recursive`, `includeItemTypes`, `fields`, `sortBy`, `sortOrder`, `startIndex`, `limit`, `enableUserData`, image fields. |
| Item detail | `GET /Items/{itemId}` | Query: `userId`; returns `BaseItemDto`. |
| Posters/backdrops | `GET /Items/{itemId}/Images/{imageType}` | Replaces Plex `/photo/:/transcode` for posters/backdrops. |

### Playback preparation and HLS/transcoding

| Need | Endpoint / field | Notes |
|---|---|---|
| Playback decision | `POST /Items/{itemId}/PlaybackInfo` | Body/query can include `UserId`, `StartTimeTicks`, `AudioStreamIndex`, `SubtitleStreamIndex`, `MediaSourceId`, `MaxStreamingBitrate`, `DeviceProfile`, direct-play/direct-stream/transcode flags, stream-copy flags. |
| Decision result | `PlaybackInfoResponse` | Contains `PlaySessionId`, `MediaSources`, `ErrorCode`. |
| Selected source | `MediaSourceInfo` | Important fields: `Id`, `MediaStreams`, `DefaultAudioStreamIndex`, `DefaultSubtitleStreamIndex`, `SupportsDirectPlay`, `SupportsDirectStream`, `SupportsTranscoding`, `TranscodingUrl`, `TranscodingContainer`, `TranscodingSubProtocol`, `RequiredHttpHeaders`. |
| HLS master | `GET /Videos/{itemId}/master.m3u8` | Key params include required `mediaSourceId`, `playSessionId`, `deviceId`, `startTimeTicks`, stream indexes, bitrate/codec caps, segment settings, adaptive/trickplay flags. Usually prefer returned `TranscodingUrl` first. |
| HLS variant | `GET /Videos/{itemId}/main.m3u8` | Similar parameter family. |
| Direct/static stream | `GET /Videos/{itemId}/stream[.{container}]` | Use with `static=true`, selected `mediaSourceId`, `playSessionId`, `tag`, and auth when direct/static playback is chosen. |

**Tick units:** OpenAPI prose around `startTimeTicks` is generated and easy to misread. Treat Jellyfin ticks as the usual .NET/Emby/Jellyfin 10,000 ticks per millisecond and verify against a live server before wiring seek/restart behavior.

### Playback progress and cleanup

| Need | Endpoint | Payload / query |
|---|---|---|
| Start | `POST /Sessions/Playing` | `PlaybackStartInfo`: `ItemId`, `MediaSourceId`, stream indexes, `PositionTicks`, `PlaySessionId`, `PlayMethod`, etc. |
| Progress | `POST /Sessions/Playing/Progress` | `PlaybackProgressInfo`: position, pause/mute state, streams, play method, session. |
| Stop | `POST /Sessions/Playing/Stopped` | `PlaybackStopInfo`: item/source/session/position and `Failed`. |
| Ping | `POST /Sessions/Playing/Ping` | Query `playSessionId`. |
| Stop encoding | `DELETE /Videos/ActiveEncodings` | Query `deviceId` and `playSessionId`; important before replacing or abandoning a transcode. |

### Downloads/offline

| Need | Endpoint | Notes |
|---|---|---|
| Original media download | `GET /Items/{itemId}/Download` | Reference clients use this for downloads. Gate UI on `CanDownload`/policy. |
| Original file | `GET /Items/{itemId}/File` | Direct original file access. |
| Direct stream fallback | `GET /Videos/{itemId}/stream[.{container}]` | Can be used for direct/static delivery, but not an offline transcode system. |

No first-party offline-sync system analogous to Plex Downloads was found in the public API surface. VisionPlay should treat Jellyfin downloads as raw/original media downloads first; a VisionPlay-compatible offline rendition would be a later app/server workflow.

## Reference-client behavior

### Official Swift SDK (`jellyfin/jellyfin-sdk-swift`)

Use this as a generated API reference, not as a player architecture. It exposes the exact shapes VisionPlay needs:

- `Paths.getPostedPlaybackInfo(itemID:...)` for `POST /Items/{id}/PlaybackInfo`.
- `PlaybackInfoDto` with device profile, start ticks, stream indexes, media source, max bitrate, and direct/transcode flags.
- `MediaSourceInfo.transcodingURL` for returned server-generated transcode URLs.
- `Paths.getVideoStream` for direct/static video streams.
- `Paths.getDownload` for `/Items/{id}/Download`.
- `reportPlaybackStart`, `reportPlaybackProgress`, and `reportPlaybackStopped`.

### Swiftfin (`jellyfin/Swiftfin`)

Swiftfin is the closest Apple-client reference because it has both VLC and native AVPlayer paths.

Observed flow:

1. Fetch full item and choose a media source.
2. Build a player-specific Jellyfin `DeviceProfile`.
3. POST `PlaybackInfoDto` with `AutoOpenLiveStream=true`, `DeviceProfile`, `LiveStreamId`, `MaxStreamingBitrate`, `UserId`, and `MediaSourceId` for non-live items.
4. Choose the returned `MediaSourceInfo` with eTag/open-token/id fallback matching.
5. If `mediaSource.transcodingURL` exists, resolve it against the server URL and play that.
6. Otherwise, for non-live video, build `/Videos/{itemId}/stream` with `Static=true`, `Tag`, and `PlaySessionId`.
7. Report playback start/progress/stop with item id, media source id, play session id, selected audio/subtitle indexes, and position ticks.
8. Downloads use `Paths.getDownload(itemID:)` and store `Media.<mimeSubtype>`.

Swiftfin's native profile is a good starting point: Apple-friendly direct-play containers/codecs, HLS transcoding, `minSegments=2`, break on non-keyframes, and subtitles in the manifest.

### Jellyfin Web

The web client is the best source for server semantics and fallback behavior.

Observed flow:

- `getPlaybackInfo` posts playback info with `UserId`, `StartTimeTicks`, `IsPlayback`, `AutoOpenLiveStream`, selected streams, direct/copy flags, `MaxStreamingBitrate`, direct-play protocols, and `DeviceProfile`.
- Stream selection separates direct play (`mediaSource.Path`), direct/static stream (`/Videos/{id}/stream.{container}` with `Static=true`, `mediaSourceId`, `deviceId`, token, tag, optional live stream id), and transcode (`mediaSource.TranscodingUrl`).
- For HLS transcodes, the web client tags the stream as `application/x-mpegURL`.
- On stream replacement, it stops active encodings before/after source replacement to avoid leaked encoders.
- For iOS/macOS HLS, `htmlVideoPlayer` prefetches `live.m3u8` by replacing `master.m3u8`, then feeds that URL to the player to avoid segment-start stalls. This is a key live-validation target for visionOS AVPlayer.

### Android TV

Android TV is the most useful reference for seek/rebuild edge cases.

Observed flow:

- POST playback info with media source, start ticks, device profile, direct flags, stream indexes, stream-copy allowed, and `AutoOpenLiveStream=true`.
- If the player says the current item is seekable, seek locally.
- If not seekable, stop playback, stop the old active encoding, re-POST playback info with `StartTimeTicks`, and start the returned stream.
- Progress service reports start/progress/stopped with item, queue, play session, position, play method, volume/mute, repeat/order.

### Jellyfin Media Player / Desktop

Desktop delegates server URL construction to Jellyfin Web and hands the resulting URL to MPV. It is still useful because its device profile exposes practical transcode policy knobs: HLS `ts`, configurable video codecs, and force-transcode rules for Dolby Vision/HDR/Hi10P/HEVC/AV1/4K. Those are future tuning inputs for a visionOS profile.

## VisionPlay codebase implications

### What is already reusable

The #33 media-session proxy refactor is valuable for Jellyfin, but only part of it is backend-neutral:

- Generic/reusable now:
  - `HTTPMessage`
  - `LoopbackOrigin`
  - `UpstreamConnection`
  - `UpstreamURLMapper`
  - `PlaylistRewriter`
  - `MediaSessionHandle` / `MediaSessionStatus`
- Plex-specific today:
  - `MediaSessionRequest`
  - `MediaSessionProxy.open(_:offsetMs:)` because it builds `TranscodeRequest` and runs Plex decision/probe.
  - `stopPreviousTranscode` because it calls Plex universal transcode stop.
  - Stage-3 segment behavior because it relies on verified Plex properties: full-timeline playlists, PAT-only stubs before prime offset, absolute segment naming/PTS, and Plex re-prime behavior.

### High-conflict files to avoid until #33 stabilizes

- `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift`
- `VisionPlay/Player/PlaybackController.swift`
- `TESTING-CHECKLIST.md`
- `docs/DEVELOPMENT.md`

### Recommended first boundary

Create an app-side backend layer **above PMSKit** first. Do not rename PMSKit or make `MediaSessionProxy` generic while the Plex proxy branch is still moving.

Suggested initial files:

- `VisionPlay/Backend/MediaBackend.swift`
- `VisionPlay/Backend/BackendModels.swift`
- `VisionPlay/Backend/Plex/PlexBackendAdapter.swift`
- Later: `VisionPlay/Backend/Jellyfin/JellyfinBackendAdapter.swift`

Suggested protocol shape:

```swift
protocol MediaBackend {
    var kind: MediaBackendKind { get }
    func signOut() async
}

protocol LibraryBrowsingBackend {
    func sections() async throws -> [LibrarySection]
    func homeRails() async throws -> [MediaRail]
    func search(_ query: String) async throws -> [MediaRail]
    func metadata(for id: MediaID) async throws -> MediaItem
    func children(of id: MediaID) async throws -> [MediaItem]
}

protocol PlaybackBackend {
    func makePlaybackOpenRequest(
        item: MediaItem,
        options: PlaybackOptions
    ) async throws -> PlaybackOpenRequest

    func reportTimeline(_ event: PlaybackTimelineEvent) async
    func stopPlayback(_ session: PlaybackSession, failed: Bool) async
}

protocol DownloadBackend {
    func downloadRequest(
        item: MediaItem,
        quality: DownloadQuality,
        mediaIndex: Int,
        partIndex: Int
    ) async throws -> DownloadRequest
}
```

For the first branch, the Plex adapter can wrap existing Plex request builders and return current PMSKit models. Jellyfin can initially be a parallel adapter with its own raw request builders and live probes. The UI can migrate gradually once Plex behavior is protected by URL/header snapshot tests.

## Recommended implementation strategy

### Approach A — narrow backend seam first (recommended)

- Add backend protocols and neutral model wrappers/aliases.
- Add a Plex adapter that builds the same current URLs/headers.
- Add tests proving Plex request shapes are unchanged.
- Add Jellyfin API request builders and tests without touching player/proxy hot files.
- After #33 stabilizes, connect Jellyfin playback to the media proxy or a parallel playback resolver.

**Why:** Lowest conflict with ongoing proxy work and protects Plex while creating a clean place for Jellyfin.

### Approach B — make `MediaSessionProxy` backend-generic now

- Refactor proxy to accept a backend resolver for open/re-prime/stop.
- Add Plex and Jellyfin resolvers.

**Why not first:** This touches exactly the files still under active #33 refactor and risks breaking the fragile Plex seek/scrub work before it is live-proven.

### Approach C — Jellyfin spike in a parallel mini-player

- Add a hard-coded Jellyfin login/playback spike behind a debug setting.
- Load returned `TranscodingUrl` directly in AVPlayer without integrating browse/download.

**Why not first:** Fast live validation, but it creates throwaway app plumbing and postpones the backend seam we already know we need.

## Live validation checklist for Jellyfin

Before declaring Jellyfin better than Plex for VisionPlay, run these against a real Jellyfin server:

1. `POST /Items/{id}/PlaybackInfo` with a visionOS profile returns a playable HLS `TranscodingUrl`.
2. AVPlayer on visionOS can play the returned HLS URL with the required auth headers/query token.
3. Determine whether visionOS needs Jellyfin Web's `master.m3u8` → `live.m3u8` prefetch workaround.
4. Confirm seek unit behavior: `StartTimeTicks = seconds * 10_000_000` lands at the requested time.
5. Check whether AVPlayer native seeking works inside Jellyfin HLS transcodes; if not, implement Android-style re-POST-with-start-ticks and item replacement.
6. Confirm `DELETE /Videos/ActiveEncodings?deviceId=...&playSessionId=...` actually stops the server encoder on close/retry/seek rebuild.
7. Inspect subtitle/audio stream behavior for HLS: manifest groups vs burned-in vs external subtitles.
8. Test `/Items/{id}/Download` output on representative media and decide whether raw original downloads are acceptable offline.

## Sources

- Jellyfin API browser: https://api.jellyfin.org/
- Stable OpenAPI spec: https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json
- Jellyfin Swift SDK: https://github.com/jellyfin/jellyfin-sdk-swift
- Swift SDK README (auth/client notes): https://github.com/jellyfin/jellyfin-sdk-swift#readme
- Swiftfin: https://github.com/jellyfin/Swiftfin
- Swiftfin playback builder: https://github.com/jellyfin/Swiftfin/blob/20588d079d7693b4322945073e552dd63644c2b9/Shared/Objects/MediaPlayerManager/MediaPlayerItem/MediaPlayerItem%2BBuild.swift
- Swiftfin progress observer: https://github.com/jellyfin/Swiftfin/blob/20588d079d7693b4322945073e552dd63644c2b9/Shared/Objects/MediaPlayerManager/MediaProgressObserver.swift
- Swiftfin native player profile: https://github.com/jellyfin/Swiftfin/blob/20588d079d7693b4322945073e552dd63644c2b9/Shared/Objects/VideoPlayerType/VideoPlayerType%2BNative.swift
- Jellyfin Web playback manager: https://github.com/jellyfin/jellyfin-web/blob/df87d518b826d5db50b599dbb10e55cf03a2553e/src/components/playback/playbackmanager.js
- Jellyfin Web HLS prefetch workaround: https://github.com/jellyfin/jellyfin-web/blob/df87d518b826d5db50b599dbb10e55cf03a2553e/src/plugins/htmlVideoPlayer/plugin.js
- Jellyfin Android TV playback resolver: https://github.com/jellyfin/jellyfin-androidtv/blob/86036e4e625766f2022e598139f6b6999139bec3/playback/jellyfin/src/main/kotlin/mediastream/JellyfinMediaStreamResolver.kt
- Jellyfin Android TV seek fallback: https://github.com/jellyfin/jellyfin-androidtv/blob/86036e4e625766f2022e598139f6b6999139bec3/app/src/main/java/org/jellyfin/androidtv/ui/playback/PlaybackController.java
- Jellyfin Media Player: https://github.com/jellyfin/jellyfin-media-player
- Jellyfin auth-change risk note: https://jellyfin.org/posts/state-of-the-fin-2026-05-24/
