# Jellyfin Backend Mode Design

**Issue:** #35 — Support Jellyfin as an alternate media server backend
**Worktree:** `.claude/worktrees/jellyfin-35`
**Approved approach:** A — Jellyfin-first mode with adapters, preserving Plex paths.

## Goal

Turn the current manual Jellyfin stream probe into a real, selectable Jellyfin backend mode that can answer the key product question: can VisionPlay become a stable Jellyfin client if Plex remains unreliable?

The first build-out should let a user choose Plex or Jellyfin, log in to Jellyfin with a server URL plus username/password, restore that Jellyfin session on launch, browse enough Jellyfin library content to reach a detail page, and play a Jellyfin item through the resolved-stream player seam already added on this branch.

## Non-goals for this slice

- Do not remove Plex or rewrite the whole app around generic backends yet.
- Do not refactor `MediaSessionProxy` into a generic proxy while the Plex proxy work is still moving.
- Do not implement Jellyfin Quick Connect yet.
- Do not implement Jellyfin downloads/offline sync yet.
- Do not promise parity with Plex music, home hubs, watch-state mutations, subtitles, skip markers, or Up Next in this slice.

## User-facing behavior

### Backend selection

The login screen should offer a clear backend choice:

- Plex
- Jellyfin

Plex remains the default for existing installs unless a Jellyfin session is explicitly selected/restored. A Settings control should show the active backend and allow signing out of that backend. The existing experimental manual Jellyfin stream test can stay temporarily, but it should no longer be the primary Jellyfin entry point once real login and browsing exist.

### Jellyfin login

When Jellyfin is selected, the login screen asks for:

- server URL, for example `https://jellyfin.example.com`
- username
- password

On submit:

1. Build a `JellyfinClientIdentity` from the existing stable `ClientIdentity`.
2. Call `POST /Users/AuthenticateByName`.
3. Persist the returned access token, user ID, server ID when present, and normalized server URL.
4. Mark the app as browse-ready for Jellyfin.

Passwords must never be persisted. Jellyfin access token and user ID must be stored in Keychain, not `UserDefaults`.

### Session restore

On launch, the app should restore whichever backend was last selected:

- Plex: existing restore path.
- Jellyfin: read Jellyfin server URL, access token, and user ID from Keychain; validate with a lightweight authenticated Jellyfin request before showing browse UI.

If Jellyfin restore fails with unauthorized/forbidden, clear only Jellyfin credentials and return to login with Jellyfin selected. If it fails due to network/server availability, show a recoverable login/restoring failure rather than silently falling back to Plex.

## Architecture

### App model

Add an active-backend concept to `AppModel` without disrupting existing Plex state:

```swift
enum MediaBackendKind: String, Codable, CaseIterable, Identifiable {
    case plex
    case jellyfin

    var id: String { rawValue }
}
```

`AppModel` should track:

- `activeBackend: MediaBackendKind`
- current Plex fields exactly as today: `token`, `serverToken`, `selectedServer`, `serverBaseURL`
- Jellyfin session fields: `jellyfinServerBaseURL`, `jellyfinAccessToken`, `jellyfinUserID`, `jellyfinServerID`

`isBrowseReady` becomes backend-aware:

- Plex ready when existing Plex fields are ready.
- Jellyfin ready when server URL, token, and user ID are set.

Existing callers should not need to know about all credentials directly; Jellyfin-specific browse calls should live in `VisionPlay/Backend/Jellyfin/JellyfinBrowseService.swift` so view files stay focused.

### Keychain

Extend `KeychainStore` with separate Jellyfin keys:

- selected backend
- Jellyfin server URL string
- Jellyfin access token
- Jellyfin user ID
- Jellyfin server ID

Keep the existing Plex token key unchanged for backwards compatibility.

### Authentication manager

`AuthManager` can remain the app-level session coordinator, but it should gain backend-aware methods rather than becoming a Jellyfin-only class:

- `selectBackend(_:)`
- `loginToJellyfin(server:username:password:)`
- `restoreSession()` routes by selected backend
- `signOut()` clears active backend credentials
- private `signOutPlex()` and `signOutJellyfin()` helpers

Plex PIN auth should remain untouched except for being selected only when `activeBackend == .plex`.

### Jellyfin API layer in PMSKit

Add small, tested PMSKit request/model files instead of pulling in the generated SDK:

- `JellyfinAuth.swift` already exists for auth header/login request.
- Add `JellyfinLibrary.swift` for:
  - `GET /UserViews?userId=...`
  - `GET /Items?userId=...&parentId=...&includeItemTypes=Movie,Episode,Series,Season&fields=Overview,Genres,MediaSources,People,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData&recursive=...`
  - `GET /Items/{id}?userId=...`
  - image URL helper for `/Items/{id}/Images/{type}`
- Keep the JSON models minimal and shaped around what the first UI needs.

### Model mapping

Map Jellyfin `BaseItemDto` into existing `MediaItem` so `DetailView` and the player can be reused.

Initial type mapping:

| Jellyfin `Type` | VisionPlay `MediaItem.type` |
|---|---|
| `Movie` | `movie` |
| `Series` | `show` |
| `Season` | `season` |
| `Episode` | `episode` |
| other | ignore for first video slice |

Initial field mapping:

- `Id` → `ratingKey`
- `Name` → `title`
- `Overview` → `summary`
- `ProductionYear` → `year`
- `RunTimeTicks / 10_000` → `duration` in ms
- `UserData.PlaybackPositionTicks / 10_000` → `viewOffset` in ms
- `ImageTags.Primary` present → synthetic image path like `jellyfin://item/{id}/Primary`
- `BackdropImageTags` present → synthetic image path like `jellyfin://item/{id}/Backdrop`
- `ParentId`, `SeriesId`, `SeriesName`, season/episode indexes → existing hierarchy fields where possible

The synthetic `jellyfin://` image paths let `PosterImage` route image loading by backend without forcing every caller to know image URL details.

### Browse UI routing

Do the smallest UI routing needed:

- `HomeView`: for Jellyfin, show a vertical “Jellyfin Libraries” list from `GET /UserViews`; each row navigates into that view’s items.
- `LibrariesView`: for Jellyfin, show the same user views list and item grids under a selected view, reusing existing poster cells where possible.
- `SearchView`: query Jellyfin `/Items` with `searchTerm`, recursive video item filtering, and render the same poster rail/result detail flow as Plex search.
- `MusicLibraryView`: show a clear disabled placeholder: “Jellyfin music is not in this slice.”

Avoid large visual rewrites. Put Jellyfin network calls and model mapping behind `JellyfinBrowseService`; views should only branch enough to choose Plex or Jellyfin data sources.

### Image loading

Update `PosterImage` so image loading is backend-aware:

- Plex path: unchanged `/photo/:/transcode` behavior.
- Jellyfin synthetic path: build direct Jellyfin image URL using server/token and fetch with MediaBrowser auth header.

This keeps existing poster/detail UI mostly reusable.

### Playback

Reuse the stream resolver already added:

1. DetailView play action detects `appModel.activeBackend`.
2. Plex path remains unchanged.
3. Jellyfin path calls `JellyfinPlayback.playbackInfoRequest(...)` with:
   - active server URL
   - access token
   - user ID
   - item ID
   - max bitrate converted from kbps to bps
   - start ticks derived from `MediaItem.viewOffset` when present
4. Decode `JellyfinPlaybackInfoResponse`.
5. Resolve stream URL.
6. Present `CustomPlayerView with PlaybackController(remoteStreamURL:item:identity:client:httpHeaders:)`.

Jellyfin active-encoding cleanup is part of this slice: when a Jellyfin remote-stream player stops or is dismissed, call `DELETE /Videos/ActiveEncodings` with the current device ID and `PlaySessionId`. Full Jellyfin progress reporting (`/Sessions/Playing`, `/Progress`, `/Stopped`) remains a follow-up because it is not required to prove login, browse, and basic playback.

## Error handling

- Jellyfin login:
  - invalid URL: inline form error
  - 401/403: “Invalid Jellyfin username or password.”
  - other non-2xx: include HTTP status
  - network failures: “Couldn’t reach Jellyfin server.”
- Restore:
  - unauthorized clears Jellyfin credentials
  - network errors surface a retryable failed state
- Browse:
  - empty libraries show `ContentUnavailableView`
  - unsupported item types are filtered, not fatal
- Playback:
  - PlaybackInfo non-2xx should surface in DetailView before presenting player
  - resolver errors should show a readable “Jellyfin could not provide a playable stream” message

## Testing strategy

Use TDD for all production code changes.

PMSKit tests:

- Jellyfin auth response decoding from `AuthenticateByName`.
- UserViews request URL/header shape.
- Items request URL/header/query shape.
- Items search URL/query shape.
- Item detail request URL/header/query shape.
- Mark played/unplayed request method/header shape.
- Original-file download request header shape; do not put `api_key` in Jellyfin download URLs.
- BaseItemDto → MediaItem mapping for movie, series, season, episode.
- Image URL helper/header behavior.

App tests are limited by current project structure, so compile/build verification covers SwiftUI wiring. Keep app logic small and push pure request/mapping behavior into PMSKit where it can be tested.

Verification commands:

```bash
swift test --package-path PMSKit
./scripts/ci-hygiene.sh
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
```

## Rollout and compatibility

- Existing Plex installs should still restore Plex by default unless the selected backend key says Jellyfin.
- Plex credentials and Jellyfin credentials must not overwrite each other.
- Plex browsing/playback/download behavior must remain unchanged when active backend is Plex.
- The branch stays separate from main until Jellyfin login + browse + play are verified on simulator and, ideally, against a real server.

## Open follow-ups after this slice

1. Jellyfin playback progress: `/Sessions/Playing`, `/Progress`, `/Stopped`.
2. Seek behavior validation: native AVPlayer seek vs Android-style re-POST PlaybackInfo with `StartTimeTicks`.
3. Jellyfin download validation: first-pass original-file downloads use `/Items/{id}/Download` with MediaBrowser auth headers, but this still needs live testing on representative media and a later quality/transcoded offline path decision.
4. Jellyfin music.
5. Optional Quick Connect login UX.

## Branch close-out status

As of the local Jellyfin worktree close-out, this branch has moved beyond the initial slice:

- UI parity work from `ui/35-jellyfin-parity` is merged into `backend/35-jellyfin-support`; the local UI parity worktree/branch was removed.
- Home now shows a library icon rail plus Plex-style media rails instead of only a folder listing.
- Detail actions now include Jellyfin playback, watched/unwatched, and first-pass downloads.
- Search now works for Jellyfin video items instead of showing the original placeholder.
- Settings no longer exposes the manual Jellyfin stream-test form; the real backend switch/login path is the primary surface.
- Jellyfin downloads intentionally use authenticated request headers, not `api_key` URL tokens.

Before merging this branch to main, run the verification commands above once no other agent is using the shared Xcode/simulator build state, then repeat real-server smoke tests for login, browse, search, play, seek/reopen, watched toggle, and download.
