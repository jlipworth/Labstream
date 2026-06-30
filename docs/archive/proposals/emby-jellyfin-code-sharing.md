> **Archived:** Historical refactor/status note from an earlier app version. Do not treat this as an active implementation plan or current architecture source of truth; verify against current `PMSKit/Sources/PMSKit/MediaBrowser/`, `Jellyfin/`, and `Emby/` code before reusing any detail.

# Archived Jellyfin + Emby MediaBrowser sharing note

Status: archived. This is historical context from an earlier future-refactor/proposal lane, not an active plan and not the current architecture source of truth.

Scope at the time: PMSKit MediaBrowser/Jellyfin/Emby code and app-layer browse/music seams. Plex was explicitly out of scope.

## Historical snapshot: shared seams observed during cleanup

At the time this note was archived, the code had several targeted Jellyfin/Emby shared seams:

- **Low-level URL/auth/query helpers** in `PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserNetworking.swift`:
  - `MediaBrowserURL.normalizedServerURL` and `joinTrustedServerURL` preserve base paths and reject cross-origin absolute URLs.
  - `MediaBrowserAuth.headerValue` centralizes fragile quoting while each backend still passes its own scheme/parameter list.
  - `MediaBrowserLibraryFields`, `MediaBrowserLibraryQueryDialect`, and `MediaBrowserRequest` keep common browse request construction from drifting while preserving Jellyfin/Emby query-name/path differences.
- **Shared DTOs** in `PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserItemModels.swift`:
  - `MediaBrowserBaseItemDto<Flavor>` and related response/source/stream/chapter/user-data types are generic over `JellyfinFlavor` / `EmbyFlavor` so synthetic image/media URI schemes stay explicit.
  - Backend-facing typealiases preserve the familiar Jellyfin/Emby public names at call sites.
- **Shared playback/progress carriers and policies**:
  - `MediaBrowserPlaybackCarriers.swift` defines backend-neutral playback method/source/open-result structs for the app boundary.
  - `MediaBrowserPlaybackPolicy.swift` keeps pure quality/bitrate/active-encoding cleanup decisions shared.
  - `MediaBrowserPlaybackProgressPolicy.swift` keeps progress-event/tick policy shared.
  - Backend-specific services still build their native PlaybackInfo and cleanup requests.
- **Shared app-layer music seam**:
  - `MusicProvider` is the music UI abstraction for all backends.
  - `MediaBrowserMusicProvider` drives Jellyfin or Emby through `MediaBrowserMusicBrowsing`, backed by `JellyfinBrowseService` and `EmbyBrowseService`.
  - The Music tab, paged grids, album/artist/playlist details, search music routing, and queue actions are shared above the provider boundary.

## What remains intentionally backend-specific

Do not collapse these differences into hidden runtime `if backend == …` branches:

| Concern | Jellyfin | Emby |
| --- | --- | --- |
| Auth scheme prefix | `MediaBrowser ` | `Emby ` |
| Token header | token in `Authorization` | `Authorization` plus `X-Emby-Token` |
| `UserId` in auth header | not included | included when known |
| Browse user-view/items paths | `/UserViews`, `/Items` | `/Users/{UserId}/Views`, `/Users/{UserId}/Items` |
| Query names | lower camel case (`userId`, `parentId`, …) | Pascal case (`UserId`, `ParentId`, …) |
| PlaybackInfo `UserId` | body | query and body |
| `AutoOpenLiveStream` | true in the Jellyfin lane | false in the Emby lane |
| HLS child-resource auth | header/proxy path as needed | server URL carries `api_key=`; no per-child Authorization injection |
| Direct-stream fallback auth | lane-specific headers | `X-Emby-Token` when `AddApiKeyToDirectStreamUrl == false` |
| Base path | normalized/preserved | normalized/preserved; Emby Connect API base appends `/emby` when needed |
| Trick-play | Jellyfin tile-sheet provider | Emby chapter-image provider |

## Historical abstraction rule

The accepted seam in this archived note was **MediaBrowser-family**, not "backend".

Good shared code:

- pure URL/auth/query helpers with explicit dialect/flavor input;
- generic DTOs where fields are a true superset and backend-specific synthetic references remain typed;
- pure policy objects and app-boundary carriers;
- app-layer seams where both services already expose the same semantic operations.

Bad shared code:

- a Plex/Jellyfin/Emby mega-protocol;
- hiding Emby/Jellyfin wire differences behind runtime backend switches in hot paths;
- changing Jellyfin request bytes as a side effect of making Emby cleaner;
- sending Emby's accepted-but-noncanonical `MediaBrowser` auth shape just because a live server tolerated it once.

## Regression expectations for future sharing

Before moving more code into shared MediaBrowser helpers:

1. Add or update golden-request tests for the affected Jellyfin and Emby endpoints: method, URL/path/query, sorted headers, and body bytes.
2. Add or update decode tests for any DTO field migration.
3. Move the newer/lower-risk lane first when possible, then switch the other lane only after tests prove equivalent output.
4. Keep the backend-facing public functions/types unless there is a strong reason to force call-site churn.
5. If a new divergence appears, parameterize it loudly or leave that piece duplicated.

## Remaining candidate follow-ups

These may be worth revisiting only when duplication becomes a real maintenance cost:

- further common PlaybackInfo body/device-profile builders, if tests can prove request-byte equivalence after parameterization;
- additional progress/session request builders beyond the pure progress policy;
- more shared browse helpers for specialized library/search cases where the current `MediaBrowserRequest` dialect layer is not enough.

Archived recommendation at the time: any further extraction should happen only behind tests. Re-check current source and active docs before acting on this note.
