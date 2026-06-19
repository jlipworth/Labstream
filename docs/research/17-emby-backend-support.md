# 17 — Emby backend support research

Status: research only. Emby is not implemented in VisionPlay yet.

Issue: https://github.com/jlipworth/VisionPlay/issues/68

## TL;DR

Emby should be treated as its own backend lane, not as "Jellyfin with a different name." The APIs are related and many playback concepts overlap, but Emby has distinct auth headers, Emby Connect behavior, server URL/base-path concerns, and documentation ambiguities that need live validation.

Recommended first implementation boundary when this work starts:

1. manual server URL + username/password sign-in,
2. authenticated browse/metadata mapping into `MediaItem`,
3. playback-info based stream resolution,
4. progress reporting and explicit active-encoding cleanup,
5. only then optional Emby Connect or LAN discovery.

Do not implement Emby Connect, UDP discovery, or broad backend abstractions as part of the first slice unless live research proves they are necessary.

## Source quality note

Primary references are Emby's developer documentation and support pages. As of 2026-06-19, some pages appear inconsistent about header naming, whether a public endpoint requires auth, and whether token should be carried in `Authorization`/`X-Emby-Authorization`, `X-Emby-Token`, or query string form. Treat this document as a planning map, not proof. Verify every wire-shape decision against a real Emby server before calling support implemented.

## Authentication

### Manual server login

Primary endpoint:

```http
POST /Users/AuthenticateByName
Content-Type: application/json
Accept: application/json
```

Body shape:

```json
{
  "Username": "name",
  "Pw": "plain-text-password"
}
```

The request should include app/device identity. Emby references describe an auth scheme like:

```http
Authorization: Emby UserId="...", Client="VisionPlay", Device="Apple Vision Pro", DeviceId="...", Version="...", Token="..."
```

Some docs and endpoints also mention `X-Emby-Authorization` and `X-Emby-Token`. Implementation must live-probe which combination is accepted by current Emby Server versions. For planning, keep this as an Emby-specific auth seam rather than reusing Jellyfin's `MediaBrowser` header builder.

Successful auth returns at least:

- `AccessToken`
- `ServerId`
- `User`
- `SessionInfo`

Passwords must never be persisted.

### Logout

On explicit sign-out, call:

```http
POST /Sessions/Logout
```

Then clear local session material even if the network call fails.

### API keys

Emby supports API-key authentication, but VisionPlay should not use API keys for normal user playback because user identity, permissions, playstate, and library views matter.

## Server URL handling

Manual URL entry should be the first-class path.

Emby API docs describe access under:

```text
http[s]://hostname:port/emby/{apipath}
```

while endpoint references often show root-relative paths such as:

```text
/Users/AuthenticateByName
/System/Info/Public
```

VisionPlay must preserve a user-entered base path such as `/emby`; do not normalize all Emby servers to origin root. Also do not imply HTTPS-only: local Emby servers commonly use HTTP on port `8096`, while HTTPS is usually `8920` when enabled.

Relevant ports from Emby support docs:

- `8096` TCP: default HTTP
- `8920` TCP: HTTPS when enabled
- `7359` UDP: local-network discovery

Potential public info probe:

```http
GET /System/Info/Public
```

The docs conflict on whether this is truly unauthenticated. Verify live before relying on it for pre-login validation.

## Emby Connect

Emby Connect is optional and should come after manual server support. It is not Jellyfin Quick Connect parity.

High-level flow from Emby docs:

1. authenticate to `https://connect.emby.media/service/user/authenticate` with `X-Application`,
2. fetch linked servers from `/service/servers?userId=...`,
3. exchange per-server `AccessKey` via server `/Connect/Exchange`,
4. persist connect/server identity carefully per server.

Keep Connect tokens/access keys scoped by server id so VisionPlay never sends a token to the wrong server.

## Persistence planning

If/when Emby is implemented, persist in Keychain:

- Emby server base URL, including any base path,
- Emby access token,
- Emby server id,
- Emby user id,
- stable VisionPlay device id,
- optional future Emby Connect user token/access key, scoped by server id.

Do not persist passwords. On restore, distinguish invalid credentials from temporary network failures: `401`/`403` should trigger re-login, while unreachable server should keep the saved session and present an offline/unreachable state.

## Playback-info and stream resolution

Primary playback planning endpoint:

```http
POST /Items/{Id}/PlaybackInfo
```

Use POST rather than GET because VisionPlay needs to send playback constraints and a device profile-like body.

Important request fields include:

- `UserId`
- `MaxStreamingBitrate`
- `StartTimeTicks`
- `AudioStreamIndex`
- `SubtitleStreamIndex`
- `MediaSourceId`
- `DeviceProfile`
- `EnableDirectPlay`
- `EnableDirectStream`
- `EnableTranscoding`
- `AllowVideoStreamCopy`
- `AllowAudioStreamCopy`
- `AutoOpenLiveStream`
- `CurrentPlaySessionId`

Important response fields include:

- `PlaySessionId`
- `MediaSources[]`
- `SupportsDirectPlay`
- `SupportsDirectStream`
- `SupportsTranscoding`
- `DirectStreamUrl`
- `TranscodingUrl`
- `TranscodingSubProtocol`
- `TranscodingContainer`
- `RequiredHttpHeaders`
- `AddApiKeyToDirectStreamUrl`
- `LiveStreamId`
- `RequiresOpening`
- `RequiresClosing`

Prefer server-generated `TranscodingUrl` or `DirectStreamUrl` from `PlaybackInfo` when available. Construct direct stream URLs only as a fallback.

## Video and HLS URL shapes

Video stream endpoints documented by Emby include:

```http
GET /Videos/{Id}/stream
GET /Videos/{Id}/stream.{Container}
GET /Videos/{Id}/{StreamFileName}
```

HLS endpoints include:

```http
GET /Videos/{Id}/master.m3u8
GET /Videos/{Id}/main.m3u8
GET /Videos/{Id}/hls1/{PlaylistId}/{SegmentId}.{SegmentContainer}
```

Common query parameters include:

- `DeviceId`
- `Container`
- `Static`
- `StartTimeTicks`
- `VideoBitRate`
- `AudioBitRate`
- `AudioStreamIndex`
- `SubtitleStreamIndex`
- `MaxWidth`
- `MaxHeight`
- `VideoCodec`
- `AudioCodec`
- `MaxAudioChannels`
- `SubtitleMethod`

For AVFoundation, verify whether auth headers propagate to HLS child playlists and segments. If Emby requires header auth only on the master playlist, playback may appear to start and then fail on child resources. Token-bearing URLs may be necessary for HLS, but query-string tokens are more leak-prone and must be redacted from diagnostics/logs.

## Direct Play, Direct Stream, and Transcode

Emby support docs use the normal media-server meanings:

- Direct Play: original media can be used as-is.
- Direct Stream: container/package, audio, or subtitles may change, usually without video re-encode.
- Transcode: video is decoded/altered/re-encoded for compatibility, bitrate, or burn-in subtitles.

Do not equate `SupportsDirectPlay` with a local-file URL or with "no headers required." Emby may still serve compatible media through authenticated `/Videos/.../stream` URLs.

Treat Direct Stream as potentially server-active, especially when HLS/remuxing is involved.

## Progress and cleanup lifecycle

Emby exposes playback-state endpoints:

```http
POST /Sessions/Playing
POST /Sessions/Playing/Progress
POST /Sessions/Playing/Stopped
POST /Sessions/Playing/Ping?PlaySessionId=...
```

Use these for now-playing state, resume/progress, pause/unpause/track events, and final stopped position.

For server-side encoders, also call:

```http
DELETE /Videos/ActiveEncodings?DeviceId=...&PlaySessionId=...
```

Important invariant: `/Sessions/Playing/Stopped` is progress/session state. It should not be assumed to terminate active encoders. For HLS/transcode/direct-stream-remux sessions, call active-encoding cleanup when `PlaySessionId` exists and the chosen source used server-side encoding.

## Testing checklist before implementation can be called supported

Live Emby validation should cover:

- manual URL with root path and with `/emby` base path,
- HTTP `8096` and HTTPS `8920` when available,
- username/password auth and restore after app relaunch,
- token invalidation/re-login path,
- browse libraries, movies, shows, seasons, and episodes,
- Direct Play/static-compatible media,
- Direct Stream/remux media,
- HLS transcode media,
- HLS auth propagation to child playlists/segments,
- subtitle and audio stream selection,
- progress/resume reporting,
- `DELETE /Videos/ActiveEncodings` actually stopping server-side work,
- diagnostics redacting server URLs, tokens, usernames, titles, and query-string tokens.

## Current-doc promotion targets

When Emby work starts, update these current docs as behavior becomes implemented/proven:

- `docs/BACKENDS.md` — backend comparison and Emby-specific rules.
- `docs/PERSISTENCE.md` — Emby Keychain/session fields.
- `docs/PLAYBACK-ARCHITECTURE.md` — Emby playback-info/open/reopen/cleanup lifecycle.
- `docs/DOWNLOADS-OFFLINE.md` — only after offline download route is researched and proven.
- `docs/TESTING-STRATEGY.md` — live Emby gates.
- `docs/DEVELOPMENT.md` — easy-to-forget Emby auth/cleanup invariants after they are proven.

## Sources

- Emby REST API overview: https://dev.emby.media/doc/restapi/index.html
- User authentication: https://dev.emby.media/doc/restapi/User-Authentication.html
- `POST /Users/AuthenticateByName`: https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html
- API-key authentication: https://dev.emby.media/doc/restapi/API-Key-Authentication.html
- Emby Connect: https://dev.emby.media/doc/restapi/Emby-Connect.html
- System/public info: https://dev.emby.media/reference/RestAPI/SystemService.html
- Connectivity and ports: https://emby.media/support/articles/Connectivity.html
- `POST /Items/{Id}/PlaybackInfo`: https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html
- `GET /Items/{Id}/PlaybackInfo`: https://dev.emby.media/reference/RestAPI/MediaInfoService/getItemsByIdPlaybackinfo.html
- Video streaming endpoints: https://dev.emby.media/reference/RestAPI/VideoService.html
- `GET /Videos/{Id}/stream`: https://dev.emby.media/reference/RestAPI/VideoService/getVideosByIdStream.html
- HLS master playlist: https://dev.emby.media/reference/RestAPI/DynamicHlsService/getVideosByIdMasterM3u8.html
- Playback state endpoints: https://dev.emby.media/reference/RestAPI/PlaystateService.html
- Stop active encodings: https://dev.emby.media/reference/RestAPI/HlsSegmentService/deleteVideosActiveencodings.html
- Direct Play / Direct Stream / Transcoding: https://emby.media/support/articles/DirectPlay-Stream-Transcoding.html
- Transcoding support notes: https://emby.media/support/articles/Transcoding.html
