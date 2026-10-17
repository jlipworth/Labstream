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
            occupants.append(.init(id: record.ratingKey, lane: admissionLane(for: record)))
            observed.insert(record.ratingKey)
        }
        for (id, supervision) in admission.supervised where !observed.contains(id) {
            occupants.append(.init(id: id, lane: supervision.lane))
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
            guard let key = attemptKey(for: record), store.attemptAdmitsWork(key) else { continue }
            waiting[record.ratingKey] = record
            requests.append(admission.request(for: record.ratingKey, lane: admissionLane(for: record)))
        }
        let now = admission.now()
        let grants = DownloadAdmissionPolicy.grants(
            occupants: occupants, requests: requests, now: now,
            queuePaused: isQueuePaused, pauseExemptIDs: admission.pauseExemptions)
        for grant in grants {
            guard let record = waiting[grant.id] else { continue }
            launchAdmittedStart(record, lane: grant.lane, origin: grant.origin)
        }
        let granted = Set(grants.map(\.id))
        scheduleAdmissionWake(at: DownloadAdmissionPolicy.nextEligibleTime(
            requests: requests.filter { !granted.contains($0.id) }, now: now))
        // Automatic static resumes keep a pending-resume marker while they wait for a lane; drain
        // them when the static lane has room after this pass's grants.
        if hasPendingStaticRangeResumes,
           admissionHasRoom(for: "\u{1F}static-drain", lane: .staticFile) {
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
            self.finishAdmittedStart(id, generation: generation,
                                     intent: firstStart ? .seasonPlanned : .retryRequested)
        }
    }

    /// A planned first start: grant (`planned` → `admitted`), then the season planner's refreshed,
    /// source-validated start (`startPlannedRecord`).
    private func runFirstStart(_ record: DownloadRecord, generation: UUID) async {
        guard let key = attemptKey(for: record),
              admission.isCurrent(record.ratingKey, generation: generation),
              applyLifecycleEvent(.admissionGranted, for: key, context: "admission_granted"),
              let granted = store.record(for: key) else { return }
        await startPlannedRecord(granted)
    }

    /// Classify a supervised start after its async work finished (P4.4). Never rewrites a row the
    /// user paused, a deleting row, or a row a newer generation owns.
    func finishAdmittedStart(_ id: String, generation: UUID, intent: DownloadAdmissionIntent) {
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
                deferred = applyLifecycleEvent(.admissionDeferred(.seasonPlanned), for: key,
                                               context: "admission_deferred")
            case .retryRequested:
                deferred = applyLifecycleEvent(.backendUnavailable(.deferredResume), for: key,
                                               context: "admission_deferred")
                    && applyLifecycleEvent(.admissionRequested(.retryRequested), for: key,
                                           context: "admission_deferred")
            }
            if deferred { noteAdmissionDeferral(id, reason: "start_unproven") }
        case .planned?:
            noteAdmissionDeferral(id, reason: "still_planned")
        case .paused?:
            let cause = store.lifecycleState(for: key)?.history.pauseCause
            guard cause != DownloadPauseCause.user else {
                admission.clearRequest(id)
                return
            }
            // Parked by the start itself (backend not ready, session mismatch): retry with backoff.
            if record.admissionIntent == .retryRequested
                || applyLifecycleEvent(.admissionRequested(.retryRequested), for: key,
                                       context: "admission_deferred") {
                noteAdmissionDeferral(id, reason: "parked")
            }
        case .failed?, nil:
            // A definitive refusal (signed out, source gone, storage) stays a visible failure and
            // no longer waits (the reducer's failure clears the intent; withdraw any leftover).
            admission.clearRequest(id)
            if record.admissionIntent != nil {
                _ = applyLifecycleEvent(.admissionWithdrawn, for: key, context: "admission_refused")
            }
        }
    }

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
        // A first start (planned, or paused while planned) re-requests its first start (B65);
        // every other parked row waits for its retry.
        let intent: DownloadAdmissionIntent = record.lifecycle == .planned
            || record.admissionIntent == .seasonPlanned ? .seasonPlanned : .retryRequested
        if !isWaitingForAdmission(record) || record.admissionIntent != intent {
            guard applyLifecycleEvent(.admissionRequested(intent), for: key,
                                      context: "admission_requested") else { return false }
        }
        if exemptFromQueuePause { admission.exempt(record.ratingKey) }
        admission.noteRequest(record.ratingKey, origin: origin)
        scheduleAdmissionPump()
        return true
    }

    /// Whether a start of `lane` for `id` would be granted right now.
    func admissionHasRoom(for id: String, lane: DownloadAdmissionLane,
                          exemptFromQueuePause: Bool = false) -> Bool {
        guard startupRecoveryState == .ready, admission.recoveryComplete,
              seasonPlanCommitsInFlight == 0, admission.supervised[id] == nil else { return false }
        let request = DownloadAdmissionRequest(id: id, lane: lane, origin: .user,
                                               requestedAt: admission.now())
        return !DownloadAdmissionPolicy.grants(
            occupants: admissionOccupants(store.records), requests: [request],
            now: admission.now(), queuePaused: isQueuePaused,
            pauseExemptIDs: exemptFromQueuePause ? [id] : []).isEmpty
    }

    /// A user action on a row (Resume, Retry). Granted at once when a lane has room (and, during
    /// Pause All, exempt for that row only); otherwise it waits as a durable request.
    func admitRowAction(_ record: DownloadRecord) {
        let exempt = isQueuePaused
        let lane = admissionLane(for: record)
        if exempt { admission.exempt(record.ratingKey) }
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
        if store.record(for: id) == nil, !admissionHasRoom(for: id, lane: lane) {
            let plan = SeasonEpisodeDownloadPlan(
                item: item, backend: backend, choice: choice, mediaIndex: mediaIndex,
                partIndex: partIndex, audioStreamIndex: audioStreamIndex,
                mediaSourceIDOverride: mediaSourceIDOverride, estimatedBytes: nil, shouldStart: true)
            if let seed = plannedSeedRecord(for: plan),
               case .applied = await persistPlannedSeeds([seed]) {
                admission.noteRequest(id, origin: .user)
                refreshRecords()
                scheduleAdmissionPump()
                return
            }
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
        finishAdmittedStart(id, generation: generation, intent: .seasonPlanned)
    }

    /// P4.5: a statically admitted start is about to create server-prep work (a Plex original
    /// that failed preflight, an Emby negotiation rerouted to Convert). It may only if the prep
    /// lane has room; the supervised reservation then moves to that lane. When it is full the
    /// caller ends the start without work, and admission defers the row to retry later.
    func admissionMayEnterServerPrep(_ ratingKey: String) -> Bool {
        guard DownloadAdmissionPolicy.mayEnter(
            .serverPreparation, id: ratingKey, occupants: admissionOccupants(store.records)) else {
            recordDownloadDiagnostic("downloads.admission_lane_full", fields: [
                "download_id": .identifier(ratingKey),
                "lane": .label(DownloadAdmissionLane.serverPreparation.rawValue),
            ])
            return false
        }
        if let supervision = admission.supervised[ratingKey] {
            admission.switchLane(ratingKey, generation: supervision.generation,
                                 to: .serverPreparation)
        }
        scheduleAdmissionPump()
        return true
    }

    /// Pause and delete end a row's supervised start and forget its request and exemption.
    func withdrawAdmission(ratingKey: String) {
        admission.invalidate(ratingKey)
        admission.revokeExemption(ratingKey)
    }
}
