# Emby BIF trick-play implementation plan and acceptance journal

Status: **implementation complete; generated-preview real-server proof accepted, offline and no-generated-preview acceptance remain open** for [GitHub issue #238](https://github.com/jlipworth/Labstream/issues/238). The [approved post-audit implementation direction](https://github.com/jlipworth/Labstream/issues/238#issuecomment-5024007573) is authoritative. Keep the issue open until real Emby behavior is healthy; automated tests and Apple-platform builds do not replace that gate.

Baseline: 2026-07-20 at repository commit `7fc0cc63`. This document is both the implementation plan and durable acceptance journal. Promote proven behavior into current architecture/testing documentation as needed, then archive this plan only after every gate below is complete or explicitly transferred to a linked follow-up.

**Source-relocation note:** the audited baseline path `Labstream/Player/TrickPlayThumbnailProviders.swift`
is now `Labstream/Shared/Player/TrickPlayThumbnailProviders.swift`.

## Goal

Give every current shared-player platform fine-grained Emby seek previews without changing seek semantics. Online playback must prefer the selected source's authenticated BIF when Emby advertises preview thumbnails, use bounded/coalesced per-position thumbnail images when BIF is unavailable or malformed, and retain chapter images as the final fallback. Offline downloads must best-effort cache the selected source's parseable BIF through the existing side-asset lifecycle, prefer it during playback, and retain cached chapter images as fallback.

All work is optional, playback-passive, cancellable, privacy-safe, Wi-Fi-policy-aware where downloaded, non-fatal, and fenced to the owning download attempt.

## Audited ownership and invariants

- `PMSKit/Playback/TrickPlayThumbnails.swift` owns the hardened shared `BIFParser`, backend-neutral thumbnail protocol, and pure selection/parsing policies.
- At the audited baseline, `Labstream/Player/TrickPlayThumbnailProviders.swift` owned shared online/offline provider actors but its Emby actor was chapter-only and contained obsolete comments claiming no fine-grained source.
- `EmbyLibrary` and `EmbyAuth` own canonical URL construction plus `Authorization` and `X-Emby-Token` attachment. New preview requests must reuse that path and never persist token-bearing URLs.
- `DetailPlaybackLauncher` carries the actual `MediaSourceId` returned by PlaybackInfo in `MediaBrowserRemotePlayback`. Provider construction must use that negotiated identity rather than silently falling back to a different version.
- `OfflineMetadata.mediaSourceID` carries the selected/actual download source migration-safely. New optional paths must decode absent for old records and survive stale metadata upserts.
- `DownloadWorkRegistry`, `DownloadStore.attemptStagingURL`, `promoteSideAsset`, and exact `DownloadAttemptKey` mutations fence side assets against pause/delete/replacement races.
- `SideAssetFetchCoordinator` owns optional-asset pacing, concurrency, coalescing, owner cancellation, status validation, and privacy-safe request identity. Preview traffic must not bypass it.
- `DownloadStore` owns side-asset destinations, hydration, byte accounting, deletion paths, and storage audit inventory. Every new Emby BIF path must join all five.
- Existing Plex BIF, Jellyfin tiles, Emby chapter images, and legacy persisted records are compatibility gates.

## Implementation plan

### 1. PMSKit requests, decoding, and policy

- [x] Add `ThumbnailSet` models/decoder and authenticated request builders for availability, per-position Thumbnail image, and `index.bif` at one canonical width.
- [x] Include the selected `MediaSourceId` wherever Emby supports it and test the exact query/auth shape.
- [x] Add pure provider hierarchy/selection helpers where doing so keeps malformed, absent, and fallback behavior headlessly testable.
- [x] Reuse and, if tests expose gaps, harden `BIFParser`; do not add another BIF parser.

### 2. Privacy-safe live probe

- [x] Extend the repo-owned Emby live harness and `scripts/emby-live.env` conventions.
- [x] Probe one authenticated candidate's `ThumbnailSet`, a listed per-position Thumbnail image, and `index.bif` read-only.
- [x] Emit only bounded verdicts and non-identifying counts/status/content-type/parse facts. Never emit server URLs, tokens, user ids, item/media-source ids, titles, filenames, or raw authenticated payloads.
- [x] If no configured item has generated previews, record that real empty/fallback shape and leave positive generated-preview acceptance open.

### 3. Online shared provider hierarchy

- [x] Replace the Emby chapter-only provider entry point with a hierarchy actor keyed to the actual PlaybackInfo `MediaSourceId`.
- [x] Query `ThumbnailSet`; if non-empty, coalesce one authenticated BIF fetch and parse it once.
- [x] If BIF is unavailable/invalid, select advertised positions and fetch per-position images through `SideAssetFetchCoordinator` with bounded cache/in-flight coalescing and cancellation.
- [x] Fall back silently to the existing chapter provider for absent, unauthorized, malformed, unsupported, or failed preview assets.
- [x] Remove obsolete comments without changing custom scrubber/seek behavior.

### 4. Offline side-asset lifecycle

- [x] Add an optional `embyBIFRelativePath`, legacy-safe decoding, stale-upsert preservation, hydrated URL, and shared local-BIF provider preference before cached chapters.
- [x] Best-effort cache only the selected/actual source's authenticated parseable BIF at download time and on eligible rehydrate paths.
- [x] Route the fetch through Wi-Fi policy, side-asset coordinator, work registry, attempt-private staging, atomic promotion, and exact-attempt metadata mutation.
- [x] Add the asset to stable deletion paths, startup inventory/orphan recognition, hydration, and side-asset byte accounting.

### 5. Verification

- [x] Request/decoder/auth tests.
- [x] Provider hierarchy, malformed asset, media-source identity, fallback, cancellation, and request-coalescing tests.
- [x] Offline migration, preservation, inventory/deletion, byte accounting, and attempt-fencing tests.
- [x] Relevant focused and full PMSKit tests.
- [x] Relevant visionOS, iOS/iPadOS, and macOS builds for touched shared app code, without booting a simulator.
- [x] Strict MkDocs, repository link/anchor checks, Mermaid validation, and CI hygiene.
- [x] Read-only live Emby probe.

## Acceptance gates

- [x] Online real Emby item with generated preview thumbnails proves non-empty `ThumbnailSet`, authenticated parseable BIF for the selected source, and healthy provider selection.
- [ ] Real Emby item/library without generated preview thumbnails proves the empty/unavailable shape and silent chapter fallback.
- [ ] Offline download from a generated-preview source proves selected-source BIF caching and cached-BIF playback preference, with chapters retained as fallback.
- [x] Automated compatibility coverage remains green for Plex BIF, Jellyfin tiles, Emby chapters, legacy records, cancellation, replacement fencing, deletion, and accounting.
- [x] All current player platforms compile against the shared hierarchy without seek-semantic changes.
- [x] Issue #238 contains the final commit, tests/builds, live-probe evidence, fallback outcome, plan status, and any remaining real-server gate.

## Acceptance journal

### 2026-07-20 — approved direction and repository audit

- Read the complete issue body and both comments; the approved post-audit direction is the implementation contract.
- Read `CLAUDE.md` and the applicable `headless-media-testing` skill before source changes.
- Confirmed the worktree began detached and created `codex/issue-238-emby-bif`.
- Confirmed current online/offline Emby preview behavior is chapter-only and current comments still encode the obsolete no-fine-grained-source assumption.
- Confirmed the negotiated PlaybackInfo `MediaSourceId` is available on `MediaBrowserRemotePlayback`, while the existing Emby provider is constructed without it.
- Confirmed offline attempt fencing, Wi-Fi policy, deletion inventory, hydration, and byte accounting are centralized and must all be extended rather than bypassed.
- No simulator was booted or used. No physical-device acceptance has been claimed.

### 2026-07-20 — implementation and automated acceptance

- Added privacy-safe authenticated request/decoder coverage for `ThumbnailSet`, per-position Thumbnail images, and selected-source `index.bif`.
- Added the shared online hierarchy and offline cached-BIF-first hierarchy without changing seek semantics.
- Added migration-safe selected-source persistence, source-scoped preservation, optional side-asset pacing/coalescing, Wi-Fi policy, attempt fencing, rehydrate budgeting, deletion inventory, and byte accounting.
- Added hierarchy, malformed BIF, chapter fallback, media-source, auth, cancellation, coalescing, migration, deletion, accounting, and replacement-attempt tests.
- Full PMSKit: 1,603 tests passed. Full macOS app suite: 316 tests passed. The first full macOS run exposed one unrelated search-fanout timing failure; its focused suite passed (6 tests) and the complete rerun passed.
- Unsigned generic-device builds passed for visionOS and iOS/iPadOS; the macOS build and tests passed. No simulator was booted or targeted.
- `scripts/ci-hygiene.sh` passed, including strict MkDocs, repository documentation checks, Mermaid validation, and 48 tooling tests.

### 2026-07-20 — privacy-safe live Emby proof

- Ran the GET-only probe against the ignored local Emby configuration without printing host, token, user/item/source identity, title, filename, URL, or payload.
- The selected source existed; `ThumbnailSet` returned HTTP 200 JSON and decoded 623 generated frames.
- The advertised per-position Thumbnail returned HTTP 200 JPEG with a valid image signature.
- `index.bif` returned HTTP 200 and parsed as 623 frames (6,344,664 bytes).
- This satisfies the positive generated-preview server gate for the request/decoder hierarchy. It is not an offline-download or physical-device claim.

### 2026-07-20 — issue handoff

- Committed the implementation and automated coverage as `6296e113` on `codex/issue-238-emby-bif`.
- Posted the privacy-safe [implementation and acceptance update](https://github.com/jlipworth/Labstream/issues/238#issuecomment-5024396927) with tests, builds, live proof, fallback results, plan status, and both remaining real gates.
- Left #238 open; did not merge to `main` or claim simulator, physical-device, empty-library, or offline-download proof that was not performed.

## Remaining external truth

Two live gates remain deliberately open: (1) a real item/library with preview extraction absent must confirm the empty/unavailable `ThumbnailSet` and silent chapter fallback shape; (2) a real offline download must prove selected-source BIF publication and cached-BIF playback preference while retaining chapter fallback. The automated empty/malformed/fallback, source-identity, deletion, accounting, and attempt-replacement paths are green, but they do not fabricate either real-server result. Issue #238 remains open and this plan stays active/resumable.
