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
- `downloads/` — superseded downloads designs and completed downloads-specific notes;
- `macos/` — issue-specific notes from the first native Mac implementation;
- `testing/` — superseded checklists and test snapshots;
- `proposals/` — closed or superseded proposals that are not queued work;
- `first-public-cleanup/` — the preserved first-public-documentation cleanup snapshot.

Do not archive unresolved work merely to hide it, and do not cite an archive document as the current operating contract when a published page exists.

## Naming and lifecycle

Preserve established filenames when moving historical material. New archived material should normally keep or gain a `YYYY-MM-DD-<topic>.md` name when the date is known. Before archiving a plan, review, or investigation, promote durable facts and procedures into current documentation and link any deliberately open successor.

Historical prose and path literals may remain as written when they are part of the snapshot. Repair live Markdown navigation after moves, add a status banner when necessary to prevent stale instructions from being followed, and scrub private identifiers before anything enters this public lane.

## Archived plans and programs

- [`2026-07-20-emby-bif-trickplay.md`](plans/2026-07-20-emby-bif-trickplay.md) — completed Emby ThumbnailSet/BIF online and offline trick-play implementation and accepted #238 verification journal.
- [`2026-07-20-main-documentation-alignment.md`](plans/2026-07-20-main-documentation-alignment.md) — completed factual alignment, documentation taxonomy, Mermaid, and durable-governance work.
- [`2026-07-20-macos-shell-redesign.md`](plans/2026-07-20-macos-shell-redesign.md) — completed native Mac source-list, toolbar Search, adaptive-window, and acceptance work for #232; follow-up presentation polish is tracked in #251.
- [`2026-07-10-codebase-remediation.md`](plans/2026-07-10-codebase-remediation.md) — completed whole-repository correctness, concurrency, performance, backend/platform sharing, and build-cost remediation journal; accepted as complete 2026-07-24.
- [`2026-07-20-tvos-implementation.md`](plans/2026-07-20-tvos-implementation.md) — completed first-class tvOS implementation and acceptance plan for #246; accepted as complete 2026-07-24.
- [`2026-07-21-simplification-performance.md`](plans/2026-07-21-simplification-performance.md) — completed cross-platform simplification and performance program (Wave 5 measurements explicitly forgone); accepted as complete 2026-07-24.
- [`2026-09-06-agent-playback-evidence.md`](plans/2026-09-06-agent-playback-evidence.md) — completed agent playback evidence and diagnostics implementation journal; current guidance lives in [Agent playback troubleshooting](../AGENT-PLAYBACK-TROUBLESHOOTING.md).

## Archived research and session records

- [`01-plex-api-transcoding.md`](research/01-plex-api-transcoding.md) — June 2026 research on Plex auth, browsing, server-side transcoded HLS, and offline download options for the original visionOS client.
- [`02-visionos-playback-theater.md`](research/02-visionos-playback-theater.md) — June 2026 survey of visionOS HLS playback, cinema environments, and frame-packed 3D presentation.
- [`03-app-architecture-sideload.md`](research/03-app-architecture-sideload.md) — June 2026 app-structure and free-Apple-ID sideload/provisioning analysis.
- [`04-competitive-teardown.md`](research/04-competitive-teardown.md) — June 2026 snapshot of competing visionOS Plex clients for the original build/no-build decision.
- [`05-mobile-client-ux-reference.md`](research/05-mobile-client-ux-reference.md) — June 2026 feature and navigation catalog of mature iOS/iPadOS media-server clients used as UX vocabulary.
- [`06-prerequisites-licensing.md`](research/06-prerequisites-licensing.md) — June 2026 prerequisites and licensing checklist for the personal-use visionOS build.
- [`07-plex-official-api-surface.md`](research/07-plex-official-api-surface.md) — 2026-06-08 assessment of official versus community Plex API surface and auth-migration risk.
- [`08-plex-client-library-catalog.md`](research/08-plex-client-library-catalog.md) — June 2026 catalog of Plex client libraries as transcode/streaming reference implementations.
- [`09-transcode-api-deep-dive.md`](research/09-transcode-api-deep-dive.md) — version-dependent Plex universal transcode parameter and decision-code reference with per-row confidence tags.
- [`10-apple-media-api-inventory.md`](research/10-apple-media-api-inventory.md) — visionOS 26 Apple framework inventory, focused on offline download of a bitrate-capped transcode.
- [`11-offline-download-spike.md`](research/11-offline-download-spike.md) — 2026-06-08 feasibility spike for capped-bitrate offline Plex downloads.
- [`12-visionos-app-templates.md`](research/12-visionos-app-templates.md) — June 2026 survey of visionOS reference projects considered as structural templates.
- [`13-playback-state-apis.md`](research/13-playback-state-apis.md) — 2026-06-08 Plex timeline, scrobble, play-queue, hub, and resume API research.
- [`14-player-downloads-audit-and-roadmap.md`](research/14-player-downloads-audit-and-roadmap.md) — superseded June 2026 player/downloads audit and roadmap; its bugs were fixed and its work moved to GitHub issues.
- [`15-device-profile.md`](research/15-device-profile.md) — Vision Pro DeviceProfile/direct-play proposal; the decision-only probe shipped and the app-side follow-up (#7) is closed.
- [`16-jellyfin-backend-support.md`](research/16-jellyfin-backend-support.md) — pre-implementation Jellyfin backend research for #35; Jellyfin support has since shipped.
- [`17-emby-backend-support.md`](research/17-emby-backend-support.md) — Emby backend research and first-slice record for #68; Emby Connect and downloads have since shipped.
- [`18-offline-chapters-trickplay-subtitles.md`](research/18-offline-chapters-trickplay-subtitles.md) — closed #74 investigation of offline chapters, trick-play, and subtitles.
- [`2026-06-27-offline-playback-compatibility.md`](research/2026-06-27-offline-playback-compatibility.md) — closed #167 implementation-research snapshot of offline download compatibility checks.
- [`2026-07-21-tvos-session-report.md`](research/2026-07-21-tvos-session-report.md) — closed
  evidence-first session record for the tvOS focus/remote-input work; findings absorbed into
  the archived tvOS plan and the active screen audit.
- [`2026-08-22-jellyfin-public-demo.md`](research/2026-08-22-jellyfin-public-demo.md) —
  superseded evaluation of the official public Jellyfin stable demo for screenshots and App
  Review; compatibility passed, but the Labstream-controlled review catalog was chosen instead.

## Archived downloads notes

- [`DOWNLOADS-REFACTOR-135.md`](downloads/DOWNLOADS-REFACTOR-135.md) — historical #135 downloads audit and staged-refactor record.
- [`DOWNLOADS-HOLISTIC-REFACTOR-PLAN.md`](downloads/DOWNLOADS-HOLISTIC-REFACTOR-PLAN.md) — completed/superseded holistic downloads refactor plan and branch-era checkpoints.
- [`2026-07-10-static-range-segment-checkpointing.md`](downloads/2026-07-10-static-range-segment-checkpointing.md) — completed static-range segment-train checkpointing plan.
- [`2026-07-15-optional-download-side-assets.md`](downloads/2026-07-15-optional-download-side-assets.md) — completed request-family audit behind the process-wide optional side-asset coordinator.

## Archived macOS notes

- [`MACOS-228-REMAINING-WORK.md`](macos/MACOS-228-REMAINING-WORK.md) — issue-era #228 plan for finishing the first native Mac implementation.
- [`MACOS-228-VALIDATION.md`](macos/MACOS-228-VALIDATION.md) — issue-era #228 split between agent-runnable and user-only Mac validation.
- [`MACOS-RELEASE-SCAFFOLDING.md`](macos/MACOS-RELEASE-SCAFFOLDING.md) — issue-era #228 release and versioning scaffolding.

## Archived reviews

- [`2026-07-12-remediation-branch-review.md`](reviews/2026-07-12-remediation-branch-review.md) — resolved first review of the remediation branch (Phases 1–2).
- [`2026-07-12-remediation-delta-review.md`](reviews/2026-07-12-remediation-delta-review.md) — resolved second-pass delta review of the remediation branch.

## Archived proposals

- [`emby-jellyfin-code-sharing.md`](proposals/emby-jellyfin-code-sharing.md) — historical Jellyfin/Emby MediaBrowser code-sharing note from an earlier app version.

## Archived testing snapshots

- [`TESTING-CHECKLIST-2026-07-10.md`](testing/TESTING-CHECKLIST-2026-07-10.md) — the former rolling manual checklist as it existed on 2026-07-10.

## First-public-cleanup snapshot

- [`DEVELOPMENT.md`](first-public-cleanup/DEVELOPMENT.md) — pre-cleanup development notes.
- [`PROFILING.md`](first-public-cleanup/PROFILING.md) — earlier Instruments profiling workflow.
- [`TESTING-LIVE-MATRIX.md`](first-public-cleanup/TESTING-LIVE-MATRIX.md) — dated live-server coverage matrix.
- [`TESTING-LIVE-REQUIREMENTS.md`](first-public-cleanup/TESTING-LIVE-REQUIREMENTS.md) — dated #75 live-server test requirements and proposed CI wiring.

Archived files may mention retired decisions such as the `Safari` Plex client profile, old proxy-owned seek designs, or pre-Jellyfin assumptions. Do not copy those details back into code or active docs without re-verifying them against current source.
