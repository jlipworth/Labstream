# Persistence

## Keychain

Secrets and stable identifiers belong in `KeychainStore`:

- Plex account/server tokens
- stable client identifier
- selected backend/server details that are sensitive enough to avoid UserDefaults
- Jellyfin server URL, access token, user ID, and server ID
- Emby server URL (with any base path preserved), access token, user ID, and server ID

Passwords are not persisted.

### Emby session fields

`KeychainStore` persists four Emby keys: `embyServerURL`, `embyAccessToken`, `embyUserID`, `embyServerID`. The user-entered base path (for example `/emby`) is stored verbatim as part of `embyServerURL` — it must not be normalized away, because PlaybackInfo returns relative stream URLs that are joined back onto that base path. The stable device id is not a separate Emby key; it comes from the shared `ClientIdentity` (`identity.emby`) so the same device id is reused across sessions.

On launch, `AuthManager.restoreEmbySession()` reads those keys back into `AppModel` and validates the token with a `userViews` request. Distinguish failure modes: `401`/`403` clears the session and forces re-login (`signOutEmby()`); an unreachable server keeps the saved session and surfaces an offline/unreachable state rather than logging the user out. On explicit sign-out, the Emby keys are cleared locally even if `POST /Sessions/Logout` fails.

The Emby access token is a secret: redact it (and any `api_key`/`X-Emby-Token` value) from logs and diagnostics.

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
