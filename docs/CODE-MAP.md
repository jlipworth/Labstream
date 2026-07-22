# Code map

Use this as the current “where do I change X?” guide. App lifecycle, UI, and most live
orchestration live in `Labstream/`; reusable requests, models, and policies live in
`PMSKit/`. PMSKit is mostly pure, with narrow effectful infrastructure such as its
loopback media-session proxy and protected credential-artifact writer.

The directory names below are the stable first stop. Use symbol search and the ownership
tables in the subsystem pages for current file-level detail; a duplicated per-file diagram
would become stale as implementations move.

## App shell and lifecycle

- `Labstream/Shared/App/AppRuntime.swift` is the shared composition root for app-lifetime
  `AppModel`, `AuthManager`, `MusicPlayerController`, `SessionBootstrap`,
  `LibraryCatalogRepository`, `MetadataRepository`, and `ArtworkPipeline` instances. It also owns
  the real `DownloadManager` on download-capable products; tvOS has no download field or
  construction path.
- `Labstream/Platforms/visionOS/App/Labstream.swift` is the visionOS entry point. It declares the main window,
  declares Custom Cinema, and owns the live app-lifetime `WatchTogetherCoordinator` shared by
  the window and Cinema.
- `Labstream/Platforms/Mobile/App/LabstreamMobile.swift` is the universal iPhone/iPad entry point.
- `Labstream/Platforms/macOS/App/LabstreamMac.swift` is the native macOS entry point and declares the
  unique reusable main window, singleton Mac Settings scene, deterministic window reactivation,
  and menu commands.
- `Labstream/Shared/App/ContentView.swift` registers system routing, runs the one-time restore,
  and switches between restore, login, and browse states.
- `Labstream/Capabilities/Downloads/App/AppDelegate.swift` bridges iOS/visionOS background URLSession relaunch
  events; `MacAppDelegate.swift` owns the small native Mac lifecycle adapter.
- `Labstream/Shared/App/PlatformClientIdentity.swift` maps the target to its Plex client/device
  identity.

Every app target owns `Labstream/Shared/` plus exactly its matching `Labstream/Platforms/`
root. Vision Pro, mobile, and Mac also own `Labstream/Capabilities/Downloads/`; tvOS does not.
Use inline conditional compilation only where a genuinely shared file needs framework or
presentation variation. Do not create duplicate backend or policy implementations merely to
vary presentation.

## Session state, authentication, and secrets

- `Labstream/Shared/App/AppModel.swift` owns live, separate Plex/Jellyfin/Emby server and
  credential lanes, the active backend, token-free UI session identities, exact opaque browse
  authorities, immutable authenticated browse contexts, and the shared `PlexClient`.
- `Labstream/Shared/Auth/AuthManager.swift` owns sign-in, restore, server selection, backend
  switching, and sign-out. It covers Plex PIN auth, Jellyfin credentials/Quick Connect,
  Emby credentials/Connect PIN, selected-lane-first restore, and demand-driven download hydration.
- `Labstream/Shared/Auth/EmbyConnectAuthFlow.swift` privately owns pending Emby Connect secrets,
  exact server-selection state, backend exchange, and session commit. It never owns a polling task
  or authorization generation; `AuthManager` fences every follow-up through the global authority.
- `Labstream/Shared/Auth/AuthAttemptAuthority.swift` owns the one global authorization generation
  used to reject cancellation and stale publication across all backend operations.
- `Labstream/Shared/Auth/AuthorizationPollingCoordinator.swift` owns the single live Plex PIN,
  Jellyfin Quick Connect, or Emby Connect polling task plus its exact attempt/PIN metadata. Its
  narrow exact-owner finish/cancel API prevents stale poll cleanup from clearing a replacement.
- `Labstream/Shared/Auth/KeychainStore.swift` stores secrets and the stable client identifier.
  Do not put tokens in UserDefaults, diagnostics, URLs that do not require them, or
  Codable profile indexes.
- `Labstream/Shared/Auth/WebAuthSession.swift` is the cross-platform web-auth presentation
  adapter.
- `PMSKit/Sources/PMSKit/SessionIdentity.swift` and
  `PMSKit/Sources/PMSKit/MediaBackendSwitch.swift` contain the corresponding pure
  identity and switch decisions.

Downloads call `AppModel.backendSession(for:)` so each row uses its own backend lane,
not necessarily the backend currently visible in the UI.

## Browse, paging, search, and artwork

- `PMSKit/Sources/PMSKit/Models/PlexBrowseRequest.swift` contains pure Plex browse request
  builders; `Labstream/Shared/Backend/PlexBrowseAPI.swift` is their source-compatible app facade.
  `Labstream/Shared/Backend/PlexBrowseService.swift` pins one immutable Plex session and owns
  execution. Its `PlexBrowseResponseExecutor` moves JSON decoding and normalized-result mapping off
  the main actor while preserving the existing MainActor transport callback and typed errors.
- `Labstream/Shared/Backend/Jellyfin/JellyfinBrowseService.swift` and
  `Labstream/Shared/Backend/Emby/EmbyBrowseService.swift` are the live MediaBrowser browse
  facades. They snapshot MainActor session state into the Sendable browse-only
  `Labstream/Shared/Backend/MediaBrowserBrowseCore.swift`, which performs transport, decode, and
  DTO mapping off the main actor; playback and downloads stay outside it.
- `Labstream/Shared/Backend/Paging/` owns backend-neutral paging sources/models and the
  Plex/Jellyfin/Emby grid and rail adapters. Sparse library pages join one model-owned task flight
  per page rather than polling or issuing duplicate fetches. Movie-version grids retain stable
  first-seen groups and apply only each page's changed dense projection positions instead of
  re-collapsing all earlier pages. `PlaylistPagingModel` is deliberately positional: it pages long
  playlists while retaining duplicates, server order, retry, cancellation, clamped-page, and
  exact-authority semantics. `RailPagingModel`,
  `RailPagingSource`, and `RailViewAllDestination` power paged Home “View All” destinations.
- `Labstream/Shared/Backend/BoundedAsyncMap.swift` provides ordered fail-fast and
  partial-result fan-out. MediaBrowser library search and video/music alphabet probes cap their
  active requests at four while preserving the pre-existing order and failure contracts.
- `Labstream/Shared/Backend/LibraryCatalogLoader.swift` normalizes one native Plex section or
  Jellyfin/Emby view enumeration into ordered descriptors. The app-lifetime
  `LibraryCatalogRepository` shares exact-authority values and in-flight work across Libraries,
  MediaBrowser Home, Search, Music, the Mac sidebar, visibility editing, system entries, and Watch
  Together; force refresh, failure eviction, and stale-work fencing remain repository concerns,
  while per-surface query, visibility, ordering, and destination policy stay out.
- `Labstream/Shared/Backend/MetadataRepository.swift` owns exact backend/opaque-authority/item
  metadata flights, ten-second fresh display reuse, bounded stale-while-revalidate through sixty
  seconds, watched-state presentation patches, and provenance-based action admission.
  `DetailMetadataLoader.swift` and `DetailPlaybackLauncher.swift` consume that boundary: an exact
  fresh native Detail result can authorize immediate Play without a second read, while reused,
  stale, patched, expired, or superseded values require a native read.
- `PMSKit/Sources/PMSKit/Search/SearchResults.swift` owns the pure grouped,
  deduplicated, library-aware search presentation model; `Labstream/Shared/UI/SearchView.swift`
  renders its backend-neutral sections and routes standard versus music results.
- `Labstream/Shared/UI/HomeView.swift` uses Plex native hubs or
  `Labstream/Shared/UI/MediaBrowserHomeProvider.swift` for shared Jellyfin/Emby Home rails.
  `MediaBrowserHomeRailPlan.swift` assigns duplicate-safe canonical rail keys and reduces
  authority/attempt-fenced results. The provider publishes successful rails progressively under a
  single four-request ceiling and runs one failed-key-only retry while preserving successful and
  empty-success rails; only a complete, non-degraded result pins Home's loaded identity. Plex
  remains on native `/hubs`.
  `HomeRailArtworkPolicy` classifies synthetic Primary artwork as portrait and Thumb/Backdrop as
  landscape so Home request dimensions match the selected source instead of reshaping it.
- `Labstream/Shared/UI/LibraryGridView.swift` owns library roots and the shared sparse grid;
  `LibraryAlphabetRail.swift` owns the A–Z interaction.
- `Labstream/Shared/UI/ContainerBrowserView.swift` handles show/season child navigation and
  normalizes duplicate visible episode rows.
- `Labstream/Shared/UI/SearchView.swift` owns the shared search surface and music-result queue
  actions.
- `Labstream/Shared/UI/MediaArtwork.swift` resolves backend-authenticated, exact-authority artwork
  descriptors whose task/debug/reflection identity contains no request credentials. The
  app-lifetime actor-owned `ArtworkPipeline` executes remote and local requests with exact in-flight
  joining, independent waiter cancellation, canonical-origin priority admission, ephemeral
  nonpersistent remote transport, ImageIO downsampling/eager decode, and bounded
  compressed/decoded/negative caches. `PosterImage`, music/video system Now Playing,
  `AVPlayerItem` external and visionOS scoped metadata, offline row thumbnails, and offline player
  artwork consume it. Their success/failure callbacks publish only while the exact descriptor,
  pipeline instance, and owning view/playback generation remain current.
  `Labstream/Shared/UI/OfflineArtworkSource.swift` turns persisted row ownership plus
  `posterGeneration` into an opaque local authority, including same-path replacements.
  `SettingsView` clears the one pipeline, and `ArtworkShimmerClock.swift` owns one app-lifetime,
  reference-counted ticker for visible placeholders in the root UI and visionOS Custom Cinema
  ImmersiveSpace, with a static Reduce Motion path. Shared image
  values use the immutable CGImage-backed `Labstream/Shared/Platform/DecodedImage.swift`; native
  images are created only at framework bridges.

  `RequestBackedChapterImage` remains outside the pipeline because AVKit hosts the chapter tab in
  an independent environment without an injected pixel contract. BIF and sprite-sheet providers,
  Emby generated per-position frames, Emby online/offline chapter fallback, and the player nearest-
  frame cache remain provider-scoped time-indexed exceptions rather than `ArtworkPipeline`
  consumers.
  Authenticated requests use the nonpersistent side-asset transport, and their leaf caches are
  memory-only and bounded by byte cost plus entry count. Sprite sheets and final scrub previews cross
  the eager off-main `DecodedImage` boundary before cache publication; BIF indexes retain/map one
  backing payload and normal seek lookup copies only a selected frame (`frames` remains an explicit,
  source-compatible materializing accessor). Largest-real-BIF and tile-sheet peak-RSS validation
  remains a Phase 5 measurement gate. Using `DecodedImage` there is not pipeline adoption. Downloaded image-payload
  validation remains in the Wave 4 side-asset work.

Request/DTO implementations live under `PMSKit/Sources/PMSKit/Auth/`,
`PMSKit/Sources/PMSKit/Jellyfin/`, `PMSKit/Sources/PMSKit/Emby/`,
`PMSKit/Sources/PMSKit/MediaBrowser/`, and `PMSKit/Sources/PMSKit/Models/`, plus the
root Plex request files such as `PlexRequest.swift` and `PlexPhotoTranscode.swift`.

## Root navigation and shared UI

- `Labstream/Shared/UI/RootView.swift` is the common authenticated composition wrapper. It installs
  shared repositories/services and connects browse-session, music, system-entry, and Cinema-return
  events to `RootNavigationCoordinator.swift`.
- `Labstream/Shared/UI/RootNavigationCoordinator.swift` owns destination selection, online/music
  paths, Search return/focus transitions, exact-session system-entry routing, and the offline Cinema
  return focus key. `BrowseNavigationStack.swift` is the repeated session-keyed stack/push boundary.
- `Labstream/Platforms/visionOS/UI/VisionRootShell.swift`,
  `Labstream/Platforms/Mobile/UI/MobileRootShell.swift`,
  `Labstream/Platforms/macOS/UI/MacRootShell.swift`, and
  `Labstream/Platforms/tvOS/UI/TVRootShell.swift` independently own the native vision tab/ornament,
  adaptive iPhone/iPad, Mac split-view/player, and focus-driven TV presentations respectively.
- `Labstream/Shared/UI/LoginView.swift`, `BackendSignInComponents.swift`,
  `LoginChromeComponents.swift`, and `PairingCodeView.swift` own shared backend login UI.
- `Labstream/Shared/UI/DetailView.swift` owns item-detail presentation state. Extracted backend
  effect seams are in `DetailMetadataLoader.swift`, `DetailWatchedUpdater.swift`, and
  `DetailPlaybackLauncher.swift`.
- `Labstream/Capabilities/Downloads/UI/DownloadOptionsSheet.swift` owns download intent/version selection.
- `Labstream/Shared/UI/SettingsView.swift` owns backend/server status, preferences, storage,
  library visibility, diagnostics export, and About information.
- `Labstream/Shared/UI/DesignSystem.swift` contains shared visual constants and modifiers.

Online navigation paths are scoped to `AppModel.activeBrowseSessionKey` and reset when
that session changes. Offline navigation is intentionally not reset because saved items
are backend-scoped and cross-backend.

## Video playback

- `Labstream/Shared/Player/PlaybackController.swift` owns one active `AVPlayer` session and the
  shared item-observation, transport, diagnostics, seek, chapter, and chrome-facing state for
  Plex streams, negotiated Jellyfin/Emby streams, and local files. Source negotiation,
  reopen/progress callbacks, track behavior, retry mechanics, and server cleanup remain
  lane-specific.
- `Labstream/Shared/Player/CustomPlayerView.swift` is the shipping windowed player presenter and
  hosts an `AVPlayerLayer` plus `CustomPlayerChrome`; `Labstream/Platforms/visionOS/Player/CustomCinemaMode.swift`
  owns the separate immersive presenter for the same live controller.
- `Labstream/Shared/Player/CustomPlayerChrome.swift` owns the shared transport/menu/scrubber UI
  and contains the largest concentration of platform conditional compilation.
- `Labstream/Shared/UI/DetailPlaybackLauncher.swift` negotiates Jellyfin/Emby playback and
  supplies remote reopen, progress, and encoding-cleanup callbacks to the controller.
- `Labstream/Shared/Player/TimelineReporter.swift` serializes/coalesces Plex timeline and
  Jellyfin/Emby playback-progress traffic.
- `Labstream/Shared/Player/PlaybackDiagnostics.swift`,
  `PlaybackController+Diagnostics.swift`, `PlaybackHDRProbe.swift`, and
  `StatsForNerdsView.swift` own runtime diagnostics surfaces.
- `Labstream/Shared/Player/TrickPlayThumbnailProviders.swift` owns remote and local Plex BIF,
  Jellyfin tile, and Emby chapter thumbnail providers; `TrickPlayCostBoundedLRU.swift` owns their
  shared byte-and-entry cache bound.
- `Labstream/Shared/Player/AudioSessionCoordinator.swift` owns non-Mac audio-session policy.
- `Labstream/Platforms/Mobile/Player/MobilePlayerSystemCoordinator.swift` and
  `MobilePlayerOrientationCoordinator.swift` add iOS/iPadOS PiP, AirPlay, system media,
  and orientation behavior.
- `Labstream/Platforms/macOS/Player/MacPlayerSystemCoordinator.swift` and
  `MacPlayerPresentation.swift` add native Mac system-media and presentation behavior.
- `Labstream/Shared/Player/VideoNowPlayingCore.swift` is the iOS/iPadOS and macOS video adapter
  for the shared process-wide `SystemMediaSessionCoordinator` lease.
- `Labstream/Platforms/visionOS/Player/VideoNowPlayingCoordinator.swift` is the separate visionOS video
  system-media owner. It creates a scoped `MPNowPlayingSession`, publishes metadata on each
  `AVPlayerItem`, and routes session commands back to `PlaybackController`.
- `Labstream/Shared/Player/PlaybackLifecycleCallbackSink.swift` and
  `VideoPlaybackLifecyclePolicy.swift` reject queued observer/task callbacks from a
  superseded item generation; removing an observer alone is not treated as cancellation.
- `Labstream/Shared/Player/SystemMediaSessionCoordinator.swift` serializes process-wide Now
  Playing and remote-command ownership between music and video with identity-guarded leases;
  visionOS video does not use this lease path.
- `Labstream/Shared/Player/NowPlayingArtwork.swift` provides the shared MediaPlayer artwork wrapper
  used by both system-media approaches.

Pure playback policies and request builders live primarily in
`PMSKit/Sources/PMSKit/Playback/`, `PMSKit/Sources/PMSKit/Transcode/`,
`PMSKit/Sources/PMSKit/MediaBrowser/`, and
`PMSKit/Sources/PMSKit/MediaSession/`. The MediaSession directory is the exception to
the usual pure-policy boundary: it owns the live, injectable loopback HLS proxy and
upstream connection rotation used by `PlaybackController`.

## Cinema

- `Labstream/Platforms/visionOS/Player/CustomCinemaMode.swift` is the user-visible visionOS Custom Cinema
  implementation. It reuses the live `PlaybackController` and custom player chrome in an
  immersive space and is absent from non-vision products at compile time.
- `Labstream/Platforms/visionOS/Player/CinemaAppRouting.swift` is the small app-action adapter between PMSKit's
  pure Cinema exit decision and the visionOS system-entry router. Its deterministic suite is now
  visionOS-only; the assertions are preserved but honestly remain unexecuted until the planned
  visionOS-hosted test target exists.

## Downloads and offline

- `Labstream/Capabilities/Downloads/Core/DownloadManager.swift` owns queue policy, observable records and
  snapshots, retry/resume, storage limits, server-prep polling, validation, and encoder
  cleanup.
- `DownloadKeepaliveCoordinator.swift` privately owns exact-attempt Jellyfin/Emby
  keepalive tasks and credential-generation quarantine; the manager only forwards start/reconcile and exact-cancellation requests.
- `DownloadManager+Plex.swift` and `DownloadManager+PlexOptimize.swift` own Plex source
  and optimizer behavior.
- `DownloadManager+Jellyfin.swift` owns Jellyfin original/transcode/remux behavior.
- `DownloadManager+Emby.swift` and `DownloadManager+EmbyConvert.swift` own Emby source,
  remux, and Convert behavior.
- `DownloadManager+SideCache.swift` caches posters, subtitles, chapters, Plex BIF, and
  Jellyfin trick-play assets through `DownloadSideAssetService.swift`, which owns validated
  off-main repair inventory/preparation and exact resource admission.
- `DownloadPlanningRequestExecutor.swift` is the injected nonpersistent request boundary for
  `DownloadItemPlanner`; same-origin 307/308 redirects preserve method/body/headers and every other
  redirect is rejected.
- `DownloadOptionsModel.swift` owns typed option resolution; season planning captures immutable
  drafts and exact retry attempts before one atomic Store transaction.
- `DownloadTransferStartPlan.swift` is the common backend-to-transfer handoff contract.
- `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift` owns URLSession delegates,
  reattachment, progress, validation, background-wake release effects, and durable static
  byte-range recovery.
- `BackgroundDownloadWakeCoordinator.swift` owns the locked background-completion gate,
  atomic deferred-revalidation drain, and range-rebuild grace generations.
- `Labstream/Capabilities/Downloads/Core/BackgroundDownloadCompletionRegistry.swift` joins system relaunch
  callbacks to the live/recreated background session.
- `Labstream/Capabilities/Downloads/Core/DownloadStore.swift` owns the locked relative-path index and files
  under Application Support.
- `DownloadArtifactLifecycleCoordinator.swift` registers attempt-scoped filesystem work
  before execution and releases it only after the matching persistence outcome;
  `DownloadArtifactFileCommitter.swift`, `DownloadPromotionFilesystem.swift`, and
  `DownloadStaticCheckpointFilesystem.swift` are the narrow file-effect seams.
- `RevisionedPersistenceWriter.swift` and `DownloadIndexFileCommitter.swift` serialize
  revisioned index writes. `BackgroundCompletionPersistenceBarrier.swift` flushes the
  exact boundary before releasing background-session completion handlers.
- `DownloadWorkRegistry.swift` tracks attempt-scoped side-cache and encoder work.
  `DownloadCleanupIntentJournal.swift` persists credential-free Jellyfin/Emby cleanup
  independently so deleting a row cannot discard required server cleanup.
  `EmbyConvertCleanupJournal.swift` owns the compatibility Emby Convert tombstone file and
  serializes that queue independently of the `DownloadStore` index lock.
- `Labstream/Capabilities/Downloads/Core/OfflineLibraryView.swift` owns the cross-backend offline UI and
  local playback launch. Its snapshot is lightweight and actions re-resolve exact attempt identity.
- `PMSKit/.../DownloadStorageSnapshot.swift` owns provenance-aware known/unknown/not-applicable
  storage presentation.
- `PMSKit/Sources/PMSKit/Downloads/` contains pure route, status, retry, display, storage,
  identity, and range-transfer policies and offline models.

Do not assume simulator and device transfers use identical URLSession configuration:
hardware uses the relaunch-capable background session, while simulator runs normally use
the documented foreground substitute.

## Music

- `Labstream/Shared/Music/MusicProvider.swift` defines the backend-neutral browse boundary.
- `PlexMusicProvider.swift` supplies Plex-native and richer artist data.
- `MediaBrowserMusicProvider.swift` is shared by Jellyfin and Emby.
- `MusicStreamResolver.swift` is the single backend-aware stream resolver.
- `MusicPlayerController.swift` owns the app-lifetime AVPlayer queue, shuffle/repeat,
  audio-session behavior, remote commands, and Now Playing metadata.
- `MusicPlaybackLifecycle.swift` generation-guards per-track observers and queued work;
  music acquires the shared `SystemMediaSessionCoordinator` lease rather than mutating
  global MediaPlayer state independently of video.
- `MusicLibraryView.swift`, `MediaBrowserMusicView.swift`, `MusicPagedGrid.swift`, and
  the album/artist/playlist detail views own presentation.
- `MiniPlayerBar.swift` and `NowPlayingView.swift` are the compact/full playback surfaces;
  `RootView.swift` owns their shared presentation state and app-owned visionOS backdrop
  so a surround tap and the explicit leading-edge close control use the same dismissal
  path without activating obscured content.
- `PMSKit/Sources/PMSKit/Music/` contains Plex music request builders and pure queue
  mutation behavior.

Plex music currently reports timeline/scrobble state. Jellyfin/Emby music playback works,
but MediaBrowser music progress reporting is not yet implemented.

## SharePlay / Watch Together (visionOS)

- `Labstream/Platforms/visionOS/SharePlay/WatchTogetherActivity.swift` defines the GroupActivity wrapper and maps
  PMSKit's sanitized payload display fields into `GroupActivityMetadata`.
- `Labstream/Platforms/visionOS/SharePlay/WatchTogetherCoordinator.swift` owns activation, GroupSession and
  messenger state, participant readiness, local launch, the exact-item attachment consent gate,
  and the `AVPlayerPlaybackCoordinator` session binding.
- `Labstream/Platforms/visionOS/SharePlay/WatchTogetherMediaLookup.swift` searches and attempts to hydrate candidates
  only through the participant's currently authenticated online backend.
- `Labstream/Platforms/visionOS/SharePlay/WatchTogetherJoinView.swift` presents incoming local-resolution and
  participant-readiness state and forwards search, selection, start, and decline actions; the
  coordinator and lookup own the resolution work.
- `Labstream/Shared/Player/CustomPlayerView.swift` and
  `Labstream/Platforms/visionOS/Player/CustomCinemaMode.swift` maintain attachment across player-item replacement
  and the window-to-Cinema handoff.
- `PMSKit/Sources/PMSKit/SharePlay/SharePlayMediaIdentity.swift` owns backend-neutral payload
  privacy, matching, readiness, leave, and late-join re-broadcast decisions;
  `PMSKit/Sources/PMSKit/SharePlay/SharePlayPlaybackAttachmentRevision.swift` owns the pure
  session/item revision key.

## System integration

- `Labstream/Shared/SystemIntegration/SystemEntryRouter.swift` is the process-lifetime bridge
  from non-view entry points—including a participant-locally resolved SharePlay launch—into
  RootView navigation. It weakly references the app-owned state and can wait for or initiate
  session restoration without preempting an in-progress user authorization attempt.
- `Labstream/Shared/SystemIntegration/LabstreamIntents.swift` defines Play, Open, and Continue
  Watching App Intents for all three backends.
- `Labstream/Shared/SystemIntegration/MediaItemEntity.swift` defines backend/server-scoped
  AppEntity search and suggestions. Display values are snapshots; metadata is refetched
  before navigation.
- `Labstream/Shared/SystemIntegration/SpotlightIndexer.swift` performs token-free,
  index-as-you-browse video indexing and shared-domain deletion.
- `PMSKit/Sources/PMSKit/SystemEntryRouting.swift` contains pure identifier and routing
  helpers.

The current system surface excludes music and does not crawl an entire library in the
background.

## Diagnostics and privacy

- `Labstream/Shared/Diagnostics/AppDiagnostics.swift` is the opt-in app-side facade.
- `DiagnosticFileLogSink.swift` owns the rotating local JSONL sink.
- `DiagnosticReportArtifact.swift` owns export/share wrappers.
- `BrowseDiagnostics.swift` creates privacy-safe browse facts.
- `MetricKitDiagnostics.swift` stores a bounded set of redacted crash/hang summaries for
  user-generated feedback; it does not upload them.
- `PerformanceInstrumentation.swift` is real signpost instrumentation in Debug and an
  API-compatible no-op in Release. Its terminal gate emits at most one end/signpost record per
  span even when cancellation and completion race. Launch evidence includes app-wide runtime
  composition (`downloads_capable=0|1`) and selected-backend session restore (`restored=0|1`),
  without identities, URLs, or credentials; `scripts/perf_evidence_schema.py` is the closed
  allowlist for every emitted terminal field and phase/backend pairing.
- `PMSKit/Sources/PMSKit/Diagnostics/` owns typed fields, redaction, the bounded event
  store, report rendering, and MetricKit summary models.

Use typed `DiagnosticFieldValue`s. Do not add raw tokens, URLs, hosts, usernames, local
paths, filenames, client identifiers, or media titles to diagnostics.

## Tests, builds, and scripts

- `PMSKit/Tests/PMSKitTests/` covers pure policies, request builders, decoders, state
  machines, and redaction. Run it with `cd PMSKit && swift test`.
- `Labstream.xcodeproj/project.pbxproj` is the source of truth for the four native app target
  versions, platforms, and deployment settings.
- `scripts/worktree-sim.sh` provisions the visionOS worktree simulator or explicit
  iPhone/iPad and Apple TV simulators.
- `scripts/deploy-mobile-to-device.sh` deploys the signed mobile target to iPhone/iPad;
  `scripts/deploy-to-device.sh` deploys the signed visionOS target.
- `scripts/` also contains docs, hygiene, version stamping, and optional live-probe tools.
- `.woodpecker/` contains portable CI definitions.
