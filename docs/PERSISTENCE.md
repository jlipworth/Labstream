# Persistence

## Keychain

Secrets and stable identifiers belong in `KeychainStore`:

- Plex account/server tokens
- stable client identifier
- selected backend/server details that are sensitive enough to avoid UserDefaults
- Jellyfin server URL, access token, user ID, and server ID
- future Emby server base URL, access token, user ID, server ID, and stable device ID once Emby support is implemented

Passwords are not persisted. For future Emby support, preserve any user-entered base path such as `/emby` with the server URL and scope tokens by server ID so a token is never sent to the wrong server.

## UserDefaults

UserDefaults stores non-secret preferences and feature toggles, including:

- selected backend kind and UI state that is safe to persist outside Keychain
- home/remote/legacy streaming quality preferences
- playback speed
- preferred audio/subtitle languages and subtitle mode
- adaptive bitrate preference
- default download quality and storage limit
- diagnostics enabled toggle

Keep quality preference migrations explicit. Home and remote quality settings are intentionally separate.

## Offline store

`DownloadStore` persists a JSON index of offline records using PMSKit Codable models:

- `DownloadRecord`
- `DownloadStatus`
- `OfflineMetadata`

Records store relative paths so app-container moves do not permanently break the index. The app owns file placement, cleanup, poster/art caching, and reconcile behavior.
