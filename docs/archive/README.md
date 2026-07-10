# Archived docs

This directory contains historical research, implementation plans, design specs, and review snapshots that are no longer the current source of truth.

Use these files only for context. Current architecture and operating guidance lives in the active docs at the top of `docs/`:

- [`ARCHITECTURE.md`](../ARCHITECTURE.md)
- [`PLAYBACK-ARCHITECTURE.md`](../PLAYBACK-ARCHITECTURE.md)
- [`BACKENDS.md`](../BACKENDS.md)
- [`PERSISTENCE.md`](../PERSISTENCE.md)
- [`DIAGNOSTICS-PRIVACY.md`](../DIAGNOSTICS-PRIVACY.md)
- [`SYSTEM-INTEGRATION.md`](../SYSTEM-INTEGRATION.md)
- [`TESTING-STRATEGY.md`](../TESTING-STRATEGY.md)

Archived files may mention retired decisions such as the `Safari` Plex client profile, old proxy-owned seek designs, or pre-Jellyfin assumptions. Do not copy those details back into code or active docs without re-verifying them against current source.

Completed or superseded generated plans belong in a focused archive after their durable
findings are promoted into current architecture docs; they must not remain active task
transcripts or current sources of truth.

Archived future-refactor/proposal notes live under `docs/archive/proposals/`. They are preserved only as historical context from earlier app versions; do not treat them as queued work or current guidance.

Historical downloads refactor/audit notes and the completed static-range segment-checkpointing
plan live under `docs/archive/downloads/`. The current downloads source of truth is
[`DOWNLOADS-OFFLINE.md`](../DOWNLOADS-OFFLINE.md).

Issue-specific notes from the first native Mac implementation live under `docs/archive/macos/`.
The current local-build and release status is documented in [`MACOS.md`](../MACOS.md).
