# Code map

Use this as the "where do I change X?" guide. The short rule: keep pure decisions in `PMSKit`; keep side effects, SwiftUI state, AVFoundation, Keychain, files, and system APIs in the `VisionPlay` app target.

## App shell and lifecycle

- `VisionPlay/App/` — app entry, environment setup, restore/bootstrap wiring, and top-level app state.
- `VisionPlay/UI/` — Home, Libraries, Search, Detail, Settings, shared row/card views, and user-facing chrome.
- `ContentView` — main-window root: restore, login, browse, and routing handoff.
- `AppModel` — selected backend/session and browse-ready state. It should not become the player, auth controller, or download manager.

## Auth, sessions, and identity

- `VisionPlay/Auth/` — sign-in/restore/sign-out orchestration and Keychain interaction.
- `PMSKit/Sources/PMSKit/Auth/` — pure auth helpers and request/header builders.
- `PMSKit/Sources/PMSKit/Security/` and `ClientIdentity` — stable client/device identity policies.
- `docs/PERSISTENCE.md` — what belongs in Keychain vs UserDefaults vs the offline store.

## Backend browse lanes

- `VisionPlay/Backend/PlexBrowseAPI.swift` — Plex browse/search/library service lane.
- `VisionPlay/Backend/Jellyfin/` — Jellyfin browse, playback-open, and MediaBrowser adaptation.
- `VisionPlay/Backend/Emby/` — Emby browse, Connect/manual auth integration, playback-open, and active-encoding cleanup.
- `PMSKit/Sources/PMSKit/Jellyfin/`, `Emby/`, and `MediaBrowser/` — request builders, decoders, shared MediaBrowser shapes, and pure mapping helpers.

Avoid a broad "one backend protocol" unless the concrete API behavior is truly identical. Plex, Jellyfin, and Emby intentionally keep separate lanes where server semantics differ.

## Playback

- `VisionPlay/Player/` — `PlaybackController`, custom player UI, restart/reopen flow, diagnostics snapshots, progress reporting, and AVFoundation ownership.
- `PMSKit/Sources/PMSKit/Playback/` — pure playback policy and response helpers.
- `PMSKit/Sources/PMSKit/Transcode/` — Plex transcode request/device-profile policy. `X-Plex-Client-Profile-Name=Generic` is load-bearing.
- `PMSKit/Sources/PMSKit/MediaSession/` — playlist/proxy helpers used only after a stream URL is already resolved.

Playback has four lanes: Plex HLS, Jellyfin resolved remote streams, Emby `PlaybackInfo` streams, and local offline files. Keep restart and cleanup behavior explicit per lane.

## Downloads and offline

- `VisionPlay/Downloads/DownloadManager.swift` — main-actor coordinator for queue/runtime state and offline-library publishing.
- `DownloadManager+Plex.swift`, `+PlexOptimize.swift`, `+Jellyfin.swift`, `+Emby.swift`, `+EmbyConvert.swift`, `+SideCache.swift` — backend-specific request, poller, and side-asset behavior.
- `BackgroundDownloadSession` — URLSession tasks, static byte-range checkpoints, finalization, and transfer callbacks.
- `DownloadStore` — versioned `index.json`, file reconciliation, side-asset accounting, and app-container deletes.
- `PMSKit/Sources/PMSKit/Downloads/` — pure route planners, retry/pause/delete rules, static-range recovery, storage estimates, side-asset choices, captions, and offline snapshots.

If a decision can be tested without credentials, a simulator, or AVFoundation, it probably belongs in `PMSKit/Downloads`.

## Music

- `VisionPlay/Music/` — Music tab UI, queue/mini-player surface, and `MusicPlayerController` side effects.
- `PMSKit/Sources/PMSKit/Music/` — pure music request and queue helpers.

Music playback is separate from video `PlaybackController`; do not route music queue behavior through the video player.

## Diagnostics, privacy, and profiling

- `VisionPlay/Diagnostics/` — event capture, local report assembly, MetricKit summaries, and report UI.
- `PMSKit/Sources/PMSKit/Diagnostics/` — typed diagnostic values and redaction primitives.
- `docs/DIAGNOSTICS-PRIVACY.md` — required redaction contract.
- `docs/PROFILING.md` — signpost and Instruments workflow.

Never log or commit raw tokens, hostnames/IPs, media titles, library paths, usernames, item IDs, or play-session IDs.

## System integration

- `VisionPlay/SystemIntegration/` — App Intents, Spotlight, user activities, and route handoff.
- `PMSKit/Sources/PMSKit/UI/` and routing helpers — pure identifier parsing/mapping where applicable.
- `SystemEntryRouter` — the single gate into the existing main window. Do not add unrelated secondary windows for deep links or intents.

## Tests, probes, and scripts

- `PMSKit/Tests/PMSKitTests/` — pure request/model/policy tests and opt-in live probes.
- `scripts/ci-hygiene.sh` — local/CI hygiene guardrails.
- `scripts/live-*.sh` — opt-in server-wire probes gated by gitignored env files.
- `scripts/probe-*-download.sh` — simulator app-process probes for download lanes.
- `scripts/worktree-sim.sh` — one simulator per worktree; always target `$(scripts/worktree-sim.sh id)`.
- `scripts/deploy-to-device.sh` — signed physical-device build/install wrapper.

## Rules of thumb

- Put deterministic decisions in `PMSKit` with tests.
- Keep credentials, filesystem, Keychain, `URLSession`, AVFoundation, and SwiftUI side effects in the app target.
- Prefer small backend-specific adapters over a shared abstraction that hides server differences.
- Update focused current docs when behavior becomes a durable invariant; move plans and incident notes to `docs/archive/` or delete them before publication.
