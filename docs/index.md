# Labstream docs

Labstream is a native Apple Vision Pro media client for Plex, Jellyfin, and Emby. It is currently distributed as source for local builds; App Store/TestFlight distribution is not available today.

This site is split into user help, human-developer onboarding, and current architecture notes. Historical research and generated implementation plans are intentionally kept out of the published docs navigation. The source repository is public at [github.com/jlipworth/Labstream](https://github.com/jlipworth/Labstream).

## For users

- [Support & troubleshooting](support.md) — requirements, first-run steps, common playback/sign-in questions, and how to get help.
- [Report a bug](REPORTING-BUGS.md) — how to capture, preview, and share a redacted diagnostic report.
- [Privacy Policy](privacy.md) — what stays on your device and what Labstream sends to your selected media backend.
- [License Exception](app-store-exception.md) — GPLv3 plus the Apple distribution permission used by this project.

## For contributors

- [Contributor Guide](CONTRIBUTING.md) — checkout, simulator/device workflow, validation expectations, and privacy rules.
- [Development Setup](DEVELOPMENT.md) — build, launch, logging, and platform notes for day-to-day development.
- [Code Map](CODE-MAP.md) — where to change app lifecycle, auth, backend, playback, downloads, music, diagnostics, and tests.
- [Scripts Catalog](SCRIPTS.md) — safe local validation, live probes, simulator/worktree helpers, and device deployment scripts.
- [Testing Strategy](TESTING-STRATEGY.md) — test layers and live-validation expectations.
- [Profiling](PROFILING.md) — Instruments, signposts, MetricKit, and baseline-retention rules.

## Architecture by subsystem

- [Architecture overview](ARCHITECTURE.md) — ownership boundaries and the app/PMSKit split.
- [Backends](BACKENDS.md) — Plex, Jellyfin, and Emby auth, browse, playback, and download differences.
- [Playback architecture](PLAYBACK-ARCHITECTURE.md) — startup lanes, restart/reopen behavior, and server cleanup invariants.
- [Downloads and offline](DOWNLOADS-OFFLINE.md) — route choices, transfer lifecycle, reconcile/resume, and local metadata.
- [Music architecture](MUSIC-DESIGN.md) — the Plexamp-inspired music surface and queue model.
- [Persistence](PERSISTENCE.md) — Keychain, UserDefaults, offline index, and debug fallbacks.
- [System integration](SYSTEM-INTEGRATION.md) — App Intents, Spotlight, user activities, and single-window routing.
- [Diagnostics and privacy](DIAGNOSTICS-PRIVACY.md) — developer contract for safe diagnostic fields and reports.

## Docs organization

Top-level files in `docs/` are the current source of truth. Active research for not-yet-implemented behavior belongs in `docs/research/`; historical or superseded material belongs in `docs/archive/`. Promote only implemented, validated behavior into the current docs.
