# Music architecture

VisionPlay's Music tab is implemented as a Plexamp-inspired, app-native music surface rather than a separate music-first app shell. The current code lives under `VisionPlay/Music/`, with pure request and queue helpers in `PMSKit/Sources/PMSKit/Music/`.

## Current surface

- The app-level tab bar remains Home · Libraries · Search · Music · Offline · Settings. Music is one tab in the video-first client.
- `MusicLibraryView` and `MediaBrowserMusicView` present a shared Home / Artists / Albums / Playlists pivot via `MusicPivotShell`.
- Plex Home renders section hubs plus a synthesized Recently Played tracks rail and Shuffle Library; MediaBrowser Home renders provider-backed `MusicHomeRail`s such as Discover, Recently Added, Recently Played, and Favorite Albums where the backend exposes them.
- Artists and albums use `MusicPagedGrid` with provider-level paging and sort options.
- Playlists are read-only: `MusicPlaylistsPivot` lists audio playlists, and `PlaylistDetailView` preserves server playlist order for tracks.
- Artist, album, and playlist detail screens use track rows with queue actions where supported.

## Provider boundary

`MusicProvider` is the app-facing seam. It exposes music libraries, artists, albums, playlists, artist details, and album/artist/playlist tracks. Concrete providers keep backend differences explicit:

- `PlexMusicProvider` uses Plex `MusicRequest`, `PlaylistRequest`, and `BrowseAPI` endpoints, including Plex-only artist enrichments such as Popular, related shelves, Appears On, and Similar Artists.
- `MediaBrowserMusicProvider` adapts the Jellyfin/Emby-style MediaBrowser lanes through `MediaBrowserMusicBrowsing`, leaving Plex-only artist enrichments empty.

Pure request builders live in PMSKit (`MusicRequest`, `PlaylistRequest`, and `QueueMutation`). The app owns async loading state, SwiftUI routing, AVPlayer playback, artwork fetching, and system now-playing integration.

## Playback and queue

`MusicPlayerController` owns audio playback, queue state, shuffle/repeat, Now Playing metadata, remote command center handling, and interruption handling.

- `MiniPlayerBar` is a bottom scene ornament and opens `NowPlayingView`, including the queue pre-scroll path.
- `NowPlayingView` shows the current item, transport controls, scrub state, shuffle/repeat, and an editable Up Next queue.
- Track context menus use `TrackQueueMenu` for Play Next and Add to Queue.
- Queue mutations are routed through PMSKit's `QueueMutation` helpers so ordering and shuffle behavior remain testable.

## System integration

Music playback publishes metadata to `MPNowPlayingInfoCenter` and registers `MPRemoteCommandCenter` handlers for play/pause, previous/next, seek, and position changes. The music player is separate from the video `PlaybackController`; do not couple music queue state to video playback sessions.

## Deferred / non-goals

The original phase plan is complete enough that this document is now current architecture, not an implementation checklist. Still-deferred ideas should stay behind new research/proposal docs until implemented and validated: visualizers, EQ/preamp, lyrics, server-side play queues, gapless/`AVQueuePlayer` playback, playlist editing/reordering, music home customization, TIDAL, and an immersive album wall.
