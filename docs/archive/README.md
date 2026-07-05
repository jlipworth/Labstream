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

Completed or superseded generated Superpowers specs/reviews were removed from the public tree during the publication scrub. Durable findings from those plans should live in the active architecture docs or in focused archive notes, not in generated task transcripts.

Archived future-refactor/proposal notes live under `docs/archive/proposals/`. They are preserved only as historical context from earlier app versions; do not treat them as queued work or current guidance.

Historical downloads refactor/audit notes live under `docs/archive/downloads/`. The current downloads source of truth is [`DOWNLOADS-OFFLINE.md`](../DOWNLOADS-OFFLINE.md).
