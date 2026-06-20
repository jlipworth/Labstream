# 17 — Emby backend support research

Status: IMPLEMENTED (first slice) on `feature/emby-backend` and live-validated against a real Emby server. Sign-in (password), browse/DTO mapping, PlaybackInfo stream resolution, progress, and active-encoding cleanup are built as a parallel Emby lane (`PMSKit/Sources/PMSKit/Emby/*`, `VisionPlay/Backend/Emby/EmbyBrowseService.swift`) and verified by the opt-in `LiveEmbyProbe` test. Proven behavior has been promoted into [`docs/BACKENDS.md`](../BACKENDS.md), [`docs/PERSISTENCE.md`](../PERSISTENCE.md), [`docs/PLAYBACK-ARCHITECTURE.md`](../PLAYBACK-ARCHITECTURE.md), [`docs/TESTING-STRATEGY.md`](../TESTING-STRATEGY.md), and [`docs/DEVELOPMENT.md`](../DEVELOPMENT.md). Still unbuilt: Emby downloads/offline, Emby Connect, and LAN discovery — this doc remains the planning map for those. The open documentation ambiguities below were resolved by the live probe and are annotated inline as RESOLVED.

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

**RESOLVED (live):** The implemented `EmbyAuth` sends `Authorization: Emby UserId="…", Client, Device, DeviceId, Version, Token="…"` AND, on authenticated calls, the `X-Emby-Token: <token>` header. That combination was accepted live. Notably the live server also accepted the Jellyfin-style `MediaBrowser ` scheme (Jellyfin being an upstream fork of Emby), but the lane keeps its own canonical `Emby ` builder. This overlap motivates the future shared "emby-family" seam proposed in [`../proposals/emby-jellyfin-code-sharing.md`](../proposals/emby-jellyfin-code-sharing.md) — not implemented here.

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

**RESOLVED (live):** `GET /System/Info/Public` IS unauthenticated. `EmbyAuth.serverInfoRequest` sends it with no token and the `LiveEmbyProbe` returns HTTP 200 with a decodable `EmbyServerInfo` body. It is used for pre-login validation. The base-path-preservation rule above was also confirmed: the user-entered `/emby` base path is stored verbatim and joined onto relative stream URLs (`EmbyServerURL.normalized` does not strip it).

## Emby Connect

Emby Connect is an optional headset-friendly path layered on top of manual server support. It is
**not** Jellyfin Quick Connect parity — Jellyfin's server-local `/QuickConnect/*` endpoints do
**not** exist on Emby (they 404). Quick Connect was added to Jellyfin *after* the fork.

**Emby's headset-friendly "short code" login IS Emby Connect PIN sign-in** (the flow Emby's
own TV apps use), not Quick Connect. Tracked as GH #72. The username/password Connect path
(`/service/user/authenticate`) is a separate Connect method; the PIN flow below is the
convenience-login we want for visionOS.

### PIN flow — verified wire shape (RESEARCHED, GH #72)

Reverse-engineered from two official Emby clients — `MediaBrowser/Emby.ApiClient.Javascript`
(`connectionmanager.js`) and `MediaBrowser/Emby.ApiClient.Java` (`ConnectService` / model
POJOs) — which agree on every endpoint, param, and field name. **All six steps are now live-verified
end-to-end** (June 2026) against `connect.emby.media` plus a real Connect-linked Emby Server
4.9.x: created a PIN, confirmed it at `emby.media/pin.html`, exchanged it for a Connect token,
listed the linked server, exchanged the server's `AccessKey` for a local server token, and
confirmed that token authenticates a normal `GET /Users/{id}` call (HTTP 200).

Two hosts: the **cloud** account service `https://connect.emby.media/service/...` (steps 1–5)
and the **target Emby server** itself (step 6). `X-Application: <AppName>/<AppVersion>` is sent
on every cloud call (the JS/Java clients always send it; live probe shows create still returns
200 without it, but send it anyway).

| # | Purpose | Host | Method | Path | Auth header | Params | Response fields |
|---|---------|------|--------|------|-------------|--------|-----------------|
| 1 | Create PIN | cloud | POST | `/service/pin?deviceId=<id>` | `X-Application` | `deviceId` (query + form body) | `Id, Pin, DeviceId, IsExpired, IsConfirmed, AccessToken` (all nullable) |
| 2 | Poll status | cloud | GET | `/service/pin?deviceId=<id>&pin=<code>` | `X-Application` | `deviceId, pin` | `Id, Pin, DeviceId, IsExpired, IsConfirmed, AccessToken` |
| 3 | Exchange PIN → Connect token | cloud | POST | `/service/pin/authenticate` | `X-Application` | `deviceId, pin` (form body) | `UserId` (Connect user id), `AccessToken` (Connect token) |
| 4 | Get Connect user (optional) | cloud | GET | `/service/user?id=<connectUserId>` | `X-Application` + `X-Connect-UserToken` | `id` | Connect user profile (`Id`, …) |
| 5 | List linked servers | cloud | GET | `/service/servers?userId=<connectUserId>` | `X-Application` + `X-Connect-UserToken` | `userId` | array: `Id, SystemId, Name, Url, LocalAddress, AccessKey, UserType` |
| 6 | Per-server exchange | **target server** | GET | `<server>/emby/Connect/Exchange?format=json&ConnectUserId=<connectUserId>` | `X-Emby-Token: <AccessKey>` + identity header | `format=json, ConnectUserId` | `LocalUserId`, `AccessToken` (local server token) |

**Token chain:** PIN → (step 3) `ConnectAccessToken` + `ConnectUserId` → (step 5) per-server
`AccessKey` → (step 6) local server `AccessToken` + `LocalUserId`. The Connect token rides in
`X-Connect-UserToken`; the per-server `AccessKey` rides in `X-Emby-Token` for the Exchange call;
the returned local `AccessToken` then drives all normal Emby API calls to that server (reuse the
existing `EmbyAuth.applyAuth` path).

Live-probe findings (cloud, steps 1–2):
- Create returns `AccessToken: null` and `Id: null`; once the record persists, poll returns the
  populated `Id` and `AccessToken: "none"` (the **string** `"none"`, not null) until confirmed.
- **Wrong/expired/unknown PIN → bare HTTP 404, no body.** So poll error handling has two stop
  conditions: a 200 body with `IsExpired: true`, *and* a 404 (gone/mismatch). `IsConfirmed: true`
  is the success signal — then proceed to step 3.
- Poll cadence: the client libraries don't encode an interval; Emby's Roku client polls every
  **5s** repeating. Use ~5s; rely on `IsExpired`/404 for the stop condition, not a local timer.

Live findings, steps 3–6 (real Connect-linked server):
- The **confirmed poll response already carries the Connect `AccessToken`** (identical to what
  step 3 returns) — but step 3 (`/service/pin/authenticate`) is still needed because it returns
  the `UserId` (ConnectUserId), which the poll does not. Response of step 3 is exactly
  `{UserId, AccessToken}`.
- `GET /service/user?id=` returns `{Id, Name, Email, IsActive}`.
- The `/service/servers` array item carries one field the client source didn't surface:
  **`SupporterKey`** (empty string when none). Full observed shape:
  `{Id, Url, Name, SystemId, AccessKey, LocalAddress, UserType, SupporterKey}`, with
  `UserType: "Linked"` for the account owner. `Url` is the WAN address, `LocalAddress` the LAN
  `http://<ip>:8096`.
- Step 6 succeeded against the **WAN `Url`** with just `X-Emby-Token: <AccessKey>` + our existing
  `Emby …` identity `Authorization` header — the discrete `X-Emby-Client*` headers were **not**
  required on 4.9.x. Response is exactly `{LocalUserId, AccessToken}`.
- The exchanged local `AccessToken` authenticates normal calls. The `/Users/{LocalUserId}` object
  includes `ConnectUserName` and `ConnectLinkType` — usable to surface "signed in via Emby
  Connect as <name>" in the UI.

Implementation gotchas:
- POST bodies (steps 1, 3) are `application/x-www-form-urlencoded` (`deviceId`, `pin`). The Java
  client also appends `deviceId` to the query on create — harmless to mirror.
- Header alias: the JS client uses `X-Emby-Token` for step 6, the Java client uses the older
  `X-MediaBrowser-Token` — Emby accepts both; prefer `X-Emby-Token` (matches our existing lane).
- Server-list mapping: `AccessKey` → per-server exchange token; `Url` → remote/WAN address;
  `LocalAddress` → LAN; `SystemId` → the server's stable id; `Id` → cloud-side connect-server id.
  (The JS client has an upstream typo `i.LocalAddres` that drops `LocalAddress`; read the correct
  field name.)
- Step 6 is version-gated in the clients: on Emby ≥ 4.4.0.21 the identity goes as discrete
  `X-Emby-Client` / `X-Emby-Device-Name` / `X-Emby-Device-Id` / `X-Emby-Client-Version` headers;
  older servers use the single `X-Emby-Authorization`/`MediaBrowser …` header. Our targets are
  modern (4.9.x), so the discrete headers (or our existing `Emby …` identity header) apply.

Keep Connect tokens/access keys scoped by server id so VisionPlay never sends a token to the
wrong server. Never log the Connect token, per-server `AccessKey`, or the exchanged local token;
never persist the raw account password (the PIN flow never sees it).

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

**RESOLVED (live):** The server-generated `TranscodingUrl`/HLS URL already carries the token as an `api_key=` query value, so AVPlayer's child playlists and segments inherit auth from the URL — VisionPlay does NOT inject a per-child `Authorization` header. This sidesteps the header-only-on-master failure mode entirely. The trade-off is exactly the leak risk noted: `api_key`/`X-Emby-Token` must be redacted from every logged URL/header (the probe and `live-emby-probe.sh` do this; see the DEVELOPMENT.md invariant). For the direct-stream fallback where the server does NOT add the key to the URL (`AddApiKeyToDirectStreamUrl == false`), the token is attached via the `X-Emby-Token` header instead.

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

Promotion status as of the first implemented slice:

- `docs/BACKENDS.md` — DONE: Emby promoted to a supported column with auth/stream/cleanup specifics.
- `docs/PERSISTENCE.md` — DONE: Emby Keychain/session fields and restore semantics.
- `docs/PLAYBACK-ARCHITECTURE.md` — DONE: implemented playback-info/stream/progress/cleanup lifecycle.
- `docs/DOWNLOADS-OFFLINE.md` — NOT DONE: Emby offline/download route is not implemented.
- `docs/TESTING-STRATEGY.md` — DONE: `LiveEmbyProbe` gate + `scripts/live-emby-probe.sh`; remaining device-only gates listed.
- `docs/DEVELOPMENT.md` — DONE: `Stopped` != encoder stop, `api_key` redaction, `Emby ` scheme invariants.

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
