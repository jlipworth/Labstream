# Backends

VisionPlay supports Plex, Jellyfin, and Emby as selectable backends. Plex remains the default path for existing installs, but the app has real Jellyfin and Emby login, browse, playback, and download lanes. Emby playback wire shape was live-validated against a real Emby server; Emby download request paths and live probes exist, while headset/offline validation remains more limited than Plex. The original planning map lives in [`research/17-emby-backend-support.md`](https://github.com/jlipworth/VisionPlay/blob/main/docs/archive/research/17-emby-backend-support.md).

## Comparison

| Area | Plex | Jellyfin | Emby |
| --- | --- | --- | --- |
| Sign-in | Plex PIN OAuth via in-app web auth | Server URL + username/password login | Emby Connect PIN sign-in (`emby.media/pin.html`) is the primary path; manual server URL + username/password (`POST /Users/AuthenticateByName`) remains the fallback. Emby does **not** have Jellyfin Quick Connect |
| Auth header | `X-Plex-Token` family | `Authorization: MediaBrowser …` | `Authorization: Emby UserId="…", Client, Device, DeviceId, Version, Token="…"` (scheme is `Emby `, not `MediaBrowser `) **plus** `X-Emby-Token: <token>` on authenticated calls |
| Secrets | Plex account token, selected server token/resource | Jellyfin access token, user ID, server URL, server ID | Emby local server access token, user ID, server URL (base path preserved), server ID; stable device id from `ClientIdentity`. Emby Connect tokens/access keys stay in memory only during PIN sign-in and are not persisted |
| Browse | `PlexClient` actor + PMSKit request builders | `JellyfinBrowseService` + PMSKit request builders | `EmbyBrowseService` + `EmbyLibrary` request builders — an explicit parallel lane, not a shared abstraction |
| Shared model | PMS metadata mapped to `MediaItem` | Jellyfin DTOs mapped to `MediaItem` | `EmbyBaseItemDto` mapped to `MediaItem` (own decoder lane) |
| Playback | Universal transcode/direct-stream HLS, `Generic` profile | Resolved stream URL + headers + reopener | `POST /Items/{Id}/PlaybackInfo` → `resolveStream` prefers server-generated `TranscodingUrl`, then `DirectStreamUrl`, then synthesized `stream.{container}`; relative URLs joined onto the server base path |
| Stream auth | `X-Plex-Token` in URL | Header / proxy as needed | Server-generated HLS URL carries the token as `api_key=` in the query, so AVPlayer's child playlists/segments inherit auth — no per-child `Authorization` injected. Direct-stream falls back to `X-Emby-Token` header when `AddApiKeyToDirectStreamUrl` is false |
| Downloads | Direct original if locally playable; otherwise Plex optimizer / rendered static part | Direct local-playable original or negotiated static/remux/transcode output | Download-time `PlaybackInfo`; direct static original, existing/prepared static versions, compatible remux where safe, or convert-then-static for non-direct-play items |
| Progress | PMS timeline/scrobble endpoints | Jellyfin session/progress path where available | `POST /Sessions/Playing`, `/Sessions/Playing/Progress`, `/Sessions/Playing/Stopped`, `/Sessions/Playing/Ping` |
| Cleanup | Explicit transcode stop endpoint | Stop active encoding/session where available | `DELETE /Videos/ActiveEncodings?DeviceId=&PlaySessionId=`, called when the resolved source uses server-side encoding (`usesServerEncoding`) — **separate from `Stopped`** |

## Abstraction rule

Avoid inventing a broad backend protocol until the duplicated shape is proven. Plex, Jellyfin, and Emby differ in auth, stream resolution, header requirements, download semantics, and progress reporting. Keep shared code in pure helpers and model bridges; keep server-specific behavior explicit. The Emby lane is deliberately parallel to Jellyfin even though their wire shapes overlap heavily — a future shared "emby-family" seam is proposed (not yet built) in [`proposals/emby-jellyfin-code-sharing.md`](https://github.com/jlipworth/VisionPlay/blob/main/docs/proposals/emby-jellyfin-code-sharing.md).

## Current asymmetry

Plex uses a shared `PlexClient` actor because most app surfaces talk to one selected PMS server with common headers and token behavior.

Jellyfin uses `JellyfinBrowseService` and per-call request builders because its feature surface is newer and still benefits from explicit call sites while parity is verified.

Emby uses `EmbyBrowseService` and the `EmbyLibrary`/`EmbyPlayback`/`EmbyAuth` request builders for the same reason. It mirrors the Jellyfin lane intentionally without sharing code yet, so the two lanes can diverge where the wire shapes actually differ (auth scheme, `X-Emby-Token`, `api_key` HLS auth, `AutoOpenLiveStream:false`, base-path preservation).

## Emby promotion rule

Only behavior that is implemented AND live-validated against a real Emby server is documented here as supported. Emby Connect PIN request/exchange shape is implemented and live-verified, but the in-headset PIN UX still needs the checklist smoke pass before calling it user-validated.

Emby downloads/offline are implemented but still have narrower headset/off-head validation than Plex. Do not describe every Emby download lane as headset-proven until the manual/device checklist catches up. LAN discovery remains unimplemented. Keep [`research/17-emby-backend-support.md`](https://github.com/jlipworth/VisionPlay/blob/main/docs/archive/research/17-emby-backend-support.md) as historical planning context, not current capability truth.
