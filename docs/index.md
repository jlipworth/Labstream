# VisionPlay docs

VisionPlay is a personal-use, native Apple Vision Pro media client for Plex, Jellyfin, and Emby.

This documentation site keeps current user help, privacy notes, architecture, and contributor guidance separate from historical research and plans.

## Start here

- [Support & troubleshooting](support.md) — requirements, first-run steps, common playback/sign-in questions, and how to get help.
- [Report a bug](REPORTING-BUGS.md) — how to capture and share a redacted diagnostic report.
- [Privacy Policy](privacy.md) — what stays on your device and what VisionPlay sends to your selected media backend.
- [Diagnostics and privacy](DIAGNOSTICS-PRIVACY.md) — the developer-facing contract for safe diagnostic fields and reports.

## Contributor docs

- [Contributor Guide](CONTRIBUTING.md) — checkout, simulator/device workflow, validation expectations, and privacy rules.
- [Development Setup](DEVELOPMENT.md) — deeper build, launch, logging, and platform notes.
- [Testing Strategy](TESTING-STRATEGY.md) — test layers and live-validation expectations.

## Architecture docs

- [Architecture overview](ARCHITECTURE.md)
- [Playback architecture](PLAYBACK-ARCHITECTURE.md)
- [Backends](BACKENDS.md)
- [Persistence](PERSISTENCE.md)
- [System integration](SYSTEM-INTEGRATION.md)
- [Music](MUSIC-DESIGN.md)

## Docs organization

Top-level files in `docs/` are the current source of truth. Active research for not-yet-implemented behavior belongs in `docs/research/`; historical or superseded material belongs in `docs/archive/`. Promote only implemented, validated behavior into the current docs.
