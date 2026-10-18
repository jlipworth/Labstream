import Foundation
import PMSKit

/// P4: every download start goes through one lane-aware admission window (plan section "P4
/// detailed plan"). Occupancy is observed from persisted lifecycle plus live work; the
/// coordinator supervises granted starts until their async work finishes and classifies the
/// outcome, so an unavailable backend defers a row instead of failing or orphaning it.
extension DownloadManager {
    // MARK: - Observation

    /// A row waiting for a lane: a planned first start, or a parked row queued for its retry.
    func isWaitingForAdmission(_ record: DownloadRecord) -> Bool {
        if record.lifecycle == .planned { return true }
        return (record.lifecycle == .paused || record.lifecycle == .failed)
            && record.admissionIntent == .retryRequested
    }

    func admissionLane(for record: DownloadRecord) -> DownloadAdmissionLane {
        guard let metadata = record.metadata else { return .staticFile }
        return DownloadAdmissionPolicy.lane(
            backend: metadata.resolvedBackendKind(ratingKey: record.ratingKey),
            downloadLane: metadata.resolvedDownloadLane())
    }

    /// An active-looking row occupies a lane only while live work backs it: a slot, a registered
    /// prep poller, or a session-owned transfer. Residue without live work (a prep row whose
    /// backend is not signed in yet, a start that died) frees its lane; the existing recovery
    /// scanners own reattaching it (revision 3, amendment 5).
    func occupiesAdmissionLane(_ record: DownloadRecord) -> Bool {
        guard let lifecycle = record.lifecycle,
              lifecycle == .admitted || lifecycle == .serverPrep || lifecycle == .transferring,
              !isDeletionPending(record) else { return false }
        let id = record.ratingKey
        return activeJobs.contains(id)
            || hasRegisteredServerPrepPoller(ratingKey: id)
            || session.isTrackingTransfer(ratingKey: id)
            || session.ownsInProgressStaticRangeWork(ratingKey: id)
    }

    func admissionOccupants(_ snapshot: [DownloadRecord]) -> [DownloadAdmissionOccupant] {
        var occupants: [DownloadAdmissionOccupant] = []
        var observed = Set<String>()
        for record in snapshot where occupiesAdmissionLane(record) {
            // A supervised start's lane wins over metadata: a lane switch (P4.5) is authoritative
            // before the route is stamped on the row. A render that passed its handoff check (#414)
            // already holds a static slot.
            let lane = staticHandoffReservations[record.ratingKey] != nil ? .staticFile
                : admission.supervised[record.ratingKey]?.lane ?? admissionLane(for: record)
            occupants.append(.init(id: record.ratingKey, lane: lane))
            observed.insert(record.ratingKey)
        }
        for (id, supervision) in admission.supervised where !observed.contains(id) {
            occupants.append(.init(id: id, lane: staticHandoffReservations[id] != nil
                ? .staticFile : supervision.lane))
            observed.insert(id)
        }
        for id in staticHandoffReservations.keys where !observed.contains(id) {
            occupants.append(.init(id: id, lane: .staticFile))
        }
        return occupants
    }

    /// Wakes the pump when the occupancy vector changes (a lane freed, or a Plex prep row handed
    /// off into the static lane), not only when a row leaves the active states (amendment 6).
    func noteAdmissionOccupancy(_ snapshot: [DownloadRecord]) {
        let occupancy = admissionOccupants(snapshot)
            .map { "\($0.id)|\($0.lane.rawValue)" }.sorted()
        let waiting = snapshot.filter(isWaitingForAdmission).map { "w:\($0.ratingKey)" }.sorted()
        let signature = (occupancy + waiting).joined(separator: ",")
        if signature != lastAdmissionOccupancySignature {
            lastAdmissionOccupancySignature = signature
            scheduleAdmissionPump()
        }
    }

    // MARK: - Pump

    func scheduleAdmissionPump() {
        guard admissionPumpTask == nil else { return }
        admissionPumpTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.admissionPumpTask = nil
            self.pumpAdmission()
        }
    }

    /// One admission pass. Grants nothing before startup recovery has reattached work, while a
    /// season commit is proving durability (pu-05/06), or past the caps.
    func pumpAdmission() {
        guard startupRecoveryState == .ready, admission.recoveryComplete,
              seasonPlanCommitsInFlight == 0 else { return }
        let snapshot = store.records
        let occupants = admissionOccupants(snapshot)
        var waiting: [String: DownloadRecord] = [:]
        var requests: [DownloadAdmissionRequest] = []
        for record in snapshot where isWaitingForAdmission(record)
            && admission.supervised[record.ratingKey] == nil {
            guard let key = attemptKey(for: record), store.attemptAdmitsWork(key),
                  admissionPersistenceProofs[key] == nil else { continue }
            waiting[record.ratingKey] = record
            requests.append(admission.request(for: record.ratingKey, lane: admissionLane(for: record)))
        }
        let now = admission.now()
        // #414: a finished render that can hand off now takes the free transfer slot on its next
        // check; new transfer starts wait for it. Server-prep submissions are unaffected.
        let handoffPending = staticHandoffIsPending(occupants: occupants)
        let grants = DownloadAdmissionPolicy.grants(
            limits: admission.limits,
            occupants: occupants,
            requests: handoffPending
                ? requests.filter { !DownloadAdmissionLimits.countsTowardTotal($0.lane) } : requests,
            now: now,
            queuePaused: isQueuePaused, pauseExemptIDs: admission.pauseExemptions)
        for grant in grants {
            guard let record = waiting[grant.id] else { continue }
            launchAdmittedStart(record, lane: grant.lane, origin: grant.origin)
        }
        let granted = Set(grants.map(\.id))
        // Wake at the earliest backoff, including deferred static resumes that wait as pending
        // resumes rather than as waiting rows.
        let backoffs = admission.requestStates.values.map(\.eligibleAt).filter { $0 > now }
        let next = [DownloadAdmissionPolicy.nextEligibleTime(
            requests: requests.filter { !granted.contains($0.id) }, now: now), backoffs.min()]
            .compactMap { $0 }.min()
        scheduleAdmissionWake(at: next)
        // Automatic static resumes keep a pending-resume marker while they wait for a lane; drain
        // them when the static lane has room after this pass's grants.
        if hasPendingStaticRangeResumes, !handoffPending,
           admissionHasRoom(for: "\u{1F}static-drain", lane: .staticFile,
                            exemptFromQueuePause: true) {
            Task { @MainActor [weak self] in self?.drainPendingStaticRangeResumes() }
        }
    }

    private func scheduleAdmissionWake(at time: TimeInterval?) {
        admissionWakeTask?.cancel()
        admissionWakeTask = nil
        guard let time else { return }
        let delay = max(0, time - admission.now())
        admissionWakeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.scheduleAdmissionPump()
        }
    }

    // MARK: - Granted starts

    private func launchAdmittedStart(_ record: DownloadRecord, lane: DownloadAdmissionLane,
                                     origin: DownloadAdmissionOrigin) {
        let id = record.ratingKey
        let generation = admission.beginSupervision(id, lane: lane, origin: origin)
        let firstStart = record.lifecycle == .planned
            && record.admissionIntent != .retryRequested
        recordDownloadDiagnostic("downloads.admission_granted", fields: [
            "download_id": .identifier(id),
            "lane": .label(lane.rawValue),
            "path": .label(firstStart ? "first_start" : "retry"),
        ])
        // A granted retry runs its synchronous part now (a row Resume reacts in the same turn),
        // then supervision waits for the retry's spawned work.
        let retryWork = firstStart
            ? nil : retry(record: record, allowReplacingExistingActiveRow: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if firstStart {
                await self.runFirstStart(record, generation: generation)
            } else {
                await retryWork?.value
            }
            await self.finishAdmittedStart(id, generation: generation,
                                     intent: firstStart ? .seasonPlanned : .retryRequested)
            #if DEBUG
            self.admissionStartDidResolveForTesting?(generation)
            #endif
        }
    }

    /// A planned first start: grant (`planned` → `admitted`), then the season planner's refreshed,
    /// source-validated start (`startPlannedRecord`).
    private func runFirstStart(_ record: DownloadRecord, generation: UUID) async {
        guard let key = attemptKey(for: record),
              admission.isCurrent(record.ratingKey, generation: generation),
              await applyLifecycleEvent(.admissionGranted, for: key, context: "admission_granted"),
              let granted = store.record(for: key),
              admission.isCurrent(record.ratingKey, generation: generation), store.attemptAdmitsWork(key) else { return }
        await startPlannedRecord(granted)
    }

    /// Classify a supervised start after its async work finished (P4.4). Never rewrites a row the
    /// user paused, a deleting row, or a row a newer generation owns.
    func finishAdmittedStart(_ id: String, generation: UUID, intent: DownloadAdmissionIntent) async {
        defer {
            refreshRecords()
            scheduleAdmissionPump()
        }
        guard admission.endSupervision(id, generation: generation) else { return }
        guard let record = store.record(for: id), let key = attemptKey(for: record),
              !isDeletionPending(record) else {
            admission.clearRequest(id)
            return
        }
        switch record.lifecycle {
        case .serverPrep?, .transferring?, .finalizing?, .complete?, .unverified?:
            admission.clearRequest(id)
        case .admitted?:
            if occupiesAdmissionLane(record) {
                admission.clearRequest(id)
                return
            }
            // The start ended before any work existed (no session, a refresh outage): wait again.
            let deferred: Bool
            switch intent {
            case .seasonPlanned:
                deferred = await applyLifecycleEvent(.admissionDeferred(.seasonPlanned), for: key,
                                               context: "admission_deferred")
            case .retryRequested:
                let parked = await applyLifecycleEvent(.backendUnavailable(.deferredResume), for: key,
                                                       context: "admission_deferred")
                deferred = parked ? await applyLifecycleEvent(.admissionRequested(.retryRequested), for: key,
                                                               context: "admission_deferred") : false
            }
            // Back off even when the deferral write failed, so a failing volume is not retried
            // in a tight loop.
            noteAdmissionDeferral(id, reason: deferred ? "start_unproven" : "defer_write_failed")
        case .planned?:
            noteAdmissionDeferral(id, reason: "still_planned")
        case .paused?:
            let cause = store.lifecycleState(for: key)?.history.pauseCause
            guard cause != DownloadPauseCause.user else {
                // The granted start did not move the row: end the request rather than re-grant it.
                admission.clearRequest(id)
                if record.admissionIntent != nil {
                    _ = await applyLifecycleEvent(.admissionWithdrawn, for: key, context: "admission_no_start")
                }
                return
            }
            // Parked by the start itself (backend not ready, session mismatch): retry with backoff.
            let requested = record.admissionIntent == .retryRequested ? true
                : await applyLifecycleEvent(.admissionRequested(.retryRequested), for: key, context: "admission_deferred")
            if requested {
                noteAdmissionDeferral(id, reason: "parked")
            }
        case .failed?:
            // A transient negotiation failure (server error, network) waits and retries with
            // backoff, a bounded number of times; a definitive refusal (signed out, source gone,
            // storage, validation) stays a visible failure and no longer waits.
            let reason = store.lifecycleState(for: key)?.history.lastFailure
            let deferrals = admission.requestStates[id]?.deferrals ?? 0
            if reason == .server || reason == .network,
               deferrals < Self.maximumTransientAdmissionDeferrals,
               await applyLifecycleEvent(.admissionRequested(.retryRequested), for: key,
                                   context: "admission_transient_failure") {
                noteAdmissionDeferral(id, reason: "transient_failure")
                return
            }
            admission.clearRequest(id)
            if record.admissionIntent != nil {
                _ = await applyLifecycleEvent(.admissionWithdrawn, for: key, context: "admission_refused")
            }
        case nil:
            admission.clearRequest(id)
            if record.admissionIntent != nil {
                _ = await applyLifecycleEvent(.admissionWithdrawn, for: key, context: "admission_refused")
            }
        }
    }

    /// A metadata refresh that proves the item is gone (HTTP 404/410, no metadata item) is a
    /// definitive outcome; anything else is treated as the server being unavailable.
    static func isDefinitiveMissingItem(_ error: Error) -> Bool {
        if case PlexError.http(let status) = error { return status == 404 || status == 410 }
        if case MediaBrowserRequestError.httpStatus(let status) = error {
            return status == 404 || status == 410
        }
        if let service = error as? PlexBrowseService.ServiceError { return service == .noMetadataItem }
        return false
    }

    /// A start that keeps failing transiently stops waiting after this many deferrals (about
    /// three minutes of backoff) and stays a visible, retryable failure.
    static let maximumTransientAdmissionDeferrals = 6

    private func noteAdmissionDeferral(_ id: String, reason: String) {
        admission.recordDeferral(id)
        recordDownloadDiagnostic("downloads.admission_deferred", fields: [
            "download_id": .identifier(id),
            "reason": .label(reason),
        ])
    }

    // MARK: - Requests

    /// Ask for a lane for a parked row (Resume All, a row Resume or Retry delayed by capacity).
    /// The request is durable before it is queued; a failed write is not queued (amendment 3).
    @discardableResult
    func requestAdmission(for record: DownloadRecord, origin: DownloadAdmissionOrigin,
                          exemptFromQueuePause: Bool = false) -> Bool {
        guard let key = attemptKey(for: record), store.attemptAdmitsWork(key) else { return false }
        let intent: DownloadAdmissionIntent = record.lifecycle == .planned
            || record.admissionIntent == .seasonPlanned ? .seasonPlanned : .retryRequested
        let proofID = UUID()
        admissionPersistenceProofs[key] = proofID
        let submission: DownloadStore.LifecycleEventSubmission
        if !isWaitingForAdmission(record) || record.admissionIntent != intent {
            submission = store.submitLifecycleEvent(.admissionRequested(intent), for: key)
        } else { submission = .accepted(effects: [], ticket: store.currentPersistenceTicket()) }
        guard case .accepted(_, let ticket) = submission else {
            admissionPersistenceProofs.removeValue(forKey: key)
            return false
        }
        let state = store.lifecycleState(for: key)
        enqueueManagerOperation(ratingKey: key.ratingKey) { [weak self, store] in
            let result = await store.resolve(DownloadStore.AttemptMutationSubmission.accepted(change: .applied, ticket: ticket), deadline: .after(30))
            guard let self, result == .applied, store.attemptAdmitsWork(key),
                  store.lifecycleState(for: key) == state,
                  admissionPersistenceProofs[key] == proofID else { return }
            admissionPersistenceProofs.removeValue(forKey: key)
            if exemptFromQueuePause { markRowResumedDuringQueuePause(record.ratingKey) }
            admission.noteRequest(record.ratingKey, origin: origin)
            scheduleAdmissionPump()
        }
        return true
    }

    /// Whether a start of `lane` for `id` would be granted right now.
    func admissionHasRoom(for id: String, lane: DownloadAdmissionLane,
                          exemptFromQueuePause: Bool = false) -> Bool {
        guard startupRecoveryState == .ready, admission.recoveryComplete,
              seasonPlanCommitsInFlight == 0, admission.supervised[id] == nil else { return false }
        if let record = store.record(for: id), let key = attemptKey(for: record),
           admissionPersistenceProofs[key] != nil { return false }
        // A row that already holds a lane (a range train rebuilding its request, an adopted
        // remainder) continues under its own admission.
        if let current = store.record(for: id), occupiesAdmissionLane(current) { return true }
        let occupants = admissionOccupants(store.records)
        // #414: a finished render waiting for this slot goes before any new transfer start.
        if DownloadAdmissionLimits.countsTowardTotal(lane),
           staticHandoffIsPending(occupants: occupants) { return false }
        let request = DownloadAdmissionRequest(id: id, lane: lane, origin: .user,
                                               requestedAt: admission.now())
        return !DownloadAdmissionPolicy.grants(
            limits: admission.limits,
            occupants: occupants, requests: [request],
            now: admission.now(), queuePaused: isQueuePaused,
            pauseExemptIDs: exemptFromQueuePause ? [id] : []).isEmpty
    }

    /// A user action on a row (Resume, Retry). Granted at once when a lane has room (and, during
    /// Pause All, exempt for that row only); otherwise it waits as a durable request.
    func admitRowAction(_ record: DownloadRecord) {
        let exempt = isQueuePaused
        let lane = admissionLane(for: record)
        if exempt { markRowResumedDuringQueuePause(record.ratingKey) }
        // A row paused while it waited for its first start goes back to `planned`, so it starts
        // through the refreshed, source-validated first-start path.
        if record.admissionIntent == .seasonPlanned || record.lifecycle == .planned {
            requestAdmission(for: record, origin: .user, exemptFromQueuePause: exempt)
            return
        }
        guard admissionHasRoom(for: record.ratingKey, lane: lane, exemptFromQueuePause: exempt) else {
            requestAdmission(for: record, origin: .user, exemptFromQueuePause: exempt)
            return
        }
        admission.clearRequest(record.ratingKey)
        launchAdmittedStart(record, lane: lane, origin: .user)
    }

    /// A user tap in the download options sheet. Starts at once when a lane has room; otherwise
    /// persists a planned seed (the season row shape) that starts through the same refreshed,
    /// source-validated path when a lane frees. An existing row keeps today's direct start.
    func requestDownload(_ item: MediaItem, backend: DownloadBackendKind,
                         choice: DownloadIntentChoice, mediaIndex: Int, partIndex: Int,
                         audioStreamIndex: Int?, mediaSourceIDOverride: String? = nil) async {
        let id = DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: backend)
        let lane = DownloadAdmissionPolicy.lane(
            backend: backend, downloadLane: DownloadChoicePolicy.downloadLane(for: choice))
        if !admissionHasRoom(for: id, lane: lane) {
            if let existing = store.record(for: id) {
                // An existing parked row waits through its own retry; anything else is refused
                // visibly rather than started past the caps or Pause All.
                if existing.lifecycle == .paused || existing.lifecycle == .failed
                    || existing.lifecycle == .planned {
                    requestAdmission(for: existing, origin: .user)
                } else {
                    lastError[id] = .transferFailed(
                        "Every download slot is busy. Try again when a download finishes.")
                }
                refreshRecords()
                return
            }
            let plan = SeasonEpisodeDownloadPlan(
                item: item, backend: backend, choice: choice, mediaIndex: mediaIndex,
                partIndex: partIndex, audioStreamIndex: audioStreamIndex,
                mediaSourceIDOverride: mediaSourceIDOverride, estimatedBytes: nil, shouldStart: true)
            guard let seed = plannedSeedRecord(for: plan),
                  case .applied = await persistPlannedSeeds([seed]) else {
                recordDownloadDiagnostic("downloads.admission_wait_save_failed", fields: [
                    "download_id": .identifier(id),
                ])
                lastError[id] = .transferFailed(
                    "The download could not be queued. Check available storage and try again.")
                refreshRecords()
                return
            }
            admission.noteRequest(id, origin: .user)
            refreshRecords()
            scheduleAdmissionPump()
            return
        }
        let generation = admission.beginSupervision(id, lane: lane, origin: .user)
        switch backend {
        case .plex:
            await download(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                           audioStreamIndex: audioStreamIndex)
        case .jellyfin:
            await downloadJellyfin(item, choice: choice, mediaIndex: mediaIndex,
                                   partIndex: partIndex, audioStreamIndex: audioStreamIndex,
                                   mediaSourceIDOverride: mediaSourceIDOverride)
        case .emby:
            await downloadEmby(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                               audioStreamIndex: audioStreamIndex,
                               mediaSourceIDOverride: mediaSourceIDOverride)
        }
        await finishAdmittedStart(id, generation: generation, intent: .seasonPlanned)
    }

    /// P4.5: a statically admitted start is about to create server-prep work (a Plex original
    /// that failed preflight, an Emby negotiation rerouted to Convert). It may only if the prep
    /// lane has room; the supervised reservation then moves to that lane. When it is full the
    /// caller ends the start without work, and admission defers the row to retry later.
    func admissionMayEnterServerPrep(_ ratingKey: String) -> Bool {
        admissionMayEnter(.serverPreparation, ratingKey: ratingKey)
    }

    func admissionMayEnter(_ lane: DownloadAdmissionLane, ratingKey: String) -> Bool {
        if admission.supervised[ratingKey]?.lane == lane { return true }
        guard DownloadAdmissionPolicy.mayEnter(
            lane, id: ratingKey, occupants: admissionOccupants(store.records), limits: admission.limits) else {
            recordDownloadDiagnostic("downloads.admission_lane_full", fields: [
                "download_id": .identifier(ratingKey),
                "lane": .label(lane.rawValue),
            ])
            return false
        }
        if let supervision = admission.supervised[ratingKey] {
            admission.switchLane(ratingKey, generation: supervision.generation, to: lane)
        }
        scheduleAdmissionPump()
        return true
    }

    /// B69: re-plan an Original-quality first start whose planner probe failed. Returns nil when
    /// the start must end without work: the probe failed again (admission defers it), the
    /// original is definitively unsupported (the row fails visibly), or the resolved lane is full.
    func resolveUnresolvedOriginalRoute(_ record: DownloadRecord, item: MediaItem,
                                        backend: DownloadBackendKind,
                                        planner: DownloadItemPlanner) async -> DownloadIntentChoice? {
        let generation = admission.supervised[record.ratingKey]?.generation
        let options = await planner.options(
            for: item, preferredAudioLanguage: UserDefaults.standard.string(
                forKey: PlaybackPreferences.Keys.preferredAudioLanguage),
            existingVersionDiscovery: .fetchOnce, backend: backend)
        // The probe suspended: a pause, delete or newer grant since then wins.
        guard let key = attemptKey(for: record), store.attemptAdmitsWork(key),
              let generation, admission.isCurrent(record.ratingKey, generation: generation),
              store.lifecycleState(for: key)?.lifecycle == .admitted else { return nil }
        let choice: DownloadIntentChoice
        switch SeasonDownloadOriginalQualityPolicy.resolve(
            hasOriginal: options.original != nil,
            plexOriginalPreset: backend == .plex
                ? DownloadPresetPolicy.plexOriginalQualityPreset(in: options.presets) : nil,
            hasCompatibleRemux: options.compatibleRemux != nil,
            probeFailed: options.probeFailed) {
        case .original: choice = .original
        case .optimize(let target): choice = .optimize(targetName: target)
        case .compatibleRemux: choice = .optimizeCompatible
        case .unresolved:
            return nil
        case .unsupported:
            lastError[record.ratingKey] = .transferFailed(
                "This episode has no original that plays offline.")
            _ = await applyLifecycleEvent(.transferFailed(.validation), for: key,
                                    context: "admission_original_unsupported")
            return nil
        }
        let lane = DownloadAdmissionPolicy.lane(
            backend: backend, downloadLane: DownloadChoicePolicy.downloadLane(for: choice))
        guard admissionMayEnter(lane, ratingKey: record.ratingKey) else { return nil }
        return choice
    }

    // MARK: - Render handoff (#414)

    static let staticHandoffCheckInterval: Duration = .seconds(1)

    /// The first waiting render, which is next in line for a static slot.
    private var firstStaticHandoffWaiter: String? {
        staticHandoffWaiters.min { $0.value.sequence < $1.value.sequence }?.key
    }

    /// Whether the first waiting render can take a static slot right now. New transfer starts
    /// yield to it; every waiter needs the same slot, so only the first one matters.
    func staticHandoffIsPending(occupants: [DownloadAdmissionOccupant]) -> Bool {
        guard let first = firstStaticHandoffWaiter else { return false }
        return DownloadAdmissionPolicy.mayHandOffToStatic(id: first, occupants: occupants,
                                                          limits: admission.limits)
    }

    /// #414: a server-prep row whose render finished waits here, keeping its prep slot, until a
    /// static transfer slot is free, so several submitted jobs never start more transfers than the
    /// simultaneous-downloads setting allows. Waiters go first come, first served, ahead of new
    /// transfer starts. Returns nil when the wait was cancelled or `isCurrent` stopped holding
    /// (pause, delete, sign-out, a newer attempt); otherwise the row holds a static reservation
    /// until the caller passes the returned token to `endStaticHandoff`.
    func awaitStaticHandoffRoom(for key: DownloadAttemptKey, backend: String,
                                isCurrent: () -> Bool) async -> UUID? {
        let id = key.ratingKey
        let token = UUID()
        let startedAt = admission.now()
        var waiting = false
        defer {
            // Only this wait's own entry and caption are cleared; a newer wait for the row keeps its.
            if staticHandoffWaiters[id]?.token == token {
                staticHandoffWaiters[id] = nil
                if optimizeState[id] == DownloadRowStatusCaptionPolicy.serverPrepReadyState {
                    optimizeState[id] = nil
                }
                scheduleAdmissionPump()
            }
        }
        while true {
            guard !Task.isCancelled, isCurrent() else { return nil }
            let first = firstStaticHandoffWaiter
            if first == nil || first == id,
               DownloadAdmissionPolicy.mayHandOffToStatic(
                id: id, occupants: admissionOccupants(store.records), limits: admission.limits) {
                staticHandoffReservations[id] = token
                if waiting {
                    recordDownloadDiagnostic("downloads.handoff_granted", fields: [
                        "download_id": .identifier(id),
                        "backend": .label(backend),
                        "waited_seconds": .int(Int(admission.now() - startedAt)),
                    ])
                }
                return token
            }
            if !waiting {
                waiting = true
                staticHandoffSequence += 1
                staticHandoffWaiters[id] = (token, staticHandoffSequence)
                optimizeState[id] = DownloadRowStatusCaptionPolicy.serverPrepReadyState
                recordDownloadDiagnostic("downloads.handoff_waiting", fields: [
                    "download_id": .identifier(id),
                    "backend": .label(backend),
                ])
                refreshRecords()
            }
            do { try await Task.sleep(for: Self.staticHandoffCheckInterval) } catch { return nil }
        }
    }

    /// Ends a handoff reservation once the transfer start returned (its own occupancy is
    /// observable by then) or failed. Only the wait that took the reservation can end it.
    func endStaticHandoff(_ id: String, token: UUID) {
        guard staticHandoffReservations[id] == token else { return }
        staticHandoffReservations[id] = nil
        scheduleAdmissionPump()
    }

    /// Pause and delete end a row's supervised start and forget its request and exemption.
    func withdrawAdmission(ratingKey: String) {
        admission.invalidate(ratingKey)
        admission.revokeExemption(ratingKey)
    }
}
