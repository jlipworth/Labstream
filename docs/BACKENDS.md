# Backends

VisionPlay currently supports Plex and Jellyfin as selectable backends. Plex remains the default path for existing installs, but the app has real Jellyfin login, browse, playback, and download code.

## Comparison

| Area | Plex | Jellyfin |
| --- | --- | --- |
| Sign-in | Plex PIN OAuth via in-app web auth | Server URL + username/password login |
| Secrets | Plex account token, selected server token/resource | Jellyfin access token, user ID, server URL, server ID |
| Browse | `PlexClient` actor + PMSKit request builders | `JellyfinBrowseService` + PMSKit request builders |
| Shared model | PMS metadata mapped to `MediaItem` | Jellyfin DTOs mapped to `MediaItem` |
| Playback | Universal transcode/direct-stream HLS, `Generic` profile | Resolved stream URL + headers + reopener |
| Downloads | Direct original if locally playable; otherwise Plex optimizer | Direct local-playable original or static transcoded MP4 request |
| Progress | PMS timeline/scrobble endpoints | Jellyfin session/progress path where available |
| Cleanup | Explicit transcode stop endpoint | Stop active encoding/session where available |

## Abstraction rule

Avoid inventing a broad backend protocol until the duplicated shape is proven. Plex and Jellyfin differ in auth, stream resolution, header requirements, download semantics, and progress reporting. Keep shared code in pure helpers and model bridges; keep server-specific behavior explicit.

## Current asymmetry

Plex uses a shared `PlexClient` actor because most app surfaces talk to one selected PMS server with common headers and token behavior.

Jellyfin uses `JellyfinBrowseService` and per-call request builders because its feature surface is newer and still benefits from explicit call sites while parity is verified.
