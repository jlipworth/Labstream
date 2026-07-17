# Architecture overview

Labstream is a SwiftUI media client for Plex, Jellyfin, and Emby. The app code in
`Labstream/` owns UI and most live orchestration; the local Swift package in `PMSKit/`
owns reusable request builders, wire models, and policies. Most PMSKit behavior is pure
and can be tested without an app process, simulator, Keychain, filesystem, or media
server; a small set of reusable infrastructure is intentionally effectful.

```mermaid
flowchart LR
  Entry[Platform App entry point] --> Services[AppServices]
  Services --> Model[AppModel]
  Services --> Auth[AuthManager]
  Services --> Downloads[DownloadManager]
  Services --> Music[MusicPlayerController]

  UI[SwiftUI UI] --> Model
  UI --> Auth
  UI --> Downloads
  UI --> Music
  UI --> Player[PlaybackController]

  Auth --> PMSKit[PMSKit requests, models, policies]
  Player --> PMSKit
  Downloads --> PMSKit
  Music --> PMSKit

  Player --> AV[AVFoundation]
  Downloads --> Store[DownloadStore]
  Downloads --> BG[BackgroundDownloadSession]
  Store --> Files[Application Support]
```

## Native targets and release trains

The repository contains three native application targets. Vision Pro and mobile are the
supported product paths; the native Mac target is a local-build development preview. All three share the
file-system-synchronized `Labstream/` source tree and select platform behavior with
Swift **conditional compilation**.

| Target / scheme | Entry point | Platform | Current marketing version |
| --- | --- | --- | --- |
| `Labstream` | `Labstream/App/Labstream.swift` | visionOS | 1.5.0 |
| `LabstreamMobile` | `Labstream/App/LabstreamMobile.swift` | iOS and iPadOS | 1.4.0 |
| `LabstreamMac` | `Labstream/App/LabstreamMac.swift` | native macOS, not Catalyst | 1.0.0 |

The three marketing versions are intentionally independent release trains. The Xcode
project is the source of truth for current version and deployment settings.

Platform-specific code uses `#if os(visionOS)`, `#if os(iOS)`, and
`#if os(macOS)`. Capability and build variants also use `#if canImport(...)`,
`#if targetEnvironment(simulator)`, and `#if DEBUG`. These are compile-time
conditions, not runtime feature flags. The densest shared-platform branches are in
`Labstream/Player/CustomPlayerChrome.swift`,
`Labstream/Player/CustomPlayerView.swift`, `Labstream/UI/RootView.swift`, and the
shared login/detail UI. Whole-platform adapters remain in small files where possible.

## App-lifetime composition

Every target guards the optional result of `AppServices.make()` in its `App` initializer
and has a `SecureStorageUnavailableView` fallback. The current factory returns a service
bundle even when the durable client identifier cannot be read by using a process-local
identifier for that launch; credentials themselves still fail closed. `AppServices`
constructs the same four long-lived services:

- `AppModel`: active backend and the three live server/session lanes.
- `AuthManager`: authentication, restore, backend switching, and Keychain writes.
- `DownloadManager`: the cross-backend offline queue and transfer orchestration.
- `MusicPlayerController`: the app-lifetime audio queue and player.

The platform `App` also owns `SessionBootstrap`, `CustomCinemaSessionStore`, and
`RealityTheaterSessionStore`. Keeping these objects above the main window matters on
visionOS: entering Cinema can dismiss the window, but the authenticated session and
active player must survive until the window is reopened.

`ContentView` is the launch gate. It registers system-entry routing, restores saved
sessions once, presents restore/login/browse UI, and starts download reconciliation.
`RootView` is the authenticated navigation shell and injects the app model, download
manager, and music player into the view environment.

## Session and backend model

`AppModel` keeps separate Plex, Jellyfin, and Emby session state. Switching the active
backend does not overwrite another backend's credentials. At launch,
`AuthManager.restoreSession()` runs under one generation-scoped authorization attempt,
restores the selected user-facing lane, and then hydrates saved inactive lanes so an
offline job can continue against its own backend while a different backend is active.
Login, Quick Connect/Connect, restore, and server selection cannot publish stale results
from an older authorization attempt. System-entry fallback restore uses
`restoreSessionIfNoAuthorizationInProgress()` rather than taking authority from a login the
user is completing.

Token-free identities serve two different purposes:

- a stable server/user key scopes persisted preferences such as library visibility;
- a revisioned browse-session key invalidates navigation, search, paging, and music
  queues after a backend, server, user, or authentication-session change.

Online navigation is session-scoped. The Offline library is deliberately
cross-backend: its records carry their backend identity and remain available when the
active browse backend changes.

## App/PMSKit boundary

The dominant boundary keeps app-lifecycle effects in the app target:

- SwiftUI observation, navigation, presentation, and target lifecycle;
- Keychain and UserDefaults access;
- live `URLSession` execution and background-session delegates;
- files and offline-index persistence;
- `AVPlayer`, audio sessions, Picture in Picture, Now Playing, and RealityKit;
- MetricKit, Spotlight, App Intents, and share/export UI.

PMSKit primarily owns behavior that can be expressed as input-to-output decisions:

- Plex, Jellyfin, and Emby request construction and response decoding;
- shared media and offline models;
- playback, download, retry, paging, routing, and redaction policies;
- state-machine decisions that can be exercised by `swift test`.

There are deliberate package-side exceptions. `PMSKit/Sources/PMSKit/MediaSession/`
owns the reusable, effectful loopback HLS proxy and upstream connection machinery used
by the player, and
`PMSKit/Sources/PMSKit/Security/CredentialArtifactStorage.swift` performs shared
protected-file writes.
These types keep framework effects behind narrow, injectable/testable APIs; they do not
move SwiftUI, AVPlayer ownership, background-session delegation, or app persistence into
the package.

The boundary is not a mandate to erase backend differences. Plex has native hub,
optimizer, and music behavior; Jellyfin and Emby share MediaBrowser-shaped providers
where their APIs genuinely align, while their authentication, playback, and download
details remain explicit.

## Browse, search, and music

- Pure Plex browse requests are built by `PlexBrowseRequest` in PMSKit (through the small
  app facade in `Labstream/Backend/PlexBrowseAPI.swift`). `PlexBrowseService` pins one
  immutable backend session, executes through the shared `PlexClient`, decodes responses,
  and is the app-facing browse boundary.
- Jellyfin and Emby retain concrete facades under `Labstream/Backend/Jellyfin/` and
  `Labstream/Backend/Emby/`, backed by `MediaBrowserBrowseCore` only for their genuinely
  shared browse execution/decode/map behavior.
- Paging and grouped search models in `Labstream/Backend/Paging/` and
  `Labstream/Backend/Search/` feed shared SwiftUI grids and rails.
- `MusicProvider` is the backend-neutral music boundary. Plex supplies richer native
  artist metadata; Jellyfin and Emby share `MediaBrowserMusicProvider`.
- `MusicPlayerController` survives navigation. Its queue is tied to the browse-session
  identity so stale media IDs are never resolved against a different server.

## Video playback and theater surfaces

`PlaybackController` owns one `AVPlayer` for one presentation. It supports three inputs
through the same lifecycle and chrome:

1. Plex streaming resolved by the controller's Plex path;
2. an already-negotiated Jellyfin or Emby remote stream with reopen/progress/cleanup
   callbacks;
3. a local downloaded file.

`CustomPlayerView` and `CustomPlayerChrome` are the only shipping video-player surface.
There is no selectable native `AVPlayerViewController` path. Platform coordinators add
iOS/iPadOS PiP, AirPlay, orientation, and Now Playing behavior or native Mac media-key
and presentation behavior; visionOS owns its player chrome directly.

The visionOS **Custom Cinema** immersive space is the user-visible app-owned Cinema
path and reuses the same controller and chrome. The separate RealityKit theater in
`Labstream/Theater/` is a hidden prototype: its scene and tuning model compile, but its
shipping and device-testing entry-point gates are currently false. Documentation and
UI should not present that prototype as a supported theater mode.

## Downloads and offline ownership

The download pipeline has four layers:

1. backend-specific `DownloadManager` extensions select a source and perform any Plex
   optimize, Jellyfin transcode/remux, or Emby Convert preparation;
2. `DownloadManager` owns queue policy, retries, storage limits, diagnostics, the
   observable Offline snapshot, and attempt-scoped work/cleanup coordination;
3. `BackgroundDownloadSession` owns background URLSession work and durable static
   byte-range recovery, with every adoptable task stamped by its exact download attempt;
4. `DownloadStore` owns the locked relative-path JSON index and transactional artifact
   state in Application Support. `DownloadArtifactLifecycleCoordinator` orders filesystem
   work with index persistence, while `DownloadCleanupIntentJournal` independently keeps
   credential-free server cleanup durable across deletion and process death.

Device builds use a background URLSession that can relaunch the app. Simulator builds
normally substitute a foreground session because the visionOS simulator background
daemon is unreliable. Both visionOS and non-visionOS currently use the closed-segment
static range train; the conditional in `StaticRangeTransferRegime` is a future escape
hatch, not a current platform difference.

## System integration and diagnostics

`SystemEntryRouter` bridges App Intents, Spotlight, and Cinema exit back into SwiftUI
navigation. System media identifiers are backend/server scoped, authoritative metadata
is refetched before navigation, and music is intentionally excluded from the current
system-video surface. Spotlight indexing is best-effort and index-as-you-browse rather
than a full-library crawl.

Structured app diagnostics are local, bounded, redacted, and opt-in. MetricKit is a
separate passive crash/hang channel: it keeps at most five redacted summaries, uploads
nothing, and includes them only in a user-generated feedback report. Debug performance
signposts compile to no-op implementations in Release.

## Documentation rule

Published docs describe current behavior. Investigation notes, migration plans,
historical issue details, and one-off validation logs belong in `docs/research/` or
`docs/archive/`, not the public navigation.
