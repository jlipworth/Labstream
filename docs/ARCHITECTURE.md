# VisionPlay architecture

VisionPlay is a native visionOS app with a deliberately small app shell, backend-specific service lanes, and a pure Swift package (`PMSKit`) for request builders, models, and policy state machines.

## Ownership map

- `ContentView` creates and wires the long-lived app objects: `AppModel`, `AuthManager`, `DownloadManager`, and `MusicPlayerController`.
- `AppModel` owns backend/session selection and browse-ready state. It does not own the player, downloads, or auth controller.
- `AuthManager` owns sign-in, restore, sign-out, selected server credentials, and Keychain persistence.
- `DownloadManager` owns offline queue state, background transfer coordination, optimizer polling, and `DownloadStore` persistence.
- `PlaybackController` owns an active playback session: AVPlayer, restart/reopen behavior, player diagnostics, heartbeat/progress, and teardown.
- `SystemEntryRouter` is registered at launch so App Intents, Spotlight, deep links, and user activities route into the existing single window.

## PMSKit boundary

`PMSKit` is intentionally not an app framework. It should stay pure and testable:

- request builders for Plex and Jellyfin
- response models and MediaItem mapping
- playback/download decision helpers
- small policy state machines such as adaptive bitrate and seek restart budgeting
- diagnostics event/redaction primitives

The app owns all live `URLSession`, `AVPlayer`, SwiftUI state, Keychain, filesystem, and system-integration behavior.

## Backend boundary

There is no shared “everything backend” protocol yet. Plex and Jellyfin differ enough that a wide abstraction would hide important behavior. The current bridge is `MediaItem`: browse/playback/download features adapt backend-specific responses into that shared model where useful.

See [`BACKENDS.md`](BACKENDS.md) for the backend comparison.

## Playback boundary

Playback has three lanes:

1. Plex universal-transcode/direct-stream HLS through `PlaybackController.start()`.
2. Jellyfin resolved stream URLs with headers and a `RemoteStreamReopener`.
3. Local offline file URLs.

The player owns restart semantics and server cleanup. Plex transcode sessions must be stopped before intentional same-session restarts. Local offline files are static and have no server timeline or remote reopen path.

See [`PLAYBACK-ARCHITECTURE.md`](PLAYBACK-ARCHITECTURE.md).

## Offline boundary

Downloads are not “streaming with a longer timeout.” They must end in a static local file with a valid length and playable container. Plex downloads choose between direct-original and server-rendered compatible copies. Jellyfin downloads use direct original or a static transcoded MP4 request, depending on quality and local compatibility.

See [`DOWNLOADS-OFFLINE.md`](DOWNLOADS-OFFLINE.md).

## Persistence boundary

Secrets live in Keychain, preferences in UserDefaults, and offline download records in a JSON store under the app container. PMSKit owns the Codable models for offline records; the app owns the actual store and file paths.

See [`PERSISTENCE.md`](PERSISTENCE.md).

## Diagnostics and privacy boundary

Diagnostics are opt-in, local, bounded, and user-exported only. Sensitive fields must be represented with typed `DiagnosticFieldValue`s so redaction happens before report rendering.

See [`DIAGNOSTICS-PRIVACY.md`](DIAGNOSTICS-PRIVACY.md).
