# Archived documentation

This lane contains completed, superseded, or closed context that is retained for history and is never canonical guidance or an active work queue.

Current architecture and operating guidance lives in the published pages at the top of `docs/`:

- [`ARCHITECTURE.md`](../ARCHITECTURE.md)
- [`PLAYBACK-ARCHITECTURE.md`](../PLAYBACK-ARCHITECTURE.md)
- [`BACKENDS.md`](../BACKENDS.md)
- [`PERSISTENCE.md`](../PERSISTENCE.md)
- [`DOWNLOADS-OFFLINE.md`](../DOWNLOADS-OFFLINE.md)
- [`MUSIC-DESIGN.md`](../MUSIC-DESIGN.md)
- [`DIAGNOSTICS-PRIVACY.md`](../DIAGNOSTICS-PRIVACY.md)
- [`SYSTEM-INTEGRATION.md`](../SYSTEM-INTEGRATION.md)
- [`TESTING-STRATEGY.md`](../TESTING-STRATEGY.md)
- [`DEVELOPMENT.md`](../DEVELOPMENT.md)
- [`MOBILE-IOS.md`](../MOBILE-IOS.md)
- [`TVOS.md`](../TVOS.md)
- [`MACOS.md`](../MACOS.md)

Active implementation plans live in [`docs/plans/`](../plans/), unresolved investigations in [`docs/research/`](../research/), and immutable audit/profiling observations in [`docs/evidence/`](../evidence/).

## What belongs here

- `plans/` — completed or superseded implementation plans after durable guidance has been promoted;
- `reviews/` — resolved point-in-time branch and change reviews;
- `research/` — closed investigations and historical research;
- `downloads/` — superseded downloads designs and completed downloads-specific notes.

Do not archive unresolved work merely to hide it, and do not cite an archive document as the current operating contract when a published page exists.

## Naming and lifecycle

Preserve established filenames when moving historical material. New archived material should normally keep or gain a `YYYY-MM-DD-<topic>.md` name when the date is known. Before archiving a plan, review, or investigation, promote durable facts and procedures into current documentation and link any deliberately open successor.

Historical prose and path literals may remain as written when they are part of the snapshot. Repair live Markdown navigation after moves, add a status banner when necessary to prevent stale instructions from being followed, and scrub private identifiers before anything enters this public lane.

## Archived research and session records

- [`11-offline-download-spike.md`](research/11-offline-download-spike.md) — 2026-06-08 feasibility spike for capped-bitrate offline Plex downloads.
- [`14-player-downloads-audit-and-roadmap.md`](research/14-player-downloads-audit-and-roadmap.md) — superseded June 2026 player/downloads audit and roadmap; its bugs were fixed and its work moved to GitHub issues.
- [`18-offline-chapters-trickplay-subtitles.md`](research/18-offline-chapters-trickplay-subtitles.md) — closed #74 investigation of offline chapters, trick-play, and subtitles.
- [`2026-06-27-offline-playback-compatibility.md`](research/2026-06-27-offline-playback-compatibility.md) — closed #167 implementation-research snapshot of offline download compatibility checks.

## Archived downloads notes

- [`DOWNLOADS-REFACTOR-135.md`](downloads/DOWNLOADS-REFACTOR-135.md) — historical #135 downloads audit and staged-refactor record.
- [`DOWNLOADS-HOLISTIC-REFACTOR-PLAN.md`](downloads/DOWNLOADS-HOLISTIC-REFACTOR-PLAN.md) — completed/superseded holistic downloads refactor plan and branch-era checkpoints.
- [`2026-07-10-static-range-segment-checkpointing.md`](downloads/2026-07-10-static-range-segment-checkpointing.md) — completed static-range segment-train checkpointing plan.
- [`2026-07-15-optional-download-side-assets.md`](downloads/2026-07-15-optional-download-side-assets.md) — completed request-family audit behind the process-wide optional side-asset coordinator.
- [`2026-07-10-downloads-engine-audit-plan.md`](downloads/2026-07-10-downloads-engine-audit-plan.md) — completed full downloads-engine audit plan and execution record; physical-device evidence remains an acceptance gate.
- [`2026-07-10-downloads-state-machines.md`](downloads/2026-07-10-downloads-state-machines.md) — Phase-2 extracted download state machines versus documented intent at the audit baseline.
- [`2026-07-11-downloads-phase4-coverage-matrix.md`](downloads/2026-07-11-downloads-phase4-coverage-matrix.md) — completed Phase-4 coverage-gap matrix snapshot. The retained Phase-6 [fault-injection harness record](../evidence/audits/2026-07-11-downloads-fault-injection-harness.md) stays in evidence.

Archived files may mention retired decisions such as the `Safari` Plex client profile, old proxy-owned seek designs, or pre-Jellyfin assumptions. Do not copy those details back into code or active docs without re-verifying them against current source.
