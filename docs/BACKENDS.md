# Backends

VisionPlay currently supports Plex and Jellyfin as selectable backends. Plex remains the default path for existing installs, but the app has real Jellyfin login, browse, playback, and download code. Emby support is tracked as planned research, not implemented behavior; see [`research/17-emby-backend-support.md`](research/17-emby-backend-support.md).

## Comparison

| Area | Plex | Jellyfin | Emby status |
| --- | --- | --- | --- |
| Sign-in | Plex PIN OAuth via in-app web auth | Server URL + username/password login | Planned: manual server URL + username/password first; Emby Connect later |
| Secrets | Plex account token, selected server token/resource | Jellyfin access token, user ID, server URL, server ID | Planned: Emby access token, user ID, server URL/base path, server ID, stable device ID |
| Browse | `PlexClient` actor + PMSKit request builders | `JellyfinBrowseService` + PMSKit request builders | Planned: explicit Emby request/model lane before any broad abstraction |
| Shared model | PMS metadata mapped to `MediaItem` | Jellyfin DTOs mapped to `MediaItem` | Planned: map Emby DTOs into `MediaItem` where useful |
| Playback | Universal transcode/direct-stream HLS, `Generic` profile | Resolved stream URL + headers + reopener | Researched: `PlaybackInfo`, `DirectStreamUrl`/`TranscodingUrl`, required headers, progress, active-encoding cleanup |
| Downloads | Direct original if locally playable; otherwise Plex optimizer | Direct local-playable original or static transcoded MP4 request | Not researched/proven enough to document as a route yet |
| Progress | PMS timeline/scrobble endpoints | Jellyfin session/progress path where available | Researched: `/Sessions/Playing`, `/Progress`, `/Stopped`, `/Ping` |
| Cleanup | Explicit transcode stop endpoint | Stop active encoding/session where available | Researched: `DELETE /Videos/ActiveEncodings?DeviceId=&PlaySessionId=`; must be live-validated |

## Abstraction rule

Avoid inventing a broad backend protocol until the duplicated shape is proven. Plex, Jellyfin, and planned Emby differ in auth, stream resolution, header requirements, download semantics, and progress reporting. Keep shared code in pure helpers and model bridges; keep server-specific behavior explicit.

## Current asymmetry

Plex uses a shared `PlexClient` actor because most app surfaces talk to one selected PMS server with common headers and token behavior.

Jellyfin uses `JellyfinBrowseService` and per-call request builders because its feature surface is newer and still benefits from explicit call sites while parity is verified.

## Emby planning rule

Emby is a docs/research item until a branch implements and live-validates it. Do not present Emby as supported in README/user-facing docs yet. Use the research doc to seed future PMSKit request builders and tests, then promote only proven behavior back into this file.
