# Downloads manager overhaul

**Status (2026-10-17):** P1–P6 and P7.1–P7.6 implementation are in the stack through
`0e7bae0f`. P7 review fixes and dead-facade cleanup are parallel integration lanes. P7.7 (the
coordinated 1.8.0 source bump and release note) and external acceptance remain open. This plan
stays active in `docs/plans/` until release work is complete; do not archive it yet.

**Scope:** the shared visionOS, iOS/iPadOS and macOS download engine, backend download policies,
local playback and row presentation. tvOS remains streaming-only and compiles no Downloads
capability. No live-server or physical-device acceptance is implied by implementation completion.

**Evidence:** the immutable [bugs versus main audit](../evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md)
compares merge-base `f43dfce7` with `0e7bae0f`, records B00–B87 plus relevant store/planner
items, named guards, status/area counts and limits. Git history retains superseded designs,
review rounds, line maps and detailed lane journals; they are not repeated here.

## Maintainer decisions (2026-10-16)

| Decision | Current contract |
| --- | --- |
| Scope | Holistic, bottom-up overhaul; one coherent program, separate phase PRs. |
| D1 | Keep complete, unverified and **paused static-range rows, including zero-byte partials** during v4-to-v5 upgrade. Retire other candidates through ordinary journal-first Delete. The final partial-preservation refinement supersedes the original all-in-flight reset proposal. |
| D2 | Delete cancels supported unfinished server preparation, including paused prep. Finished server versions remain. Plex has an accepted GET-to-DELETE completion race; UI says cancellation is possible where supported. |
| D3 | Jellyfin Ping-only keepalive requires a live A/B. The opt-in `LiveJellyfinDownloadKeepaliveProbeTests` uses Quick Connect and does not deliberately mutate watch state. The A/B is blocked: retain fixed-zero Playing/Progress interim, with no neutrality claim. Emby stays Ping-only. |
| D4 | Separate work: offline progress/watched sync-back, offline Up Next, Offline season grouping and Emby Premiere detection. |
| D5 | The cellular preference also governs constrained/Low Data Mode and expensive/hotspot networks for new request-based transfers and side assets. Active/resume-data tasks retain creation policy. |
| Public hygiene | P1 removed the identifying media comment. Public history is retained; no history rewrite, personal identifiers or credentials belong in this plan. |

## Target design

The design is incremental: keep the segment train, exact-attempt authority and artifact durability,
then centralize decisions and remove critical-path waits. Several originally proposed structural
refactors were deliberately not needed for the scoped defects; see [Deferred work](#deferred-work).

Current implementations and detailed invariants belong in the canonical pages:

- [Downloads and offline](../DOWNLOADS-OFFLINE.md): routes, lifecycle, truncation, bounded wakes,
  admission, server preparation, cleanup, storage, local playback and shared rows.
- [Persistence](../PERSISTENCE.md#download-store-execution-and-file-ownership): schema v5, D1,
  exact tickets, worker observations, path leases, upgrade failure boundaries and subtitle origin.
- [Playback](../PLAYBACK-ARCHITECTURE.md#localoffline-playback): one launch factory, actual-playing
  verification, exact event sinks and combined embedded/sidecar subtitles.
- [Code map](../CODE-MAP.md#download-subsystem-file-guide): every added subsystem file and role.
- [Backends](../BACKENDS.md#download-negotiation-and-lifecycle): MediaBrowser negotiation,
  first-container token, original subtitle source and backend-specific keepalive.
- [Testing strategy](../TESTING-STRATEGY.md#downloads-overhaul-pin-suites): phase guards and hosted
  commands, including `macos-hosted` and normal-parallel final gating.

The retained architecture has these boundaries:

1. One pure reducer owns lifecycle/history. Immutable attempt/source identity, artifacts, server
   obligations and history remain separate durable facts; status is a compatibility projection.
2. One event-driven admission window supervises taps, season starts, Resume All, retries and
   recovery. Static 2, prep 1, live-forward 1, total 3 are the normal caps. Existing OS work is
   observed first, and prep-to-static handoff can temporarily occupy a third static lane.
3. Plex and Emby preparation use registered pollers. Existing matching versions are adopted
   before create; live-lane handoff, durable dispatch grace and exact ownership survive awaits.
4. One independent cleanup journal retains server authority. Runner eligibility, claims and
   exact server/user checks prevent cleanup from cancelling resumable failed-row work.
5. One physical/cap storage policy counts retained/checkpoint bytes once, known remaining
   reservations, usable held-body credit, append-copy peak, future side assets and headroom.
6. The store retains its lock/worker structure. Typed asynchronous resolution bounds waiters;
   physical path leases and durable intents outlive a timeout. A timeout never proves success.
7. One local factory admits the exact rendered attempt after orientation. Metadata owns assets,
   local resume/rewind applies once, and actual playing is separate from coalesced position saves.
8. Shared row presentation/content carries waiting, preparation, verification, pause, error,
   progress, quality and accessibility semantics across Offline and all download sheets.

## What stays as it is (load-bearing, proven)

- Known static totals use 512 MiB closed segments, depth two per row, exact segment markers,
  validator checks, held-body assembly and durable checkpoint alignment. Unknown totals retain
  the open-ended fallback and strictly matched OS resume authority.
- Captured body → HEVC fixup → completion/probe validation → validated publication remains the
  order. Inconclusive probe and repeated-truncation states preserve playable bytes.
- Exact attempt ownership rejects stale callbacks, rebuild timers, task adoption, source repair,
  player saves and destructive actions. An operation ID is not substitute attempt authority.
- Background handler registration is activation-neutral. Exact tokens, generation fencing,
  bounded combined index/artifact proof and explicit timeout outcomes remain separate concepts.
- Startup keeps transport dormant until index admission. Unsupported old schemas drain tasks
  twice before quarantine/reset; unreadable, malformed, duplicate and newer inputs fail closed.
- macOS keeps per-bundle session identity and no UIKit relaunch-for-events claim. CFNetwork
  temporary files are observed, never deleted by app cleanup.
- `OptimizedVersionMatch` tier/playability checks remain. Keep
  `X-Plex-Client-Profile-Name=Generic` exactly; explicit profile-extra does not replace that name.
- Restricted Offline still requires a saved session with a transient restore failure and a real
  terminal local file. Missing/revoked credentials do not become offline authorization.

## Migration (v4 → v5): current outcome

The implemented upgrade is not the abandoned digest-receipt migration or a drain-and-drop-all
rewrite. It runs after activation and before startup publishes ready:

1. Fix the candidate set from the admitted v4 rows. Preserve complete, unverified and every
   paused static row; respect existing deletion barriers/capsules and legacy promotion rescue.
2. Retire other candidates through ordinary exact-attempt Delete. Halt daemon tasks, pollers and
   keepalive, journal server obligations or retain cleanup capsules, then run artifact work.
3. Rescue a candidate only if completion makes it terminal during this pass. A newly observed
   partial alone does not change the fixed removal decision.
4. Save the full-attempt-key removal/cleanup-gap notice durably before enqueueing the v5 stamp.
   Failed notice persistence retains v4 and a fallback notice union for retry.
5. Publish ready only after upgrade fences finish. Snapshots capture schema at enqueue time:
   v4 remains v4 before stamp and later snapshots are v5. A crash before stamp reclassifies the
   remaining committed v4 rows; already barriered removals remain recoverable.

No new generalized artifact enum or migration receipt format was introduced. Unreadable or
malformed v4 is not destructively reset. Older guarded binaries keep newer schema bytes opaque;
downgrades before the P1 guard remain a release compatibility limitation. Optional
`textSubtitleSourceMediaSourceID` is additive to v5 and does not create a new schema version.

## Phases (one PR per phase)

| Phase | PR | Compact outcome |
| --- | --- | --- |
| P1 | #371 | Endpoint fixes/containment, exact ownership and pause guards, source/audio fidelity, D5, field diagnostics and D3 probe/interim. |
| P2 | #374 | Full-sync cleanup authority, Plex intents, provenance/claims, one runner, legacy import and journal-first cancels. |
| P3a | #375 | Additive lifecycle/history, reducer call-site conversion, persistent finalizing/truncation/condemnation and typed recovery. |
| P3b | #376 | Schema v5, final D1 partial preservation, ordinary Delete upgrade pass, work-admission fences and durable notice. |
| P4 | #385 | Shared lane admission, supervised starts/backoff, row Pause All exemption and registered Plex/Emby prep runners. |
| P5 | #387 | Unified physical/cap accounting, source size/unknown estimates, targeted retry/claim/auth-generation/HEVC fixes. |
| P6 | #388 | Async store resolution, off-lock observations, physical leases, exact failed epochs, inventory visibility and absolute wake budget. |
| P7 | PR pending | Joined local launch/event sinks, subtitle-source preservation/menu, MediaBrowser helper/keepalive, availability/return and shared rows. Release step remains open. |

### P1 outcome

Fixed the endpoint/source defects retained by later phases, with regression coverage, and contained
failed-Convert cleanup and repeated-truncation publication. Follow-up ownership tests drive real
session callbacks: finishing bodies keep their handoff hold; system cancellation parks the whole
train; post-construction activation failure keeps owned work. B53 was refuted by fail-closed route
selection. B70 retains a source guard rather than mounted-view behavioural proof. D3 remains interim.

### P2 outcome

Cleanup writes use full-sync atomic commits in protected, backup-excluded authority storage.
Deletion, terminal-release and abandonment eligibility are distinct. Claims and captured sessions
are rechecked after awaited inspection immediately before cancellation; failed Convert jobs stay
protected for Retry. Migration/quarantine barriers rerun before runner passes, unreadable input
blocks, and waiting intents retain their own wake/backoff. Only unresolved Plex creates expire.
Legacy import readers/receipts remain compatible; physical engine cleanup is an independent lane.

### P3a outcome

Lifecycle/history became authoritative and production status writes use the reducer. Finalizing
survives relaunch, progress cannot revive a paused/failed row, and source-bound truncation outcomes
are deduplicated. Persistent condemnation blocks all same-attempt body readers and Retry cloning,
even after failed rename/removal or an overwritten failure reason. Replacement starts at zero
and inherits only applicable strikes. Retry Recovery re-probes and season-indeterminate has its own
reason. Existing artifact recipes execute effects; generalized reconcile recipes were not added.

### P3b outcome

Final D1 keeps paused static partials. Exact Delete stops tracked and marked OS work and releases
prep/keepalive; full keys prevent one legacy attempt ID cancelling another item's task. Deletion
barriers/capsules reject suspended starts, retries, pollers and season re-plans. The upgrade pass,
completion-only rescue, durable full-key notice and per-snapshot version capture replace the earlier
proposed migration protocols. Notice-save failure delays the stamp; fallback entries merge on retry.

### P4 outcome

Observed persisted/live occupancy and generation-supervised starts replace ad hoc admission.
Durable planned seeds retain first-start source/route/audio intent; parked retries keep their own
checkpoint/blob/job facts. Temporary failures defer with bounded backoff; source-missing is a
separate definitive result. Pause withdraws pending work, and only the explicitly resumed row can
bypass Pause All. Startup OS work is grandfathered; later prep scanner attachment requires room.
Plex fresh/resume shares adopt-before-create, typed queue inspection, dispatch grace and live-lane
handoff. Emby fresh/relaunch shares registered polling and a non-self-cancelling static handoff.

### P5 outcome

Every storage gate uses the same physical timeline and self-excluding cap model. Source-size
mapping fixes blind Original/remux estimates; media of unknown size remains unknown. The single
sheet is informational; the season sheet confirms unknowns. Concurrent pre-publication cap checks
are not a new atomic reservation system. Blob storage refusal keeps the blob and never falls
through to a fresh restart. Delayed retries retain gate ownership and exact attempt/train/action
generations through backend/auth hops and successor registration. Positive durable appends reset
transport-drop budget; repeated optimistic prefixes do not. Both stash sweeps respect rename-to-
manifest claims. HEVC fixup walks bounded top-level boxes and scans moov content beyond edge windows.

### P6 outcome

Production persistence callers submit and await bounded proof off MainActor. Pause/Delete fence
immediately; startup admissible load/repair and recovery cleanup use workers. Copied observations
revalidate generation after off-lock I/O. Retry, append, side-cache, condemnation and reconcile
reserve all paths through physical completion, independent of waiter expiry. Typed exact epochs
retain old failures across later success and the unclaimed 512-entry history cap. Permanent failed
heads are not retried by unrelated completion. Hidden/pending files are counted in report-only
inventory; duplicate input remains blocked with original bytes conserved. Registry receipt fixes
one non-sliding 25/20/5-second wake budget, including missing finish-events and slow flushes.
The build-1506 leading hypothesis is addressed by these mechanisms, **not confirmed** as the cause.

### P7.1–P7.6 outcome

Both production launch surfaces use the manager-owned factory and admitted-launch player. Final
admission follows orientation; presentation and playback generations are independent of attempt
identity. The exact sink separates actual playing from position and coalesces one resolving save
plus one latest sample, including close. Repeated truncation remains unverified. Combined subtitle
selection keeps embedded and sidecar mechanisms mutually exclusive and generation-fences parsing.
Shared MediaBrowser negotiation preserves selected source/audio and owning session; the first
container token is used consistently. New/provable Emby subtitle origins survive coding, reorder,
reuse, retry and handoff; ambiguous history skips repair. Side-work controls reserve monotonic
versions before suspension, including fetch entry. Both current sheets and Offline use shared row
content/presentation and exact confirmations. Off-main availability avoids body-time stats; the
restricted Cinema return is acknowledged before Reconnect. tvOS still excludes Downloads.

Sign-out captures exact encoder cleanup before revocation, parks rows promptly and resolves
journal work asynchronously before compare-clearing. After-implementation review round 1
(rework: 1 P1, 2 P2) is fixed: cleanup-runner migration barriers and backend-hydration reads use
the bounded worker seam with fresh authority after suspension; recovery journals paused
forward-only encoder handles once, replaying the index-before-journal sign-out crash window; and
both launch surfaces restore orientation after a current rejected request without overriding a
newer one. A mobile-only failure exposed a real race where a post-revocation refresh discarded a
transient encoder handle before its journal handoff was durable; the handle is now retained
until durable cleanup proof.

A simplicity review removed about 690 net lines of dead or superseded code: rating-key store
mutations, the Emby tombstone producer (legacy consumption retained), compact captions, unused
async-resolver overloads and test-only facades, with fixtures migrated to bounded submissions.

A hosted-suite flake hunt reproduced 14 intermittently failing test functions (startup and
heartbeat scheduling, checkpoint-admission timing, wake-clock overlap, shared subtitle/queue
preferences). Fixtures now wait on explicit acknowledgements, events and isolated preference
suites; no product race was demonstrated and no assertion or expiry pin was weakened. Five
consecutive full parallel Mac hosted runs then passed.

The build-1513 field report (see the evidence page) exposed two storage gaps in checkpoint
ownership handoff, fixed in P7. **B86:** startup orphan inventory now recognises hard-killed
checkpoint-copy temps through the audit's grammar, keeping startup identity, durable/pending-intent
references, live leases and post-inventory protection. **B87:** handoff admits the whole
checkpoint-copy peak plus existing headroom through the shared physical-space policy, reserving
capacity across concurrent handoffs; a refusal keeps the predecessor's owner and bytes and surfaces
the existing storage-full message. Aggregate diagnostics count copy bytes, sweep reclamation and
space refusals, without paths or identifiers.

A performance review of the whole stack judged it net better than `main` for launch, recovery and
steady-state cost, and P7 fixed its four pre-release findings. Cold launch no longer classifies,
inventories or decodes the index on MainActor: the startup worker does it once and reuses the
result, while the store stays admission-closed and Offline shows its restoring state until load
completes. Cleanup abandonment journals through the bounded worker seam, with one commit per
stale-title sweep. Row phase and fraction are published values, with resume-presence evidence
cached per exact attempt and artifact generation, so rendering performs no stats. Foreground
side-asset repair builds one off-main inventory per pass, revalidated against exact attempt and
source before dispatch. Two findings are follow-up issues: side-asset fetches can queue completed
payloads behind slow preparation (a cheap B83 improvement), and P6 async waits poll every 10 ms.

After-implementation review round 2 found two P2s in that work, both fixed: a startup load that
outlives its deadline now resolves Offline availability terminally (so recovery controls show) and
still publishes a late completion under generation fencing; and the side-asset repair inventory
now observes every owned asset, so a missing first Jellyfin tile can no longer drop references to
existing tiles. The iPhone-simulator lane exposed fixture races (premature encoder cleanup,
startup reconciliation of synthetic transfers, overlapping foreground stats) that hung or failed
only there; those fixtures now use bounded acknowledgements. Round 3 found that a load finishing
after an expired background wake still returned before publishing; readable rows and Offline
availability now publish with transport dormant, and a pending in-memory edge resumes startup on
foreground or a new wake under generation fencing.

## Verification checkpoint

These are inherited journal results, not tests rerun by this documentation lane:

- P6: hermetic PMSKit 1,616 tests; two full Mac hosted runs, 909 test functions each, including a
  clean-DerivedData run, no failures/skips; hygiene 386 tooling tests plus docs/redaction.
- P7.6: hermetic PMSKit 1,628 test functions; two full Mac hosted runs, 952 functions each
  (886 Swift Testing + 66 XCTest), normal parallelism, one expected release-pin issue, no
  unexpected failures or skips. Clean generic iOS, visionOS and tvOS builds also passed.
- Earlier isolated diagnostic runs used serialization to inspect held workers. Those are not the
  final normal-parallel acceptance. Fixture coordinator identities and worker-entry/recovery
  acknowledgements were repaired instead of widening the two-second heartbeat.

Current commands are in [Testing strategy](../TESTING-STRATEGY.md#downloads-overhaul-pin-suites).
App code lanes still need their affected native checks and owned product run. Live, interactive,
physical-device and TestFlight acceptance remain open regardless of these deterministic results.

## Unresolved validation and review work

Do not mistake an old review transcript's unclosed pin for a current implementation defect, or
helper-level coverage for end-to-end proof. The following limits remain explicit:

- P3a finalization/replay is covered at store/reducer boundaries. A full session-level crash at
  every capture/verdict boundary and a wedged writer is not established by that coverage.
- Manager-level condemned Retry → unavailable backend → backend-ready → zero-byte successor
  needs its own deterministic end-to-end pin; lower-level condemnation and retry guards remain.
- P3b has full-key marker, candidate matrix and pre-stamp crash controls. Actual daemon deletion
  races against suspended start/prep/optimize and a crash while artifact execution is held are
  not all individually pinned. Delayed snapshot schema capture is structural authority.
- P4 pause exemption, lane-full reroute, over-cap relaunch grandfathering and finalizing lane
  release have policy/code-review coverage; not every case has a dedicated manager latch test.
- Cleanup policy/claim tests do not mean every network executor has a full hermetic wire test.
- B70 remains a source-level sheet ownership guard, not a mounted SwiftUI inspection result.
- P7 real surface adapters exercise shared factories/sinks, metadata backend conflicts, missing
  local files, source/audio and subtitle parse races. They do not prove decoded playback, device
  rotation/layout/accessibility or server negotiation on real accounts.
- P7 review/code-cleanup lanes must land and pass the final combined checks before the release
  commit. The docs lane edits no source/project/version file and boots no simulator.

## Deferred work

Each deferral states why it remains separate and what behaviour is retained. There are no invented
issue numbers; attach successor issue links when the maintainer creates or chooses them.

### Open defects and safety limits

- **B27 — legacy promotion preemption.** Ordinary Delete queues behind artifact work and failed
  heads have recovery. Safely preempting a wedged legacy promotion needs cancellation/publication
  rules; keep the explicit refusal rather than weaken publication authority.
- **B30 — emergency full-volume Delete.** Preparing a durable intent can fail before freeing any
  bytes. Reserved journal capacity or an emergency protocol is needed; no bytes-first shortcut.
- **B55 / D3.** Ping-only Jellyfin evidence is absent/blocked. Fixed-zero reports stop advancing
  positions but do not prove watch-state neutrality or encoder lifetime. Keep the live A/B gate.
- **B83 — inherited backlog memory ceiling.** Serial 4 MiB append chunks, streamed bodies and P4
  new-start caps do not bound all inherited completions, captured closures or side assets.
  Whole-backlog accounting/backpressure is separate work.
- **B85 — write amplification.** Static append still copies completed bodies. A time budget does
  not bound lifetime bytes written; zero-copy/extent design and measurement remain separate.
- **B20 structural remainder.** Off-lock I/O, resume-reference clearing and physical exclusion
  are implemented. Generalized durable working-body reconcile recipes add schema/rollback work;
  retain conservative recovery and failed-cleanup authority.
- **st-39 / sd-46 wider orphan reclamation.** Audit is report-only. Stable media/side-asset deletion
  beyond the initialization-inventory staging sweep needs new liveness proofs.
- **Paused static finish-before-reattach.** Write-then-pause preserves delivered bytes. Deciding
  that they form a complete publishable file needs whole-file evidence and a dedicated pin.
- **P7 local-file lifetime.** Exact-key admission and a final stat do not guarantee open-file
  byte retention if Delete/re-download replaces a stable path during startup. Keep current file
  handling; a reproducible lifetime issue needs a separate scoped fix, not long-lived store leases.
- **Historical B51.** A converted source/array index cannot reconstruct an ambiguous original
  subtitle source. Keep cached sidecars and playable media; skip speculative repair.
- **Downgrade boundary.** No new persisted intent cases were added. Older binaries may drop
  additive history; builds predating P1's newer-schema guard are not made safe by this stack.

### Product and backend deferrals

- **D4 / op-06:** progress/watched sync-back needs durable outbound authority, replay/conflict and
  near-end/watch semantics per backend. Local positions remain local.
- **D4 / op-33:** offline Up Next/autoplay needs episode ordering, exact downloaded-source matching
  and queue lifecycle. Local launches issue no PlayQueue/NextUp requests.
- **D4 season grouping:** a hierarchy/navigation change, independent of shared row correctness.
  Keep existing episode ordering and identifiable context.
- **D4 / emby-44:** Premiere/Convert entitlement discovery needs capability and failure UX;
  preserve honest current failure and never silently substitute intent.
- **op-13:** access after explicit sign-out/revocation is a product/auth decision. Keep current
  cold-launch exclusion; cache availability is not entitlement.
- **op-17:** bitmap subtitles require OCR, burn-in or a local image renderer. Retain text/embedded
  scope; do not imply bitmap support.
- **op-24:** broader HDR/DV decoder/delivery changes are a separate cross-backend programme.
  Keep hvc1 handling and require decoded-frame/hardware evidence for touched playback.
- **op-30:** no new legacy-owner/metadata reconstruction without reliable identity. Preserve
  existing safe minimal fallback only.
- **jf-26:** a new transient forward-stream retry strategy needs validator-safe restart budgets.
  Existing bounded failure/stall restart remains; no forward byte-offset resume.
- **B70 expanded proof:** a broad mounted-SwiftUI inspection framework is disproportionate here.
  Retain focused presentation/selection checks and the source guard, with semantic gates open.

### Structural work intentionally not required

- Full store/facet split, actor conversion and wholesale ownership reorganization increase review
  surface without fixing an additional scoped defect; the lock/worker design remains.
- Universal filesystem and generic typed-result registries are unnecessary for the targeted
  ordering failures. Keep narrow seams, exact outcomes and retained-waiter semantics.
- Broad test-only/rating-key facade deletion and physical tombstone-engine cleanup are separate
  cleanup work. Preserve import readers, receipts, rollback and authority storage; reconcile the
  parallel dead-facade lane before release.
- A single restart primitive, `RangeAttemptState` packaging, unified owned-work snapshot and DEBUG
  extraction are behaviour-neutral. Keep targeted claims, generations, retry backoff and handles.
- The opaque resume fallback remains reachable for metadata-poor legacy rows; deleting it needs
  a compatibility decision.
- Fully asynchronous construction/UI-wide lookup redesign remains larger than the mapped P6
  waits. Initial classification/protection and some off-lock synchronous metadata reads remain.
- A performance baseline/benchmark campaign is not a requirement here. Deterministic held-I/O,
  counters, leases and deadline tests establish the scoped contracts without a new benchmark suite.

## Build-1506 field report

The report describes termination after waking with background downloads completed during sleep.
It has recovery fan-out but no termination signature. The leading hypothesis was watchdog pressure
from recovery starts plus synchronous MainActor persistence; unbounded wake duration and append/
reattach ownership were alternatives. P4 caps new starts, P5 targets retry/claim races and P6
addresses persistence/lock/wake pressure. This is **addressed, not confirmed**. The matching
**`.ips`/JetsamEvent is still required**; no code test proves that termination's cause or rules out
recurrence. Do not turn a missing signature into a jetsam/watchdog diagnosis.

## P7.7 Final sub-phase — version bump and release note — lead

This is the remaining final implementation step, after code integration and checks:

1. Use the repository version workflow to update all twelve marketing-version settings from
   1.7.2 to **1.8.0**: four app targets × Debug/Release/PerformanceAudit, including streaming-only
   tvOS. Verify exact count/configuration mapping statically. Keep runtime bundle identity.
2. Write the 1.8.0 source/download-overhaul note in `docs/RELEASES.md` and source columns for all
   four products. Preserve recorded 1.7.2 processed/selected distribution history. No archive,
   upload, selection, validation, device acceptance or App Review claim follows from a source bump.
3. Keep build numbering/tagging in the separately coordinated release workflow. Do not bump a
   build number or invoke release preflight just to inspect source versions.
4. Retain release/digest tooling compatibility tests. Add cases only if a real version assumption
   appears; no unconditional tooling expansion. `testflight-release.py` reads project settings,
   while `asc-digest.py` defaults to newest uploaded version, which can still be 1.7.2 after bump.
   Historical fixture versions are not stale production constants.
5. Correct the old release-page wording about a matching PMSKit version fallback if still present:
   the app takes bundle version with a neutral fallback, not a production 1.7.2 Swift constant.
6. Run focused static assertions, the release and digest unittest modules, then strict docs,
   rendered links, Mermaid and hygiene. Resolve functional defects before this final commit.

Release pin 15 remains pending until this step. This docs lane does **not** edit the project,
Swift, release page, build number, tag or distribution state.

### User-visible changes feeding the final release note

Use accepted implementation as the source, without copying a proposed note into current releases:

- Consistent download status and controls across iPhone/iPad, Vision Pro and Mac.
- Bounded shared queue, durable paused-static upgrade preservation and route-specific recovery.
- Shared Detail/Offline local resume and rewind, with exact playing-copy saves.
- Eligible verification clears only after actual playing; known truncation keeps its warning.
- Embedded and downloaded text subtitles together; proven original source retained for new Emby
  converted downloads and safe skipping of ambiguous historical repair.
- Jellyfin first-container normalization and selected-source/audio fidelity.
- Clear supported unfinished server-job cancellation and finished-version retention on Delete.
- Derived Offline availability and one-shot Cinema return before Reconnect.
- Cellular, constrained and expensive network preference remains one policy; tvOS stays streaming-only.

## Open gates (never claimed by this work)

- **Live Plex/Jellyfin/Emby:** exact variants and audio, direct/remux/encode provenance, optimizer/
  Convert reuse and handoff, deletion/failed-row recovery, embedded/sidecar subtitle selection,
  initial/reopen/seek playback and inspected decoded frames. One backend does not establish another.
- **D3:** Jellyfin Ping-only A/B remains blocked; do not infer watch-state neutrality from zero.
- **Physical iPhone/iPad/Vision Pro:** background continuation, lock/sleep/off-head, token/network
  changes, low storage, actual rotation, accessibility and layout. App-side wake bounds are not
  a scheduling guarantee.
- **visionOS:** restricted Offline → Cinema → exit → Reconnect, focus/return ownership, audio
  handoff and immersive interaction. Passive smoke is not gaze/pinch acceptance.
- **macOS:** native sheet resize/keyboard/VoiceOver, window/player teardown, sandbox identity and
  background recovery. No simulator stands in for host acceptance.
- **HDR/DV:** actual decoded video and display evidence on hardware, independently of labels or
  an advancing playhead.
- **Release/TestFlight:** P7 review lanes and final combined gate, P7.7 source commit, then separately
  authorized archive/validate/upload/distribution/selection and physical acceptance. No App Review
  submission is implied.

### Final integration checklist

- Reconcile the parallel P7 review fixes and dead-facade cleanup without changing v5's persisted
  cases, losing legacy import authority or reintroducing MainActor persistence waits.
- Search both surfaces for duplicate local construction, rating-key saves, active/prefix backend
  authority, body-time stats and unordered side-control Tasks. Metadata identity wins; safe legacy
  fallback is explicit. Preserve `Generic` and the tvOS compile exclusion.
- Run hermetic PMSKit, affected app-hosted suites and normal-parallel full Mac hosted gate with
  one Xcode lane active. Fixtures acknowledge held-worker entry/recovery completion, not arbitrary
  yield counts. Require terminal xcodebuild result and no unexpected skips/failures.
- Run applicable native builds/product smokes under the lead's one-simulator lease, using exact
  worktree products/IDs, then shut down and clean staged Mac apps. This docs lane boots none.
- Run strict MkDocs first, rendered links, Mermaid and hygiene; search unpublished internal lanes
  for removed anchors too. Promote durable changes into canonical docs before pruning the plan.
- Check narrow phone, regular iPad, visionOS and resizable Mac with long context/error strings,
  waiting/zero-progress/indexing/verification, exact delete race/copy and accessible action values.
- Keep live/device/D3/signature/TestFlight gates explicit. Unit counts never close them.
- Commit P7.7 last, then let the maintainer coordinate stack integration and authorized release.
  Archive this plan only once release work and successor tracking are complete.

## Edge cases added by the second review

| Case | Current disposition | Guard / remaining gate |
| --- | --- | --- |
| Unknown media becomes known extras-only (B81) | Fixed in P5; media unknown remains unknown. | Storage estimate/admission and season confirmation tests. |
| Protected data unavailable, then unlock | Fail closed and re-probe; never reset unreadable bytes. | Recovery/store controls; actual locked-device acceptance open. |
| Cleanup committed before row/index removal | Ordinary Delete barrier/capsule and replay preserve authority; obsolete migration-receipt design removed. | Cleanup/schema-upgrade tests; full session crash injection not exhaustive. |
| Callbacks after enumeration/drain | Exact-owner/work-admission fences reject obsolete work. | Task ownership/full-key tests; daemon/device acceptance open. |
| Storage exhausted during upgrade | Retain v4/notice/cleanup authority and block or retry safely. | Fault/notice/upgrade controls; emergency Delete remains B30. |
| Downgrade opens v5 | Guarded older binaries preserve unsupported bytes; additive-field loss is documented. | Index/schema tests; pre-guard downgrade limitation remains. |
| Failed Convert job cleanup (B44/B49, emby-37) | Fixed P1 containment/P2 claims; resumable failed-row jobs are retained. | Cleanup ordering/eligibility tests; live acceptance open. |

## Appendix A — Bug list

The complete B00–B87 dispositions, relevant st-/pu- cases, severities, phase/PRs, named guards,
status/area counts and deferred reasons live only in the immutable
[bugs versus main evidence page](../evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md).
Do not restore a second bug table here.

## Appendix B — Edge-case inventory

The original 329 case IDs remain as a compact acceptance/retention index below. These are current
contract summaries, **not** a claim that every case has an independent test or passed on devices.
Obsolete observed-status, pinned yes/no, historical rationale and line-number columns are removed.
The canonical pages linked above own implementation detail. Explicit deferrals and exceptions win
where an original requirement was narrowed; the evidence page owns bug-fix classification.

### Background session

- **bg-01:** Normal OS handler release waits for finish-events, required operations and their
  persistence boundary; absolute expiry reports timeout.

- **bg-02:** Several handlers for the same identifier: release only the exact token batch
  claimed at finish

- **bg-03:** Index plus artifact flush shares the absolute wake budget and its five-second
  persistence reserve; timeout retains dirty work.

- **bg-04:** Rebuild grace: hold the wake while the manager re-mints an authenticated request
  (20 s timeout, generation-fenced)

- **bg-05:** Keep a nested gate operation open across the held-body lifecycle completion

- **bg-06:** Handler stored after urlSessionDidFinishEvents already fired

- **bg-07:** Startup admission: keep the session dormant (URLSession not built) until the index
  is admitted, then purge unowned or non-current tasks before opening

- **bg-08:** Destructive reset for an unsupported schema: cancel every OS task, require two
  consecutive empty enumerations, then replace the root

- **bg-09:** Blocked-before-transport handlers release without construction; activation and
  failed-after-transport keep their distinct owned-work rules.

- **bg-10:** Defer the initial transport activation by one MainActor turn; a retry cancels the
  deferred edge and owns the only submission

- **bg-11:** Reattach adopts only current exact-attempt markers; mismatched/malformed/unowned
  tasks cannot revive paused or deleted work.

- **bg-12:** A reattached or dead-finish closed segment recovers its segmentLength (from the
  Range end, else the grid clamped to the expected total)

- **bg-13:** Terminal rows (complete/failed/unverified) must not re-adopt straggler tasks

- **bg-14:** Stamped tasks whose row was deleted are cancelled

- **bg-15:** Deletion-pending rows: cancel their tasks and keep held manifests and bodies until
  journal-first deletion completes

- **bg-16:** Reattach must not re-adopt a task whose pause or cancel is in flight

- **bg-17:** Re-enumerate and reconcile tasks on scene-active (headset wake)

- **bg-18:** Recover pending validated promotions off the URLSession delegate queue, before task
  classification

- **bg-19:** Move the didFinishDownloadingTo temp file synchronously (O(1) rename) before any
  classification; do the heavy append off the delegate queue

- **bg-20:** Never delete CFNetworkDownload_*.tmp during reattach; leaked network temps are only
  observed

- **bg-21:** Sweep orphaned range-body stashes (tmp/) and orphaned durable held bodies on
  reattach

- **bg-22:** Dead-finish adoption of a marked segment that finished while the process was dead;
  unowned bodies limited to discard or reset

- **bg-23:** Dead-finish adoption of a forward-only (opaque) transfer that completed while the
  app was terminated

- **bg-24:** A complete attempt-owned forward body enters persisted finalizing and is replayed
  after process death.

- **bg-25:** Duplicate or late delegate callbacks are absorbed: superseded-ID set, newer-task
  supersede, per-attempt finalizer single-flight, stale-attempt drops

- **bg-26:** Halt kinds: a pause preserves a just-finished body (writeThenPause), a cancel
  discards it, and a pause never downgrades a cancel

- **bg-27:** Train epochs reject captured bodies after teardown; range restart stays serialized
  and old timers cannot acquire new Resume authority.

- **bg-28:** A closed segment that receives more than segmentLength bytes is cancelled and
  rebuilt; closed-segment resume blobs are never persisted or adopted

- **bg-29:** Unknown-total open remainders use blobs only when Range start matches the durable
  checkpoint and bounded retry authority remains.

- **bg-30:** Network-path counter reset on the same task id: cancel and rebuild from the
  checkpoint, judged by the task's live counter

- **bg-31:** visionOS wake silently restarts the body of a custom-Range request with no error or
  resume data; loss is bounded by a pre-queued closed segment train

- **bg-32:** Train sizing and fan-out (512 MiB × 2 per row)

- **bg-33:** In-session transient transport retry for the range lane

- **bg-34:** HTTP retry/auth rehydrate retains backoff, wake holds and exact
  attempt/train/action generation through successor registration.

- **bg-35:** Missing temp or body (Cocoa error 4) during stash or append: bounded retry or
  rehydrate from the durable checkpoint

- **bg-36:** Start/continuation/blob preflights and ENOSPC use the shared physical policy;
  automatic redrive remeasures storage parks.

- **bg-37:** No AVPlayer probe while an OS wake handler is pending: finalize as unverified and
  revalidate on the next foreground pass

- **bg-38:** Serialise playback-validation probes (global limiter) and bound retries

- **bg-39:** Rewrite hev1 to hvc1 before probing; bounded edge windows plus top-level/moov
  scanning include valid extended-size boxes.

- **bg-40:** Cellular policy is stamped per request, and the background session itself stays
  permissive

- **bg-41:** Simulator uses a foreground session with a per-request 3600 s timeout

- **bg-42:** Session identifier: per-bundle on macOS so worktrees don't reattach each other's
  transfers; legacy fixed identifier on iOS/visionOS

- **bg-43:** macOS has no handleEventsForBackgroundURLSession and no relaunch-for-events

- **bg-44:** System cancellation parks static checkpoints and makes forward-only work retryable;
  it is not silently classified as user Pause.

- **bg-45:** Self-heal a queued or downloading static row that has a durable partial but no
  tracked task

- **bg-46:** When the rebuild grace times out, park a queued row with no task as Paused at its
  checkpoint

- **bg-47:** Same-source truncation strikes persist across Retry/relaunch; deduplicated body
  outcomes and permanent per-attempt condemnation prevent unsafe reuse.

- **bg-48:** A user start or resume resets every range restart budget; internal continuations do
  not

- **bg-49:** Exact-attempt task creation: the session never mints authority, and every task
  description carries item key + U+001F + an attempt or segment marker

- **bg-50:** Exact-attempt keepalive follows tracked transfer and captured credential
  generation; stale suspended work cannot publish for a replacement session.

- **bg-51:** Persisted range progress is pinned to the durable checkpoint; live train bytes are
  a separate overlay clamped to the total

- **bg-52:** Intentionally dropped: the old first-progress hold/graceful checkpoint-pause
  mechanism is not restored.

- **bg-53:** Registry registration and handler storage never reattach on their own

- **bg-54:** Opaque lane HTTP and MIME gate, and forward-only streams never resume from a byte
  offset

### Store and durability

- **st-01:** Persist one-level relative paths; re-hydrate absolute URLs against the live
  container (container moves on reinstall/update)

- **st-02:** Reject unsafe persisted relative paths (no '/', '..', '\\') before any file
  operation

- **st-03:** Exclude the Downloads root from backup and apply
  CompleteUntilFirstUserAuthentication protection; apply per-file protection to committed
  artifacts

- **st-04:** Server-cleanup authority lives outside the versioned media root so a destructive
  reset or row deletion cannot erase it

- **st-05:** Migrate cleanup journals from the old in-root location to the authority directory,
  with byte-equality conflict check

- **st-06:** Schemas 1–3 reset only after two empty task enumerations and durable quarantine; v4
  upgrades and newer/unreadable inputs remain distinct.

- **st-07:** Reclaim quarantined/retired roots asynchronously, and again on every launch

- **st-08:** Retained fail-closed policy: malformed current rows block a writable partial
  library; decoder isolation is not silent salvage authority.

- **st-09:** Duplicate current keys remain blocked with exact original bytes retained; no
  trapping unique-key loader initializer.

- **st-10:** Unreadable or malformed index bytes are never overwritten while startup is blocked

- **st-11:** Malformed current-schema ownership (missing or disagreeing top-level attemptID,
  wrong working path) blocks admission without guessing an owner

- **st-12:** Serialized, revisioned full-snapshot index writes with encode and I/O off the store
  lock; superseded snapshots are never written

- **st-13:** Crash-durable index commit (unique temp, F_FULLFSYNC, rename, parent fsync) plus
  age-gated cleanup of abandoned temps

- **st-14:** A failed index write stays dirty and is retried by the next full snapshot or a
  bounded flush

- **st-15:** Ambiguous post-rename commit failure (the new bytes may already be canonical)

- **st-16:** Throttle progress-driven index writes to about 1 per second; status transitions
  persist immediately

- **st-17:** Normal handler release proves the resulting index/artifact boundary within the
  whole-wake budget; expiry is explicit timeout.

- **st-18:** Never orphan a resume blob: write it under a generation-private name behind a
  durable prepared intent, and age-sweep abandoned commit temps

- **st-19:** Validated promotion crash window (rename done, terminal index not yet committed)
  replays from a durable intent

- **st-20:** Attempt-scoped hidden working files, so a stale attempt can never write, checkpoint
  or promote over a replacement attempt's body

- **st-21:** Startup sweep deletes only attempt-staging files that existed at Store init and are
  unreferenced

- **st-22:** Durable held range bodies with manifest; held-body deletion is recoverable across a
  failed commit or relaunch

- **st-23:** Orphan held-range body sweep at reattach

- **st-24:** Row deletion is a terminal artifact barrier; failure retains row/files/intent,
  exact waiters and recoverable successors.

- **st-25:** Joined deletion waiters (double-tap Delete, coalesced recovery) each receive the
  outcome for the same epoch

- **st-26:** An unavailable cleanup journal retains a durable deletion capsule and exact
  obligations; work admission stays fenced until recovery.

- **st-27:** Cleanup journals: unreadable is not empty; exact-value proofs after an ambiguous
  atomic write; element-level quarantine repair (intent journal only)

- **st-28:** Reconcile: a complete or unverified row whose file is missing becomes failed

- **st-29:** Reconcile preserves resumable partials, clears resume authority durably and defers
  stale/busy physical cleanup; generalized body recipes remain deferred.

- **st-30:** Reconcile skips rows with pending artifact intents

- **st-31:** Plex prep returns to queued/admitted; failed forward streams remain retryable; live
  static task authority is observed without reviving user Pause.

- **st-32:** Side-asset owner fencing on load: a mismatched owner retires the bundle; a legacy
  ownerless bundle with an attempt is adopted

- **st-33:** Load-time normalization of legacy Plex prepared-static lane rows

- **st-34:** One off-lock season transaction commits new rows and exact retry intents
  atomically; compensation is conditional and ambiguous success blocks admission.

- **st-35:** Cross-row path protection: a destructive step never deletes a path another row
  references, including paths captured only by pending intents

- **st-36:** Static byte-range checkpoints use only durable file size; a complete row can be
  reconstructed into a working checkpoint via a durable clone

- **st-37:** Retry clones only an eligible predecessor checkpoint under path exclusion before
  durable successor ownership; failed commits retain source bytes.

- **st-38:** Storage audit: report referenced, unreferenced and orphan-candidate bytes in
  diagnostics (#171), report-only

- **st-39:** Deferred: general stable-media/side-asset orphan reclamation; retain report-only
  audit and narrow initialization-inventory staging sweep.

- **st-40:** Failed/superseded live epochs are bounded; registered exact waiters retain failures
  independently of the 512-entry unclaimed history cap.

- **st-41:** Mapped store filesystem/journal work runs outside the store lock with copied
  generation checks and physical path exclusion.

- **st-42:** Retain downgrade compatibility: no new persisted intent cases; old decoders can
  lose additive history, and pre-P1 newer-schema protection is not guaranteed.

- **st-43:** If Application Support is unavailable, fall back to the temporary directory

### Storage, delete, pause and retry

- **sd-01:** Proactive free-space preflight counts iOS purgeable space

- **sd-02:** Physical preflight charges remaining network bytes, largest append duplication,
  uncached side assets and 500 MB headroom.

- **sd-03:** Range continuation/retry storage gate

- **sd-04:** ENOSPC mid-transfer on the static range lane is terminal storage-full, not a fake
  resumable pause or 'system code 640'

- **sd-05:** ENOSPC on the opaque/forward-only lane (Jellyfin/Emby transcode, remux)

- **sd-06:** Storage-full rows are parked, not auto-redriven against an unchanged full disk
  (retry storm)

- **sd-07:** User Retry may reattempt a storage park immediately, but still passes
  lane/cap/free-space preflights.

- **sd-08:** User storage cap (Unlimited/10-250 GB) enforced at enqueue/start, never deleting
  existing downloads

- **sd-09:** Storage estimate includes side assets (trick-play/BIF + chapter images)

- **sd-10:** Delete while downloading: halt the lane and bump the train epoch so in-hop bodies
  are discarded, not appended to a re-download

- **sd-11:** Row actions (pause/retry/delete) are fenced to the exact rendered attempt

- **sd-12:** Delete clears all recovery state (finalizing keys, preservation keys, pending
  resume, retry state)

- **sd-13:** Delete cancels in-flight side-cache work and removes its staging files (#171 async
  side-cache race)

- **sd-14:** Deleting a Jellyfin/Emby transcode row tears down the server ActiveEncoding durably

- **sd-15:** Deleting an Emby Convert row cancels its server Sync job, including failed rows and
  crash-window ambiguous creates

- **sd-16:** Deleting a Plex row still in server prep removes its type-42 optimize item

- **sd-17:** Completed Plex renders are retained; an accepted read-to-cancel completion race
  remains because PMS has no conditional cancellation.

- **sd-18:** Deletion stays pending (row and files intact) until server-cleanup authority is
  durable

- **sd-19:** Missing server-cleanup identity: delete locally but surface the leak, and keep that
  disclosure after a successful delete

- **sd-20:** Normal Delete queues behind promotion; preempting wedged legacy validated promotion
  remains deferred (B27).

- **sd-21:** Deferred B30: a completely full volume may prevent durable Delete preparation;
  explicit failure/retry preserves authority.

- **sd-22:** Refuted live defect: current row actions require exact attempt ownership; there is
  no new ownerless-delete recovery path.

- **sd-23:** Delete releases the in-flight slot, queue-title protection, and optimize
  progress/ETA

- **sd-24:** Re-download after delete starts with clean budgets (truncation counter, retry/range
  budgets)

- **sd-25:** Pausing a Plex server-prep row (persisted as .queued) parks it synchronously

- **sd-26:** User pause supersedes pending system auto-resume and manual-queue-resume markers

- **sd-27:** Pause keeps held ahead-of-checkpoint stashes; cancel/delete/terminal purge them

- **sd-28:** Pause installs the halt at snapshot time and late cancel callbacks never re-pause a
  resumed replacement

- **sd-29:** Global queue pause persists across relaunch; Emby Convert keeps polling while
  paused and a completed convert parks instead of transferring

- **sd-30:** Resume All queues paused/failed rows through shared admission caps and their own
  retry facts.

- **sd-31:** Manual static resume while the queue is paused is honored without clearing the
  global gate

- **sd-32:** Retrying a paused or failed Emby Convert row that still owns a job id resumes
  POLLING, never a fresh POST

- **sd-33:** Persisted URLSession resume data for static rows resumes on the range lane

- **sd-34:** Resuming a paused Plex server-prep row reattaches to the existing optimize queue
  item (no duplicate transcode)

- **sd-35:** Retry rehydrates the user's original lane intent from persisted metadata
  (compatible remux, Emby existing/converted version, original)

- **sd-36:** A failed row stays visible and retryable until backend auth/server preflight
  succeeds

- **sd-37:** A resume-data retry restarts missing side-asset hydration for the exact attempt

- **sd-38:** Sign-out is a resumable pause of that backend's active rows, run before credentials
  are cleared

- **sd-39:** A post-logout 401/403 defers to 'waiting for session' instead of failing the row

- **sd-40:** No purge of downloads on sign-out or server removal

- **sd-41:** Side-asset payloads are validated before promotion (no HTML/error bodies in the
  offline bundle)

- **sd-42:** Process-wide pacing of optional side-asset requests per origin

- **sd-43:** Completed-row side-asset repair is bounded per launch and charged only on real
  dispatch

- **sd-44:** New side-asset requests use the same cellular/constrained/expensive preference; no
  cellular-only policy divergence.

- **sd-45:** Pause / Pause All parks optional side-asset work; resume continues it

- **sd-46:** Narrow staging reclamation and report-only visibility remain; general stable orphan
  deletion is deferred pending liveness proofs.

- **sd-47:** Remove Completed includes .unverified; Remove All cancels active transfers

- **sd-48:** A storage-limit or other pre-transfer abort fails the row BEFORE dropping its
  pending-resume marker

### Plex

- **plex-01:** X-Plex-Client-Profile-Name=Generic on every download-side Plex decision call

- **plex-02:** Original direct download requires an AVPlayer preflight of the remote static URL;
  on failure, fall back to the optimizer

- **plex-03:** A delete or pause landing during the long preflight must not upsert or seed a
  zombie prep row

- **plex-04:** Existing Plex Version chosen explicitly: static as-is transfer, no preflight,
  never touches the optimize queue

- **plex-05:** A static retry of a rendered or existing version keeps the exact Part identity
  and fails closed if the Part vanished

- **plex-06:** The optimize create uses the type-42 playlist grammar with a server-resolved
  targetTagID and custom Device/MediaSettings

- **plex-07:** Prefer an alternate (writable) library location for optimizer output

- **plex-08:** Surface server read-only/optimizer failure: a completed type-42 item with
  failed>0 and successful==0 fails the row

- **plex-09:** Completed-but-unindexed render gets a bounded 120-second grace only after
  successful metadata inspection; unavailable inspection is not absence.

- **plex-10:** Overall optimize deadline persisted across relaunches

- **plex-11:** Poll health: consecutive 401/403 polls go terminal as auth-dead; unreachable
  diagnostics are bucketed

- **plex-12:** Re-resolve the Plex lane on every poll iteration; on sign-out or server change,
  park the row for deferred resume

- **plex-13:** Orphan guard: the poll loop stops when the row is gone or the in-flight slot is
  released

- **plex-14:** Delete journals exact unfinished Plex queue cancellation before row removal,
  including paused prep; resource claims are rechecked.

- **plex-15:** Known completed Plex queue items are preserved; the unavoidable GET-to-DELETE
  completion race is explicitly disclosed.

- **plex-16:** Stale-job sweep is scoped to our '[Labstream ' marker, minus protected titles
  (in-memory plus persisted non-complete rows)

- **plex-17:** Queue-title protection held for the whole download lifetime, not released in a
  defer

- **plex-18:** Relaunch during optimize: adopt an already-completed tier-matching render before
  inspecting or recreating queue work

- **plex-19:** Relaunch recreate only when the queue was actually inspected and the item is
  provably absent

- **plex-20:** Bounded in-loop retry of the background-processing key lookup

- **plex-21:** Paused prep resumes the existing queue item without another create; stale poller
  tokens cannot clear new ownership.

- **plex-22:** Failed optimize retry keeps the user's requested target

- **plex-23:** A validated original that fails the local playback probe falls back to an
  optimize, with no loop

- **plex-24:** Fallback seeds are stamped with the optimize lane and serverPrepThenStatic before
  the first upsert

- **plex-25:** At handoff, persist the rendered Part id, its size, staticByteRange resume mode
  and serverPreparedVersion atomically

- **plex-26:** Optimized-version tier matching: ±16 px bounding box, container bitrate up to
  ×1.10 of the cap plus 768 kbps, original quality at source height

- **plex-27:** Optimize baseline is only the selected source part, so a tier-matching existing
  Plex Version is discoverable

- **plex-28:** An optimize-create failure (HTTP 400 duplicate) must not flash a terminal failed
  row

- **plex-29:** Unpause the server's idle-paused background queue (conditional write)

- **plex-30:** Optional 'Prioritize quick downloads': move only our item to just after the
  active conversion

- **plex-31:** Server-prep progress attribution under concurrent jobs

- **plex-32:** Finalizing caption instead of 'Preparing on server… 100%'

- **plex-33:** Plex audio track for server-prepared output: select the preferred stream on the
  Part before the optimize POST, best-effort

- **plex-34:** Original-quality optimize uses the server Original Quality target with no caps;
  internal target labels are not duplicated in UI.

- **plex-35:** Multi-part items (one Media with several Parts)

- **plex-36:** Optimize chain is a cancellable registered Task; superseded chains never tear
  down a newer attempt's state

### Emby

- **emby-01:** Route decided by an authoritative download PlaybackInfo POST (static-mp4 download
  profile, ~200 Mbps ceiling), not the naked-item SupportsDirectPlay

- **emby-02:** Explicit static stream.mp4 transcode URL with the minted PlaySessionId (the
  codecless /stream URL 500s on HEVC/DTS)

- **emby-03:** A live transcode is rerouted to a persistent server Convert job.
  .original/.existingVersion fail closed instead of silently becoming forward-only

- **emby-04:** Existing-version/converted handoff is gated on local playability
  (container+codec), not Emby's streaming DirectPlay verdict

- **emby-05:** No recursion: the .existingVersion handoff never re-enters the Convert lane

- **emby-06:** Attempt-currency check after the PlaybackInfo await, with best-effort release of
  the just-minted PlaySession

- **emby-07:** Explicit mediaSourceIDOverride must equal the negotiated MediaSource (EMBY-F6)

- **emby-08:** Width-aware resolution label persisted from negotiated dimensions for
  server-prepared versions

- **emby-09:** Expected bytes for static originals and remux come from MediaSource.Size

- **emby-10:** Compatible remux stays forward-only with a persisted minted session, Ping-only
  keepalive and durable terminal teardown.

- **emby-11:** Compatible-remux fallback to the 1080p Convert preset is disclosed, and
  confirmation is required above 1080p (EMBY-F4)

- **emby-12:** A visible .preparing row is seeded before the expensive reuse/refresh preflight

- **emby-13:** Reuse an already-converted File source instead of creating a duplicate Convert
  job (#126 on the auto-convert path)

- **emby-14:** Reuse keeps tier/source-band/4K-original fidelity and selected audio-language
  matching; unrelated siblings cannot satisfy an exact request.

- **emby-15:** Bounded targeted item refresh plus about 30 s source poll before creating a new
  conversion (#133)

- **emby-16:** Persist the full pre-conversion File-source snapshot so that, after relaunch, a
  prior converted version is never mistaken for the new output

- **emby-17:** Convert jobs are identified by the persisted job id, never by the submitted name

- **emby-18:** A complete Sync-job baseline is captured before POST. The list decoder tolerates
  foreign clients' jobs

- **emby-19:** Persist ambiguous-create identity before POST; pre-dispatch/definitive 4xx clear
  recovery, while uncertain transport/5xx/invalid success retains it.

- **emby-20:** Crash-window adoption needs exactly one new fingerprint/time-window match on the
  same owning server/user.

- **emby-21:** Crash-window identity older than 24 h expires: handed to cleanup and the row
  released

- **emby-22:** A row deleted or paused while POST /Sync/Jobs is in flight is not resurrected

- **emby-23:** Status polling: healthy renders are unbounded; a consecutive run of
  unreachable/5xx/undecodable responses is bounded (60 × 5 s)

- **emby-24:** Terminal poll HTTP: 404/410 clears the job id (fresh retry); 401/403 KEEPS it so
  re-login plus Retry resumes the live job

- **emby-25:** Retrying a .failed row that still owns a Sync job id resumes POLLING rather than
  POSTing again

- **emby-26:** Progress pinned at 0 while Converting shows indeterminate 'Preparing on server…',
  never '0%' or an ETA

- **emby-27:** Recognized terminal errors, including CompletedWithError, fail promptly;
  genuinely unknown future statuses remain nonterminal.

- **emby-28:** Server-side Failed/Cancelled fails the row and clears the job id so Retry creates
  a fresh job

- **emby-29:** Post-completion indexing lag: item refresh, then poll unfiltered PlaybackInfo up
  to 72 × 5 s for the new File source

- **emby-30:** Pickup selects the NEW converted output (outside the snapshot, converted-shaped,
  tier-sane relative to min(requested, source))

- **emby-31:** Relaunch at 'Preparing… 100%': check for an exposed converted source before the
  job loop, and cancel the still-live job before handing off (EMBY-F1)

- **emby-32:** The .preparing row is kept until the static handoff atomically replaces it
  (EMBY-F11)

- **emby-33:** With the queue paused, Convert polling continues; the static handoff is parked as
  paused

- **emby-34:** A stale convert chain never fails, re-plants progress on, or resurrects a fresh
  row (attempt UUID plus row/job/target guard after every await)

- **emby-35:** Convert-lane persistence failures fail the row and release the slot

- **emby-36:** Preparing/failed/paused Delete journals job cancellation before local deletion;
  mismatched sessions defer and retain authority.

- **emby-37:** Cleanup claims protect failed resumable Convert jobs as well as active rows;
  stale create/abandonment never cancels a replacement owner.

- **emby-38:** Only one recovery per tombstone/intent at a time

- **emby-39:** The converted file is kept for future reuse; Sync-job DELETE never deletes an
  already-converted file

- **emby-40:** Server Sync-job hygiene: Completed/Failed jobs are never deleted, so they
  accumulate

- **emby-41:** Audio stream intent is persisted and carried through Convert create, reuse,
  resume and handoff

- **emby-42:** Text sidecars retain the proven original source ID independently of converted
  media/BIF; ambiguous historical repair is skipped.

- **emby-43:** Resume, retry and cleanup run only under the same server and user that created
  the job

- **emby-44:** Deferred D4: new Premiere/Convert entitlement discovery; preserve honest failure
  and selected intent.

- **emby-45:** 4K/Original Convert uses profile:custom with mp4/h264/aac (tv downscales to
  1080p; the literal 'original' token is rejected with 500)

- **emby-46:** Convert uses nondestructive originalmediafolder and backend-native body/response
  shapes; nested create Job differs from fetched job.

- **emby-47:** A row with no job id after relaunch (died before create) fails as retryable 'did
  not finish starting'; a prepared-phase baseline is discarded

- **emby-48:** Pausing a .preparing convert row parks it; resume re-attaches polling of the same
  job

- **emby-49:** Fresh and resumed Convert chains are registered pollers; handoff detaches its own
  token without self-cancellation.

- **emby-50:** A static original's destination extension stays stable across retry

- **emby-51:** The debug probe classifies routes the same way production does

### Jellyfin

- **jf-01:** Server-minted PlaySessionId for the transcode lane (no locally minted ids)

- **jf-02:** Compatible remux gated by a re-probe of PlaybackInfo, not in-memory Part streams

- **jf-03:** Remux request fallback: stale UI/retry for a non-copyable source becomes a 1080p 8
  Mbps transcode and is relabeled lane .optimize

- **jf-04:** Remux lists the source video and audio codec so the server stream-copies, keeps 7.1
  (no maxAudioChannels), and uses AAC as the re-encode target

- **jf-05:** HEVC hev1->hvc1 tag fixup on finished MP4-family bodies (remux output and static
  mp4/mov)

- **jf-06:** Live-forward streams are not byte-offset resumable: URLSession resume blobs are
  refused and the row fails with a 'restart from the beginning' message

- **jf-07:** Forward-only body that finishes while the app is terminated is adopted on
  redelivery (JF-F4)

- **jf-08:** Tighter truncation guard for forward-only streams (0.95), and nil duration
  finalizes .unverified instead of .complete (JF-F2)

- **jf-09:** Two-strike truncation park: repeated truncations keep the file as .unverified
  instead of deleting and re-transcoding forever

- **jf-10:** Forward-only stall watchdog: cancel and restart a zero-bandwidth stream after 90s,
  at most 2 automatic restarts

- **jf-11:** D3 blocked: fixed-zero Playing/Progress interim retained; never restore advancing
  byte-derived position or claim neutrality.

- **jf-12:** Keepalive exits remove only their generation; owning sessions are rechecked and
  401/403 quarantines that credential generation.

- **jf-13:** Keepalive must not run for a row that has no live transfer (IC-4)

- **jf-14:** PlaySessionId is persisted on the row so a hard kill can still tear down the
  encoder; teardown goes through a durable cleanup-intent journal

- **jf-15:** Post-await currency check after PlaybackInfo, with best-effort teardown of the
  superseded minted session

- **jf-16:** Original retry keeps the on-disk container extension (lean rebuilt item collapses
  to .mp4)

- **jf-17:** Retry preserves compatible-remux intent, selected audio/source and stable static
  extension through relaunch.

- **jf-18:** Retry against a different Jellyfin server or user is deferred instead of replayed
  (A-5), and the job never reads active backend (#84)

- **jf-19:** Explicit selected source must remain exact; resolved sources are persisted for side
  assets without sibling substitution.

- **jf-20:** Selected audio track is honored for server-prepared lanes

- **jf-21:** Transcode and remux progress shows an estimated ~% from duration x bitrate (remux
  uses the source size)

- **jf-22:** Storage-limit and free-space preflight sized to the expected download

- **jf-23:** Trickplay cache: header auth, ApiKey stripped from tile URLs, sanitized local
  playlist, and an 'apikey=' guard before publishing

- **jf-24:** Background-wake finalize defers the AVPlayer probe to .unverified and revalidates
  in the foreground

- **jf-25:** Sign-out pauses in-flight Jellyfin rows and tears down encoders while credentials
  still exist

- **jf-26:** Deferred new transient forward-stream retry strategy; existing bounded
  failure/stall restart remains and no byte-offset resume is claimed.

### Planner and row UI

- **pu-01:** Tri-state watched state: a missing value is never treated as unwatched
  (Jellyfin/Emby); Plex nil viewCount means unwatched

- **pu-02:** Unwatched scope offered only when usable watched state exists; skipped
  'unavailable' count is shown

- **pu-03:** Repeated season plans deduplicate by durable state/identity; completed media stays
  available and parked rows retry only through shared admission.

- **pu-04:** No rolling season sync; later episodes require an explicit repeated plan.

- **pu-05:** Persist every planned row atomically before admitting any work; on failure start
  nothing

- **pu-06:** Indeterminate atomic-write outcome pauses download admission (fail closed)

- **pu-07:** Lane-aware bounded admission window (static 2 / server-prep 1 / live-forward 1 /
  total 3)

- **pu-08:** Ordinary stale/relaunch recovery must not start season-pending rows

- **pu-09:** Admission revoked when a row is deleted, replaced or paused during the
  metadata-refresh suspension

- **pu-10:** Exact source Part re-found by sourcePartID at admission (media array may reorder)

- **pu-11:** Original quality never falls back to an unrelated bitrate rendition; an unsupported
  episode becomes its own failed row

- **pu-12:** Existing-version distance uses proportional resolution/bitrate, smaller-file tie
  breaking and offline playability; no arbitrary incompatible fallback.

- **pu-13:** Unknown episode sizes are never counted as zero; known bytes over the cap block;
  unknown sizes need explicit confirmation

- **pu-14:** Prepared/remux output uses preferred language/role then default/first audio;
  byte-for-byte routes retain every file track.

- **pu-15:** Cancelled planning sheet never starts the next probe or publishes a partial plan;
  probes run one at a time

- **pu-16:** Immutable draft: the confirmation dialog and the commit use the same plan

- **pu-17:** Global queue pause stops season admission

- **pu-18:** Planning probes use an ephemeral, cookie-less, cache-less session; redirects only
  allowed for same-origin 307/308 with identical method/body/headers

- **pu-19:** Jellyfin PlaybackInfo probe retries once on a spurious URL cancellation

- **pu-20:** Interactive Emby existing-version discovery can refresh/poll; season planning skips
  that repeated expensive path.

- **pu-21:** Offline list orders episodes by show title, then season, then episode, then title
  (not by episode title)

- **pu-22:** Episode rows identify themselves offline ('Show · S1E3 · Title') and show a
  year/runtime/rating subtitle

- **pu-23:** Multi-row delete confirmation ('Delete N downloads?')

- **pu-24:** Row actions fenced by exact attempt identity (stale pause/retry/delete/play are
  no-ops)

- **pu-25:** Shared exact/estimated/indeterminate progress keeps preterminal values below 100%;
  zero server preparation is indeterminate.

- **pu-26:** Separate post-transfer 'Verifying download…' and server-prep 'Finalizing server
  transcode…' phases

- **pu-27:** 'Waiting for <backend>…' instead of 'Preparing on server…' when a prep row has no
  live poller and its backend is not configured

- **pu-28:** Server-prepared static versions are labelled 'Downloading optimized' with an
  Optimized badge, never 'transcode'

- **pu-29:** Media bytes vs extras (side-asset) bytes shown separately in captions

- **pu-30:** Quality text: requested profile while in flight, derived average bitrate once
  complete (never the raw source/Emby bitrate)

- **pu-31:** Intentionally dropped: do not resurrect the old checkpoint-drain pause caption.

- **pu-32:** Paused rows show a non-red resumable caption and a Resume control; failed rows show
  the reason in red or a generic fallback

- **pu-33:** Season-pending rows shown as waiting, not as active work

- **pu-34:** A backend switch must not bounce an already-ready browse UI; offline surface only
  after a failed restore with local media

- **pu-35:** Season 0/Specials planned only when invoked from that season; no whole-show
  traversal

- **pu-36:** Duplicate episode items collapsed by S\|E\|title display identity before planning

### Offline playback

- **op-01:** Local playhead persisted per completed download row (#146)

- **op-02:** Saved position is clamped, floored below 1s, and reset to 0 within 30s of the end

- **op-03:** Local playhead takes priority over the server viewOffset captured at download; the
  captured value is the fallback

- **op-04:** Position and observed-playing verification are bound to the playing attempt plus
  independent playback-session generation.

- **op-05:** Both launch surfaces use the same immutable factory/event sink; position saving
  never substitutes for actual-playing evidence.

- **op-06:** Deferred D4: progress/watched-state sync-back; local positions remain local.

- **op-07:** Local playback makes no server requests (timeline, scrobble, up-next PlayQueue,
  artwork)

- **op-08:** Cold launch with a saved session but an unreachable server opens a restricted
  Offline surface when a completed file exists (#259)

- **op-09:** Signed out / revoked (401) / refused (403 or wrong user) / temporarily unavailable
  are kept distinct; only the transient case opens Offline

- **op-10:** A stale temporarilyUnavailable outcome does not keep Offline open after switching
  to a backend with no saved credential; browse readiness always wins

- **op-11:** Offline admission needs a terminal row (complete or unverified) whose local file
  still exists; durable rows alone do not count

- **op-12:** Reconnect from the Offline surface returns to the normal browse root and re-runs
  download recovery

- **op-13:** Deferred product/auth policy change: preserve sign-out/revocation cold-launch
  exclusion.

- **op-14:** Actual current-item playing can verify eligible probe-miss/deferred rows;
  repeated-truncation warning survives playback and relaunch.

- **op-15:** Downloaded SRT/VTT sidecar subtitles are offered offline, parsed lazily on
  selection, and generation-fenced

- **op-16:** Embedded subtitles and downloaded text sidecars coexist in one menu with one Off
  and mutually exclusive generation-fenced selection.

- **op-17:** Intentionally excluded/deferred: no new bitmap/OCR/local image subtitle renderer.

- **op-18:** Offline audio selection uses the file's AVFoundation audible group; backend
  metadata audio selection is disabled

- **op-19:** Cached side-asset references (poster, BIF, tiles, chapters, subtitles) survive
  later metadata upserts

- **op-20:** Offline scrub previews: Plex BIF, Jellyfin tiles, Emby BIF with chapter-image
  fallback, loaded single-flight

- **op-21:** Offline chapter images from the cache (#88)

- **op-22:** Offline poster and Now Playing artwork come from the cached poster, fenced by
  attempt and generation

- **op-23:** Local playback shows 'preparing' wording instead of remote 'Buffering'

- **op-24:** Current HDR/DV delivery retained; broader engine changes deferred and
  decoded-frame/physical display acceptance remains open.

- **op-25:** Leaving Cinema returns to the originating Offline row (#87), including from the
  cold-launch Offline surface

- **op-26:** Orientation precedes exact local admission; close or rejected/superseded launch
  must restore presentation orientation (P7 review gate).

- **op-27:** Music yields the audio session before offline video starts (#17)

- **op-28:** Partial or active rows never offer local Play; Play re-checks that the file exists
  for the exact row identity

- **op-29:** Items deleted on the server stay playable offline; repairs for missing side assets
  are bounded

- **op-30:** Keep safe minimal legacy metadata fallback where present; no new owner/metadata
  reconstruction without reliable identity.

- **op-31:** Resume rewind applies once, identically from Detail and Offline.

- **op-32:** Persisted metadata backend owns assets; prefix fallback is limited to legacy
  missing-backend metadata.

- **op-33:** Deferred D4: offline Up Next/autoplay; local sessions issue no server queue
  requests.

- **op-34:** Offline records never store tokens

- **op-35:** Losing connectivity mid-session keeps Offline reachable; switching to an
  unreachable backend opens Offline
