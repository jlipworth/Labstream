# Archived documentation

This lane contains completed, superseded, or closed context that is retained for history and is never canonical guidance or an active work queue.

Current architecture and operating guidance lives in the published pages at the top of `docs/`:

- [`ARCHITECTURE.md`](../ARCHITECTURE.md)
- [`PLAYBACK-ARCHITECTURE.md`](../PLAYBACK-ARCHITECTURE.md)
- [`BACKENDS.md`](../BACKENDS.md)
- [`PERSISTENCE.md`](../PERSISTENCE.md)
- [`DIAGNOSTICS-PRIVACY.md`](../DIAGNOSTICS-PRIVACY.md)
- [`SYSTEM-INTEGRATION.md`](../SYSTEM-INTEGRATION.md)
- [`TESTING-STRATEGY.md`](../TESTING-STRATEGY.md)

Active implementation plans live in [`docs/plans/`](../plans/), unresolved investigations in [`docs/research/`](../research/), and immutable audit/profiling observations in [`docs/evidence/`](../evidence/).

## What belongs here

- `plans/` — completed or superseded implementation plans after durable guidance has been promoted;
- `reviews/` — resolved point-in-time branch and change reviews;
- `research/` — closed investigations and historical research;
- `downloads/` — superseded downloads designs and completed downloads-specific notes;
- `macos/` — issue-specific notes from the first native Mac implementation;
- `testing/` — superseded checklists and test snapshots;
- `proposals/` — closed or superseded proposals that are not queued work;
- `first-public-cleanup/` — the preserved first-public-documentation cleanup snapshot.

Do not archive unresolved work merely to hide it, and do not cite an archive document as the current operating contract when a published page exists.

## Naming and lifecycle

Preserve established filenames when moving historical material. New archived material should normally keep or gain a `YYYY-MM-DD-<topic>.md` name when the date is known. Before archiving a plan, review, or investigation, promote durable facts and procedures into current documentation and link any deliberately open successor.

Historical prose and path literals may remain as written when they are part of the snapshot. Repair live Markdown navigation after moves, add a status banner when necessary to prevent stale instructions from being followed, and scrub private identifiers before anything enters this public lane.

## Archived plans

- [`2026-07-20-main-documentation-alignment.md`](plans/2026-07-20-main-documentation-alignment.md) — completed factual alignment, documentation taxonomy, Mermaid, and durable-governance work.
- [`2026-07-20-macos-shell-redesign.md`](plans/2026-07-20-macos-shell-redesign.md) — completed native Mac source-list, toolbar Search, adaptive-window, and acceptance work for #232; follow-up presentation polish is tracked in #251.

Archived files may mention retired decisions such as the `Safari` Plex client profile, old proxy-owned seek designs, or pre-Jellyfin assumptions. Do not copy those details back into code or active docs without re-verifying them against current source.
