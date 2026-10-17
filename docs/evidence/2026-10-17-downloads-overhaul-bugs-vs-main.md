# Downloads overhaul: bugs versus main

**Immutable audit date:** 2026-10-17. **Compared revisions:** `main` merge-base `f43dfce7`
and P1–P7 implementation at `0e7bae0f` (`downloads/p7-mediabrowser-ux`). This records the
pre-release documentation checkpoint before the separate P7 review fixes/dead-facade cleanup
and P7.7 release commit. It is not a live-server, simulator or device acceptance report.

The source inventory is the overhaul plan's Appendix A and final per-phase journals, checked
against the implementation and named test sources at this revision. The active
[plan](../plans/2026-10-16-downloads-overhaul.md) owns remaining work; canonical contracts live in
[Downloads and offline](../DOWNLOADS-OFFLINE.md) and [Persistence](../PERSISTENCE.md).
Raw private evidence is excluded. No new app tests, builds or live probes were run for this audit.

## Reading the dispositions

- **fixed:** the scoped defect has an implementation and a named guard in the stack; this does
  not assert live acceptance or that every structural proposal was implemented.
- **retained/refuted:** the original claim was refuted/misdiagnosed, or the deliberate policy is
  retained. No fabricated fix or red-to-green claim is implied.
- **deferred:** the defect or decision remains unresolved, with its reason below.

Severity is the original Appendix A assessment, including uncertain findings. B00 is included
alongside B01–B85. B23/B40 remain explicit aliases of B01/B28, and B44/B49 overlap; counts describe
inventory rows, not independent root causes. Suite names identify guarding coverage, not proof
that each individual pin was reproduced red. Source guards, retained controls and missing pins
are labeled. P1 #371, P2 #374, P3a #375, P3b #376, P4 #385, P5 #387 and P6 #388 identify the
stacked PRs; P7 has no PR at this checkpoint.

## Bug dispositions

| Bug ID | One-line defect on main | Severity | Status | Fixing phase/PR | Guarding pin or test name |
| --- | --- | --- | --- | --- | --- |
| B00 | Static stale-row recovery reads the published path and can discard the real attempt checkpoint. | high | fixed | P1 #371 | DownloadRetryPolicyTests; BackgroundDownloadRangeOwnershipTests |
| B01 | Resume free-space preflight charges the whole file instead of the remaining physical work. | high | fixed | P1 #371; unified in P5 #387 | DownloadDiskSpacePolicyTests; DownloadStorageAdmissionPolicyTests |
| B02 | Late reattach/rebuild/auth work can restart an attempt after user Pause. | medium | fixed | P1 #371; completed by P5 #387 | BackgroundReattachTaskGatePolicyTests; P5SessionTransportTests |
| B03 | A stash sweep can unlink a body whose append/publication is still queued. | medium | fixed | P5 #387 | P5SessionTransportTests (pin 12) |
| B04 | Delayed retries can release the completion gate before successor work is registered. | medium | fixed | P5 #387 | P5SessionTransportTests (pins 8–9) |
| B05 | A runtime admission block aborts a live transport’s background holds. | medium | fixed | P1 #371 | BackgroundDownloadStartupAdmissionTests |
| B06 | A handler arriving while startup is blocked/dormant can remain unreleased (originally uncertain). | medium | fixed | P6 #388 | P6BackgroundWakeTests.startupFailure |
| B07 | Post-construction activation failure rejects healthy owned callbacks and finished bodies. | medium | fixed | P1 #371 | BackgroundDownloadRangeOwnershipTests; BackgroundDownloadStartupAdmissionTests |
| B08 | Optimistic progress resets the retry budget, allowing unbounded repeated segment fetches. | medium | fixed | P5 #387 | P5SessionTransportTests (pin 10); BackgroundDownloadTransientRetryPolicyTests |
| B09 | OS cancellation is silently treated as user cancellation and later progress can undo parking. | medium | fixed | P1 #371; completed by P3a #375 | DownloadLifecycleStoreTests; BackgroundDownloadRangeOwnershipTests |
| B10 | Process death during forward-only finalization loses the completed body. | medium | fixed | P3a #375 | DownloadLifecycleStoreTests; DownloadLifecycleReducerTests |
| B11 | MainActor handler registration can race finish-events (originally uncertain). | low | fixed | P1 #371 | BackgroundDownloadCompletionRegistryTests |
| B12 | Range/error callbacks lack exact attempt identity and can affect a replacement. | low | fixed | P5 #387 | P5SessionTransportTests (auth/manager handoff controls) |
| B13 | Anonymous leaked background operations have no time bound (originally uncertain). | low | fixed | P6 #388 | P6BackgroundWakeTests.operationDeadline |
| B14 | HEVC fixup misses sample entries outside its front/back scan windows. | low | fixed | P5 #387 | HEVCTagFixupTests (pin 13) |
| B15 | A second index read failure can admit an empty store and overwrite the real index. | medium | fixed | P1 #371 | DownloadStorePersistenceTests |
| B16 | Cached unreadable admission makes Retry Recovery ineffective and hides local media. | high | fixed | P3a #375 | DownloadLifecycleStoreTests; P7OfflineAvailabilityTests |
| B17 | Failed artifact heads grow live bookkeeping and retry on unrelated commits. | medium | fixed | P6 #388 | P6ArtifactRetryTests.failedHeadGrowth; unrelatedCommitDoesNotRetry |
| B18 | Cleanup authority lacks reliable backup/protection and full-sync commit semantics. | medium | fixed | P2 #374 | DurableJournalCommitTests; DownloadCleanupIntentJournalTests |
| B19 | Hidden staging and pending artifacts are missing from storage audit accounting. | high | fixed | P6 #388 | P6StoreInventoryTests.auditAllBytes; OfflineDownloadFileInventoryTests |
| B20 | Reconcile does filesystem work under the store lock and leaves stale resume references. | medium | fixed | P6 #388 | P6ReconcileCleanupTests; P6StoreIOTests; P6PathLeaseTests |
| B21 | Indeterminate season persistence is mislabeled unreadable and blocks recovery indefinitely. | medium | fixed | P3a #375 | DownloadLifecycleStoreTests |
| B22 | Held-body sweep can delete a newly written, not-yet-manifested body. | low | fixed | P5 #387 | P5SessionTransportTests (durable sweep and rename-to-manifest controls) |
| B23 | Start preflight recharges the full size for an existing partial (duplicate of B01). | high | fixed | P5 #387 | DownloadStorageAdmissionPolicyTests (alias B01) |
| B24 | Storage cap double-counts a retry and omits active rows’ remaining reservations. | high | fixed | P5 #387 | DownloadStorageAdmissionPolicyTests; SeasonPlannerIntegrationTests |
| B25 | Completed Plex repair refetches source metadata outside side-asset rate limiting. | high | fixed | P1 #371 | SideAssetFetchCoordinatorTests |
| B26 | Forward-only ENOSPC fails to surface the storage-full classification. | medium | fixed | P1 #371 | BackgroundOpaqueCompletionPolicyTests |
| B27 | Delete is refused by a pending legacy validated promotion; wedged-head preemption is absent. | medium | deferred | P6 #388 scoped out | DownloadArtifactLifecycleTests retains normal queue handling; no preemption pin |
| B28 | Plex prep Delete cancels non-durably, before deletion proof, and misses paused prep. | medium | fixed | P2 #374 | DownloadDeletePolicyTests; CleanupRunnerManagerTests; CleanupAuthorityContractTests |
| B29 | Claim: ownerless-row Delete silently returns; branch is dead under current ownership. | low | retained/refuted | Refuted; P6 #388 preserves exact-owner contract | Exact-attempt deletion contract; refuted dead branch, no failing behavioural pin |
| B30 | A completely full volume can prevent durable Delete intent creation and space reclamation. | medium | deferred | P6 #388 scoped out | DownloadStoreFaultInjectionTests retains safe failure; no emergency-reclaim pin |
| B31 | Storage-full park history exists only in memory. | medium | fixed | P3a #375 | DownloadLifecycleReducerTests; DownloadLifecycleStoreTests |
| B32 | Asynchronous side-asset park/unpark/cancel controls can arrive out of order. | low | fixed | P7 PR pending | P7SideAssetOrderingTests (pin 14) |
| B33 | Plex rendered-Part handoff uses enqueue-time credentials instead of the observed live lane. | medium | fixed | P4 #385 | ServerPrepRunnerIntegrationTests.plexHandoffUsesObservedLiveLane |
| B34 | Plex optimize Retry loses the requested tier and uses the global default. | high | fixed | P1 #371 | DownloadBackendRetryIntentPolicyTests |
| B35 | Fresh Plex prep creates a job before adopting a matching existing render. | high | fixed | P4 #385 | ServerPrepRunnerIntegrationTests.plexAdoptsWithoutCreatingAnotherRender |
| B36 | An explicit existing-version download can incorrectly fall back to a new Plex optimize. | high | fixed | P1 #371 | PlexOriginalFallbackPolicyTests |
| B37 | A swallowed optimize-create error can leave preparation pending for a day. | high | fixed | P4 #385 | ServerPrepRunnerIntegrationTests.plexProvenMissingCreateFailsAfterGrace |
| B38 | Optimizer fallback Location identifies the client rather than the server. | medium | fixed | P1 #371 | OptimizePlaylistTests |
| B39 | Background-job progress can be attributed to another client/item. | medium | fixed | P1 #371 | BackgroundQueueTests |
| B40 | Paused Plex prep Delete never cancels its unfinished server job (duplicate of B28). | high | fixed | P2 #374 | DownloadDeletePolicyTests; CleanupRunnerManagerTests (alias B28) |
| B41 | Plex original/final-validation fallback can create optimize work without a storage-cap gate. | medium | fixed | P5 #387 | SeasonPlannerIntegrationTests (fallback cap control) |
| B42 | Plex type-42 completion-state vocabularies disagree. | low | fixed | P1 #371 | PlexOptimizeCompletionPolicyTests |
| B43 | Audio override by stream index can be sent as a different Plex stream ID. | low | fixed | P1 #371 | DownloadMediaSelectionPolicyTests |
| B44 | Launch cleanup deletes Convert work retained by a failed row for Retry. | high | fixed | P1 #371 containment; P2 #374 | DownloadCleanupOrderingTests; CleanupIntentEligibilityPolicyTests |
| B45 | Emby Convert treats a synthetic media index as the original MediaSource ID. | high | fixed | P1 #371 | EmbyConvertedSourcePolicyTests |
| B46 | Convert fallback can adopt an old sibling/original without proving a new output. | medium | fixed | P1 #371 | EmbyConvertedSourcePolicyTests |
| B47 | Pause during Convert creation cancels the job while retaining ambiguous-create authority. | medium | fixed | P1 #371 | EmbyConvertJobTests |
| B48 | An unmodeled terminal Convert error polls indefinitely. | medium | fixed | P1 #371 | EmbyConvertJobTests |
| B49 | Ambiguous-create cleanup races failed-row Convert recovery. | medium | fixed | P1 #371 containment; P2 #374 | DownloadCleanupOrderingTests; CleanupIntentEligibilityPolicyTests |
| B50 | Some Convert cancellation paths are fire-and-forget without durable intent. | medium | fixed | P2 #374 | DownloadCleanupIntentRunnerTests; CleanupRunnerManagerTests |
| B51 | Convert retry/relaunch loses original text-subtitle source and repairs the wrong source. | medium | fixed | P7 PR pending | P7SubtitleSourceRecoveryTests; P7JoinedDownloadControlsTests |
| B52 | Convert ownership compares user identity differently from backend session matching. | low | fixed | P1 #371 | EmbyConvertJobTests |
| B53 | Claim: missing Container forces an unsafe static mp4 retry; route actually fails closed. | low | retained/refuted | Refuted in P1 #371 | EmbyDownloadRouterTests (B53 fail-closed control) |
| B54 | A repeated-truncation parked forward body is lost or deleted after relaunch. | high | fixed | P1 #371 publication; P3a #375 history | BackgroundDownloadStartupAdmissionTests; DownloadLifecycleStoreTests |
| B55 | Jellyfin keepalive emits Playing/Progress that can alter watch state; Ping-only safety is unproven. | medium | deferred | D3 blocked; P1 #371 interim retained in P7 | JellyfinDownloadKeepalivePolicyTests pins interim only; live A/B blocked |
| B56 | Missing MediaSource sizes hide Original/remux costs from storage gates. | high | fixed | P5 #387 | MediaBrowserSourceSizeTests; DownloadStorageAdmissionPolicyTests |
| B57 | Comma-list container metadata disagrees across eligibility, request and file extension. | low | fixed | P7 PR pending | P7DownloadContainerTests; P7JoinedDownloadControlsTests |
| B58 | Remux audio-copy eligibility uses the first audio track instead of the selected track. | medium | fixed | P1 #371 | JellyfinPlaybackTests |
| B59 | A missing requested source silently becomes a different edition. | medium | fixed | P1 #371 | JellyfinPlaybackTests; P7MediaBrowserNegotiationTests.explicitMissingSourceFailsClosed |
| B60 | Keepalive continues for a row with no tracked transfer. | medium | fixed | P1 #371 | DownloadKeepaliveTransferGateTests; DownloadKeepaliveCoordinatorTests |
| B61 | A reported remux length excludes forward-only work from the stall watchdog. | low | fixed | P3a #375 | DownloadStallRecoveryPolicyTests |
| B62 | Prep recovery attaches planned season rows outside admission caps. | medium | fixed | P4 #385 | SeasonPlannerIntegrationTests (prep scanner skips planned rows) |
| B63 | Resume All starts parked season rows without the shared lane window. | high | fixed | P4 #385 | SeasonPlannerIntegrationTests; DownloadAdmissionPolicyTests |
| B64 | Claim: waiting-row Pause never persists; refuted, with a narrower start/resume race guarded. | high | retained/refuted | Refuted; narrower race guarded in P4 #385 | SeasonPlannerIntegrationTests (waiting Pause/Resume race); original claim refuted |
| B65 | Resume bypasses admission and leaves contradictory planned-row state (original claim overstated). | medium | fixed | P4 #385 | SeasonPlannerIntegrationTests; DownloadLifecycleReducerTests |
| B66 | Clearing pending admission before a proven start leaves orphan queued rows. | medium | fixed | P4 #385 | DownloadAdmissionCoordinatorTests; DownloadLifecycleReducerTests |
| B67 | A temporary backend outage turns season admission into permanent failure. | medium | fixed | P4 #385 | SeasonPlannerIntegrationTests (refresh outage defers) |
| B68 | Season planning repeats the interactive Emby refresh/poll for every episode. | high | fixed | P1 #371 | DownloadExistingVersionDiscoveryTests; SeasonDownloadPlannerSheetTests |
| B69 | A transient Original probe error is treated as permanently unsupported. | medium | fixed | P4 #385 | SeasonDownloadPlanningPolicyTests; DownloadAdmissionPolicyTests |
| B70 | The season sheet reads a changing active backend instead of capturing its presentation owner. | low | fixed | P1 #371 | SeasonDownloadPlannerSheetTests (source guard, not mounted-SwiftUI proof) |
| B71 | Duplicate item keys can trap season-sheet state construction. | low | fixed | P1 #371 | SeasonDownloadPlannerSheetTests |
| B72 | Admission undercounts async starts across passes. | low | fixed | P4 #385 | DownloadAdmissionPolicyTests; SeasonPlannerIntegrationTests |
| B73 | Detail Play Offline does not save position or verify eligible local playback. | high | fixed | P7 PR pending | P7OfflinePlaybackTests.detailProgressSavesLocalPosition |
| B74 | Saved position or startup promotes unverified/truncated files without actual playing. | medium | fixed | P7 PR pending | P7OfflinePlaybackTests.actualPlayingAtZeroVerifiesWithoutProgress; P7OfflineLifecycleTests |
| B75 | Player callbacks write whichever attempt is current rather than the playing attempt. | medium | fixed | P7 PR pending | P7OfflinePlaybackTests.replacedAttemptRejectsOldPlayerClose; oldSessionCloseCannotOverwriteReopenAfterHeldCommit |
| B76 | Offline position/pause/play saves synchronously block MainActor on durable persistence. | medium | fixed | P6 #388; P7 PR pending coalescing | P6ManagerPersistenceTests; P7OfflinePlaybackTests.heldCommitCoalescesPendingSamplesAndRetainsClose |
| B77 | Offline Reconnect does not repeat inactive-backend hydration and encoder cleanup. | medium | fixed | P1 #371 | LaunchDownloadRecoveryGateTests |
| B78 | A restricted Offline Cinema return can replay after Reconnect. | low | fixed | P7 PR pending | P7OfflineReturnTests |
| B79 | The launch gate stats every row during view-body evaluation. | low | fixed | P7 PR pending | P7OfflineAvailabilityTests |
| B80 | Sidecars hide subtitle tracks embedded in the local file. | medium | fixed | P7 PR pending | P7OfflineSubtitleTests |
| B81 | Known side assets turn unknown media size into a falsely known extras-only estimate. | high | fixed | P5 #387 | DownloadStorageEstimatePolicyTests |
| B82 | Balanced background operations can exceed the aggregate OS wake budget. | medium | fixed | P6 #388 | P6BackgroundWakeTests (pins 8–9) |
| B83 | Inherited completed bodies plus side assets have no proven global memory ceiling. | low | deferred | P6 #388 scoped out | P6BackgroundWakeTests retains bounded-wake controls; no process-wide memory ceiling pin |
| B84 | A duplicate-row loader initializer can trap; current admission already blocks duplicates. | low | fixed | P6 #388 | P6StoreLoadSafetyTests.checkedIngestion (source guard plus byte conservation) |
| B85 | Static append re-copies bodies without measuring/bounding lifetime write amplification. | low | deferred | P6 #388 scoped out | No amplification measurement/zero-copy pin; bounded-copy behaviour retained |

B20 is fixed for lock-held I/O, stale resume authority and physical path exclusion; generalized
durable working-body recipes remain deferred. B51 is fixed for new/provable original source
identity; ambiguous historical rows intentionally skip repair. B70 retains only its source guard,
not mounted-view behavioural proof. B84 removes a latent trapping initializer while retaining the
already-existing whole-index duplicate block; this is not a newly demonstrated duplicate crash.
B06/B11/B13 were uncertain safety findings, not confirmed causes of the field termination.

## Additional store and planner inventory

These relevant Appendix B rows supplement or clarify the bug audit. Their severities are this
audit's risk classification (Appendix B had none). Aliases are retained to make preservation and
intentional scope choices visible; they are counted separately from B00–B85.

| Bug ID | One-line defect on main | Severity | Status | Fixing phase/PR | Guarding pin or test name |
| --- | --- | --- | --- | --- | --- |
| st-02 | Unsafe decoded paths can reach destructive I/O without a complete validation boundary. | high | fixed | P6 #388 | P6StoreIOTests (unsafe-path controls) |
| st-03 | Authority backup/protection coverage is incomplete. | medium | fixed | P2 #374; P6 #388 retained | DurableJournalCommitTests; DownloadStoreFaultInjectionTests |
| st-08 | Claim: one corrupt row should be silently salvaged into a writable partial library. | medium | retained/refuted | P6 #388 retains fail-closed policy | DownloadStoreFaultInjectionTests; DownloadIndexCodingTests |
| st-09 | Duplicate current row keys can reach a trapping loader initializer (B84). | low | fixed | P6 #388 | P6StoreLoadSafetyTests.checkedIngestion |
| st-17 | A per-flush budget alone does not bound the whole background wake (B82). | medium | fixed | P6 #388 | P6BackgroundWakeTests.proofMustCoverResultingBoundary |
| st-23 | Held-body sweep can steal a writer’s not-yet-manifested path (B22). | medium | fixed | P5 #387; P6 #388 leases | P5SessionTransportTests; P6PathLeaseTests |
| st-35 | Off-lock path checks need physical exclusion for cross-kind pending references. | high | fixed | P6 #388 | P6ReconcileCleanupTests; P6PathLeaseTests; P6SessionPathLeaseTests |
| st-38 | Ghost-storage audit loses hidden/pending byte visibility (B19). | high | fixed | P6 #388 | P6StoreInventoryTests.auditAllBytes |
| st-39 | General stable-media/side-asset launch orphan reclamation is absent. | low | deferred | P6 #388 scoped out | Report-only audit controls; no generalized deletion pin |
| st-40 | Failed lifecycle epochs accumulate or lose exact waiter outcomes (B17). | medium | fixed | P6 #388 | P6ArtifactRetryTests; P6StoreResolutionTests |
| st-41 | Store-lock filesystem/journal work blocks delegate and MainActor progress. | high | fixed | P3a #375; P6 #388 | P6StoreIOTests; P6ManagerReworkTests; P6ReviewRegressionTests |
| st-42 | An older decoder cannot accept new pending-intent enum cases. | low | retained/refuted | P3a #375; P6 #388 compatibility retained | DownloadIndexCodingTests; DownloadSchemaUpgradeTests |
| pu-13 | Unknown media can bypass the season unknown-size confirmation (B81). | high | fixed | P5 #387 | DownloadStorageEstimatePolicyTests; SeasonDownloadPlanningPolicyTests |
| pu-24 | A stale rendered action can target a replacement attempt. | medium | fixed | P4 #385; P7 PR pending sheets | SeasonPlannerIntegrationTests; P7DownloadRowsTests |
| pu-25 | Duplicated row classifiers can disagree about finalizing and waiting. | medium | fixed | P7 PR pending | P7DownloadPresentationTests; P7DownloadRowsTests |
| pu-31 | Claim: old checkpoint-drain pause caption must return. | low | retained/refuted | Intentionally dropped; P7 retains current pause semantics | DownloadRowStatusCaptionPolicyTests |
| pu-33 | Season-pending rows look active despite having no transport. | medium | fixed | P4 #385; P7 PR pending parity | P7DownloadPresentationTests; P7DownloadRowsTests |

## Counts

B00–B85: **78 fixed, 3 retained/refuted, 5 deferred; 86 rows**.

| Original area | Fixed | Retained/refuted | Deferred | Total |
| --- | ---: | ---: | ---: | ---: |
| bg-session | 15 | 0 | 0 | 15 |
| store | 9 | 0 | 0 | 9 |
| storage-delete | 8 | 1 | 3 | 12 |
| plex | 11 | 0 | 0 | 11 |
| emby | 9 | 1 | 0 | 10 |
| jellyfin | 7 | 0 | 1 | 8 |
| planner-ui | 10 | 1 | 0 | 11 |
| offline-playback | 8 | 0 | 0 | 8 |
| background-wake | 1 | 0 | 1 | 2 |

Additional st-/pu- inventory: **13 fixed, 3 retained/refuted,
1 deferred; 17 rows**. Store: 9 fixed, 2 retained/refuted, 1 deferred (12 rows).
Planner/UI: 4 fixed, 1 retained/refuted, 0 deferred (5 rows).
Combined row count: **91 fixed,
6 retained/refuted,
6 deferred; 103 rows**.

## Build-1506 field-report verdict

The leading hypothesis was watchdog pressure from recovery fan-out and synchronous MainActor
persistence; aggregate wake duration and reattach/append ownership were alternatives. P4 bounds
new admission; P5 fixes retry/claim races; **P6 addresses the leading hypothesis** with worker-backed
persistence, off-lock I/O, path exclusion and an absolute wake budget. This is **addressed, not
confirmed**. The report has no termination signature. The matching **`.ips`/JetsamEvent is still
needed** before attributing the termination or claiming that it cannot recur. Hosted heartbeats,
fake-clock deadlines and bounded copy buffers do not establish hardware scheduling, process-wide
memory bounds or lifetime disk-write amplification.

## Deferred items and reasons

| Item | Reason / retained behaviour |
| --- | --- |
| B27 | Preempting a wedged legacy validated promotion needs safe cancellation/publication rules. Ordinary queued Delete and failed-head recovery remain. |
| B30 | Full-volume Delete can fail before a durable prepared intent exists. Reserved journal capacity or an emergency deletion protocol is needed; durability ordering is retained. |
| B55 / D3 / jf-11 | Ping-only Jellyfin live A/B is blocked. Fixed-zero Playing/Progress remains interim; encoder lifetime and watch-state neutrality are unproven. Emby Ping-only is retained. |
| B83 | Global accounting/backpressure for inherited completed bodies plus side assets is absent. Serial bounded-buffer append and admission caps do not prove a global ceiling. |
| B85 | Zero-copy/extent redesign and lifetime amplification measurement are separate work. A wake deadline does not bound bytes written. |
| st-39 | General stable-media/side-asset orphan deletion needs wider liveness proofs. Audit remains report-only; startup staging cleanup stays narrowly inventoried. |
| B20 structural remainder | Generalized durable reconcile body recipes add schema/rollback obligations; conservative deferral and retained recovery authority remain. |
| D4 / op-06, op-33, emby-44 | Progress/watched sync-back, offline Up Next, season grouping and Premiere detection require separate product/ownership work. |
| Historical B51 | Missing or ambiguous original subtitle-source identity cannot safely be reconstructed from a converted source or array index; keep cached assets and skip repair. |
| B70 expanded proof | A new mounted-SwiftUI inspection framework is disproportionate here. The captured-owner fix/source guard remains; semantic UI acceptance stays open. |
| op-13, op-17, op-24, op-30, jf-26 | Post-sign-out local entitlement, bitmap subtitles, broader HDR/DV delivery, legacy-owner reconstruction and a new forward-stream retry strategy are separately scoped decisions. Preserve current safe behaviour. |
| Paused-static finish-before-reattach | Preserving delivered bytes is not proof of a publishable whole file. Write-then-pause remains; complete-file finalization needs its own pin. |
| Structural consolidation | Full store split/actor conversion, universal filesystem/result systems, restart-state packaging, unified owned-work snapshots and DEBUG extraction have no required defect beyond the targeted fixes. Legacy metadata-poor opaque resume remains compatible. Dead facade deletion is a separate lane. |
| P7 review follow-ups | Cleanup-journal async paths, sign-out recovery replay and orientation restoration on rejection are in the parallel code lane, outside this frozen comparison. |

## Open acceptance gates

- Live Plex, Jellyfin and Emby acceptance for shared behaviour, including negotiated exact sources,
  Convert/optimizer handoff, subtitles and inspected decoded frames.
- Physical iPhone/iPad/Vision Pro acceptance: rotation, accessibility/layout, Cinema return,
  background continuation, lock/off-head recovery, network policy and HDR/DV. Mac host background
  recovery and interaction acceptance remain open too.
- D3 Jellyfin Ping-only A/B remains **blocked**, with no watch-state neutrality verdict.
- P7.7 coordinated 1.8.0 source bump and release note, then separately authorized TestFlight
  archive/upload/distribution and device acceptance. No live/device/TestFlight pass is claimed here.
