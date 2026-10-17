import Foundation
import PMSKit

/// Serializes Emby Convert job adoption and cancellation per server (P2.3, B49). Crash-window
/// recovery holds it from its job-list GET through the durable adoption commit; journaled cleanup
/// holds it from its list GET through the DELETE and the metadata clear. Neither can then act on a
/// job list that the other is about to change.
@MainActor
final class EmbyConvertJobCoordinator {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func key(baseURL: URL, serverID: String?) -> String {
        if let serverID, !serverID.isEmpty { return "id:\(serverID)" }
        return "url:\(baseURL.absoluteString.lowercased())"
    }

    func acquire(_ key: String) async {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume() // Ownership passes directly to the next waiter.
        } else {
            held.remove(key)
        }
    }

    func withExclusiveAccess<T>(_ key: String, _ body: () async -> T) async -> T {
        await acquire(key)
        let value = await body()
        release(key)
        return value
    }
}

extension DownloadManager {
    /// Synthetic attempt-id prefix for intents migrated from legacy Emby tombstones, which carry no
    /// attempt id of their own.
    static let legacyTombstoneAttemptPrefix = "legacy-tombstone-"

    func makeCleanupRunnerDependencies() -> DownloadCleanupIntentRunner.Dependencies {
        let journal = cleanupIntentJournal
        return DownloadCleanupIntentRunner.Dependencies(
            runBarriers: { [weak self] in self?.runCleanupBarriers() ?? true },
            load: { journal.load() },
            replace: { journal.replace($0) },
            rowState: { [weak self] intent in self?.cleanupRowState(for: intent) ?? .unknown },
            isBlocked: { [weak self] intent in self?.cleanupIntentIsBlocked(intent) ?? true },
            hasMatchingSession: { [weak self] intent in
                guard let live = self?.appModel.backendSession(for: intent.backend) else {
                    return false
                }
                return intent.matches(session: live)
            },
            execute: { [weak self] intent in
                await self?.executeCleanupIntent(intent) ?? .waiting
            },
            diagnostic: { [weak self] name, fields in
                self?.recordDownloadDiagnostic(name, fields: fields)
            })
    }

    /// Backends that owe server cleanup and therefore need a session even while inactive: any
    /// journaled intent, a terminal row whose launch sweep will journal a handle, or a legacy
    /// tombstone awaiting migration. Read once per recovery pass, before session hydration.
    func pendingCleanupBackends() -> Set<DownloadBackendKind> {
        var backends: Set<DownloadBackendKind> = []
        if case .loaded(let intents) = cleanupIntentJournal.load() {
            backends.formUnion(intents.map(\.backend))
        }
        for record in records where record.status == .complete || record.status == .failed
            || record.status == .unverified {
            guard let metadata = record.metadata else { continue }
            let backend = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
            if backend != .plex,
               metadata.playSessionID?.isEmpty == false
                || metadata.embyConvertJobID != nil
                || metadata.hasEmbyConvertCrashWindowIdentity {
                backends.insert(backend)
            }
        }
        if case .loaded(let tombstones) = store.loadEmbyConvertCleanupTombstones(),
           !tombstones.isEmpty {
            backends.insert(.emby)
        }
        // Legacy quarantined Plex intents are imported by the sweep that runs after hydration.
        if cleanupIntentJournal.hasLegacyQuarantineFiles() {
            backends.insert(.plex)
        }
        return backends
    }

    // MARK: - Producers

    /// Journal that `originAttempt` abandons a server resource and kick the runner. Identity
    /// comes from the session the abandoning work captured, so it needs no surviving row.
    /// Returns false when the intent could not be made durable; each caller decides its fallback.
    @discardableResult
    func journalCleanupAbandonment(
        _ operation: DurableDownloadCleanupIntent.Operation,
        originAttempt: DownloadAttemptKey,
        session: BackendSession,
        plexCreate: DurableDownloadCleanupIntent.PlexCreateEvidence? = nil,
        reason: String
    ) -> Bool {
        guard let server = DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: session.baseURL, serverID: session.serverID,
                userID: session.kind == .plex ? nil : session.userID),
              let intent = DurableDownloadCleanupIntent(
                attemptKey: originAttempt, backend: session.kind, server: server,
                operation: operation, provenance: .abandonment(originAttempt: originAttempt),
                plexCreate: plexCreate, recordedAtEpochSeconds: Date().timeIntervalSince1970),
              case .committed = cleanupIntentJournal.ensure(intent) else {
            recordDownloadDiagnostic("downloads.cleanup_abandonment_not_durable", fields: [
                "download_id": .identifier(originAttempt.ratingKey),
                "operation": .label(Self.cleanupOperationLabel(operation)),
                "reason": .label(reason),
            ])
            return false
        }
        cleanupRunner?.kick(reason: reason)
        return true
    }

    /// The live session for `kind` when it targets the same server *and user* the work captured;
    /// otherwise a session built from the captured identity. Never rebinds old work to whichever
    /// account is current.
    func cleanupSession(kind: DownloadBackendKind, server: URL, token: String,
                        userID: String?) -> BackendSession {
        if let live = appModel.backendSession(for: kind),
           BackendURLIdentity.sameBaseURL(live.baseURL, server) {
            let sameUser: Bool
            switch (userID, live.userID) {
            case (nil, _): sameUser = kind == .plex
            case (let captured?, let current?):
                sameUser = MediaBrowserUserIdentity.sameUser(captured, current)
            case (_?, nil): sameUser = false
            }
            if sameUser { return live }
        }
        return BackendSession(kind: kind, baseURL: server, token: token, userID: userID,
                              serverID: nil)
    }

    // MARK: - Launch barriers

    /// Runs on every recovery pass once startup recovery is ready: migrate legacy tombstones and
    /// legacy quarantined Plex intents into the journal, then open the runner. Both barriers are
    /// idempotent, so a transient failure (locked data, full disk) is retried by the next pass;
    /// intents behind an unfinished barrier stay blocked meanwhile.
    func prepareCleanupRunnerIfNeeded() {
        guard startupRecoveryState == .ready else { return }
        _ = runCleanupBarriers()
        cleanupRunner?.enable()
    }

    /// Migrate legacy tombstones and import legacy quarantined Plex intents. Idempotent and
    /// cheap when there is nothing left; the runner calls it before every pass so a transient
    /// failure retries on the runner's own timer. Returns true once both barriers are complete.
    func runCleanupBarriers() -> Bool {
        let tombstonesDone = migrateLegacyEmbyCleanupTombstones()
        legacyCleanupImport = cleanupIntentJournal.importLegacyQuarantinedPlexIntents()
        let importDone = !legacyCleanupImport.blocksAllPlex && legacyCleanupImport.blockedIDs.isEmpty
        if legacyCleanupImport.importedCount > 0 || !importDone {
            recordDownloadDiagnostic("downloads.cleanup_legacy_plex_import", fields: [
                "imported": .int(legacyCleanupImport.importedCount),
                "blocked": .int(legacyCleanupImport.blockedIDs.count),
                "blocks_all": .bool(legacyCleanupImport.blocksAllPlex),
            ])
        }
        return tombstonesDone && importDone
    }

    /// P2.5: each legacy tombstone becomes an `ambiguousCreate` abandonment intent with the
    /// tombstone's UUID and a synthetic attempt, then the tombstone is removed. Until that removal
    /// is durable the runner skips the intent (`cleanupIntentIsBlocked`), so a retained tombstone
    /// can never recreate an intent that already drained. Tombstones that cannot be converted are
    /// kept as evidence; an unreadable tombstone file is left untouched.
    /// Returns true when no convertible tombstone remains (an unreadable file is not done).
    @discardableResult
    func migrateLegacyEmbyCleanupTombstones() -> Bool {
        guard case .loaded(let tombstones) = store.loadEmbyConvertCleanupTombstones() else {
            return false
        }
        guard !tombstones.isEmpty else { return true }
        var migrated = 0
        var unconvertible = 0
        for tombstone in tombstones {
            guard let attemptID = DownloadAttemptID(
                    rawValue: Self.legacyTombstoneAttemptPrefix + tombstone.id.uuidString),
                  let intent = Self.legacyTombstoneIntent(tombstone, attemptID: attemptID) else {
                unconvertible += 1
                continue
            }
            guard case .committed = cleanupIntentJournal.ensure(intent) else { continue }
            if case .committed = store.removeEmbyConvertCleanupTombstone(id: tombstone.id) {
                migrated += 1
            }
        }
        recordDownloadDiagnostic("downloads.cleanup_tombstones_migrated", fields: [
            "migrated": .int(migrated),
            "unconvertible": .int(unconvertible),
            "remaining": .int(tombstones.count - migrated),
        ])
        // Unconvertible tombstones stay as evidence and are not retried.
        return migrated + unconvertible == tombstones.count
    }

    nonisolated static func legacyTombstoneIntent(
        _ tombstone: DownloadStore.EmbyConvertCleanupTombstone,
        attemptID: DownloadAttemptID
    ) -> DurableDownloadCleanupIntent? {
        let key = DownloadAttemptKey(ratingKey: tombstone.ratingKey, attemptID: attemptID)
        guard let candidate = makeEmbyConvertCleanupIntent(
            attemptKey: key, metadata: tombstone.metadata,
            provenance: .abandonment(originAttempt: key)) else { return nil }
        return DurableDownloadCleanupIntent(
            id: tombstone.id, attemptKey: key, backend: candidate.backend,
            server: candidate.server, operation: candidate.operation,
            provenance: candidate.provenance,
            recordedAtEpochSeconds: candidate.recordedAtEpochSeconds)
    }

    // MARK: - Runner dependencies

    func cleanupRowState(
        for intent: DurableDownloadCleanupIntent
    ) -> CleanupIntentEligibilityPolicy.RowState {
        guard startupRecoveryState == .ready else { return .unknown }
        switch store.cleanupDisposition(for: intent.attemptKey) {
        case .unknown: return .unknown
        case .retiring: return .retiring
        case .committedAbsent: return .committedAbsent
        case .present(let record):
            let isTerminal = record.status == .complete || record.status == .failed
                || record.status == .unverified
            var protects = false
            if case .embyConvert = intent.operation, let metadata = record.metadata {
                // B44/B49: the same inputs as the Retry gate and the launch sweep.
                protects = DownloadRetryPreparationPolicy.shouldKeepEmbyConvertAuthorityForRetry(
                    status: record.status,
                    resumeMode: metadata.resolvedResumeMode(ratingKey: record.ratingKey),
                    isEmbyRecord: DownloadRecordIdentity.isEmbyRecordKey(record.ratingKey),
                    hasEmbyConvertJobID: metadata.embyConvertJobID != nil,
                    hasEmbyConvertRecoveryIdentity: metadata.hasEmbyConvertRecoveryIdentity)
            }
            return .present(isTerminal: isTerminal, protectsResource: protects)
        }
    }

    func cleanupIntentIsBlocked(_ intent: DurableDownloadCleanupIntent) -> Bool {
        if intent.attemptKey.attemptID.rawValue.hasPrefix(Self.legacyTombstoneAttemptPrefix) {
            switch store.loadEmbyConvertCleanupTombstones() {
            case .loaded(let tombstones): return tombstones.contains { $0.id == intent.id }
            case .failed: return true
            }
        }
        if case .plexOptimize = intent.operation {
            return legacyCleanupImport.blocksAllPlex
                || legacyCleanupImport.blockedIDs.contains(intent.id)
        }
        return false
    }

    // MARK: - Execution

    func executeCleanupIntent(
        _ intent: DurableDownloadCleanupIntent
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        guard let live = appModel.backendSession(for: intent.backend),
              intent.matches(session: live) else { return .failed }
        return await runAsRequiredCleanup(intent.attemptKey) { [weak self] in
            guard let self else { return .waiting }
            switch intent.operation {
            case .activeEncoding(let playSessionID):
                return await self.executeActiveEncodingCleanup(
                    intent, playSessionID: playSessionID, live: live)
            case .embyConvert(let identity):
                let key = EmbyConvertJobCoordinator.key(baseURL: live.baseURL, serverID: live.serverID)
                return await self.embyConvertJobCoordinator.withExclusiveAccess(key) {
                    await self.executeEmbyConvertCleanup(intent, identity: identity, live: live)
                }
            case .plexOptimize(let queueTitle):
                return await self.executePlexOptimizeCleanup(
                    intent, queueTitle: queueTitle, live: live)
            }
        }
    }

    /// Required cleanup stays registered with the work registry (never cancelled with its attempt)
    /// while the runner awaits its outcome.
    private func runAsRequiredCleanup(
        _ key: DownloadAttemptKey,
        _ body: @escaping @MainActor @Sendable () async -> DownloadCleanupIntentRunner.ExecutionOutcome
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        await withCheckedContinuation { continuation in
            downloadWorkRegistry.start(for: key, kind: .requiredCleanup) {
                continuation.resume(returning: await body())
            }
        }
    }

    /// Rows that may still claim the intent's server resource, read at the moment of the call:
    /// rows on the same persisted server and user, not being deleted.
    ///
    /// For an abandonment the origin row claims too, by the same persisted reference. Producers
    /// hand authority over by clearing their own reference only after the intent commits, so a
    /// write that looked failed (the producer kept the resource, and may later park the row as
    /// failed-but-retryable) leaves the reference in place and the intent waits. Row status cannot
    /// prove a handoff; the reference can. A terminal release or deletion never counts its own
    /// row: releasing that row's handle is the intent's purpose.
    ///
    /// Encoders differ: a forward-only encoder is never resumed (a paused, failed or finished row
    /// negotiates a new PlaySessionId), so an encoder abandonment's origin claims only while its
    /// transfer is active. The executor then clears the exact persisted reference itself, which
    /// makes an interrupted producer handoff replayable after relaunch.
    func claimingRecords(for intent: DurableDownloadCleanupIntent) -> [DownloadRecord] {
        store.records.filter { record in
            guard let attemptID = record.attemptID,
                  let metadata = record.metadata,
                  metadata.resolvedBackendKind(ratingKey: record.ratingKey) == intent.backend,
                  Self.persistedServer(of: metadata, matches: intent.server) else { return false }
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
            guard !store.isDeletionPending(for: key) else { return false }
            if key == intent.attemptKey {
                guard case .abandonment = intent.provenance else { return false }
                if case .activeEncoding = intent.operation {
                    return record.status == .downloading || record.status == .queued
                        || record.status == .preparing
                }
                return true
            }
            return true
        }
    }

    /// Whether a row's persisted server/user identity can be the intent's. Missing row identity
    /// matches (conservatively claims); a different server or user never does.
    nonisolated static func persistedServer(
        of metadata: OfflineMetadata,
        matches server: DurableDownloadCleanupIntent.ServerIdentity
    ) -> Bool {
        func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        if let serverID = server.serverID, let rowServerID = nonEmpty(metadata.backendServerID) {
            guard serverID == rowServerID else { return false }
        } else if let base = URL(string: server.baseURLString),
                  let rowBase = nonEmpty(metadata.backendBaseURLString).flatMap(URL.init(string:)) {
            guard BackendURLIdentity.sameBaseURL(base, rowBase) else { return false }
        }
        if let userID = server.userID, let rowUserID = nonEmpty(metadata.backendUserID) {
            guard MediaBrowserUserIdentity.sameUser(userID, rowUserID) else { return false }
        }
        return true
    }

    /// Eligibility can change while an executor awaits the server; re-read it before acting.
    private func cleanupStillEligible(_ intent: DurableDownloadCleanupIntent) -> Bool {
        CleanupIntentEligibilityPolicy.decision(
            provenance: intent.provenance, rowState: cleanupRowState(for: intent)) == .run
    }

    private func retire(_ intent: DurableDownloadCleanupIntent)
        async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        let journal = cleanupIntentJournal
        let removal = await Task.detached {
            journal.remove(id: intent.id, attemptKey: intent.attemptKey, operation: intent.operation)
        }.value
        guard case .committed = removal else { return .failed }
        recordDownloadDiagnostic("downloads.cleanup_intent_retired", fields: [
            "download_id": .identifier(intent.attemptKey.ratingKey),
            "operation": .label(Self.cleanupOperationLabel(intent.operation)),
        ])
        return .retired
    }

    nonisolated static func cleanupOperationLabel(
        _ operation: DurableDownloadCleanupIntent.Operation
    ) -> String {
        switch operation {
        case .activeEncoding: return "active_encoding"
        case .embyConvert(.knownJob): return "emby_convert_known"
        case .embyConvert(.ambiguousCreate): return "emby_convert_ambiguous"
        case .plexOptimize: return "plex_optimize"
        }
    }

    private func executeActiveEncodingCleanup(
        _ intent: DurableDownloadCleanupIntent,
        playSessionID: String,
        live: BackendSession
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        let others = claimingRecords(for: intent)
        let otherKeys = Set(others.compactMap { record in
            record.attemptID.map { DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0) }
        })
        let inMemory = embyPlaySessionByAttempt.merging(jellyfinPlaySessionByAttempt) { a, _ in a }
            .filter { otherKeys.contains($0.key) }.values
        let claimed = Set(others.compactMap { $0.metadata?.playSessionID }).union(inMemory)
        guard !claimed.contains(playSessionID) else { return .waiting }

        let confirmedGone: Bool
        switch intent.backend {
        case .jellyfin:
            confirmedGone = await JellyfinBrowseService(appModel: appModel)
                .stopActiveEncoding(playSessionId: playSessionID, session: live)
        case .emby:
            confirmedGone = await EmbyBrowseService(appModel: appModel)
                .stopActiveEncoding(playSessionId: playSessionID, session: live)
        case .plex:
            confirmedGone = false
        }
        guard confirmedGone else { return .failed }
        switch store.clearPlaySessionID(for: intent.attemptKey, expectedPlaySessionID: playSessionID) {
        case .persistenceFailed:
            // Repeat the idempotent stop later; never drop the only durable record while the row
            // clear is still unproven.
            return .failed
        case .cleared, .alreadyAbsent, .expectedValueMismatch, .staleOrMissing:
            return await retire(intent)
        }
    }

    /// Claims on Emby Convert jobs held by live rows, read at one instant.
    private struct EmbyConvertClaims {
        var jobIDs: Set<Int>
        var recoveryIdentities: [EmbyConvertRecoveryPolicy.LiveRecoveryIdentity]
    }

    private func embyConvertClaims(for intent: DurableDownloadCleanupIntent) -> EmbyConvertClaims {
        let rows = claimingRecords(for: intent).compactMap(\.metadata)
        return EmbyConvertClaims(
            jobIDs: Set(rows.compactMap(\.embyConvertJobID)),
            recoveryIdentities: rows.compactMap { metadata in
                guard metadata.embyConvertJobID == nil,
                      let baseline = metadata.embyConvertJobBaselineIDs,
                      let fingerprint = metadata.embyConvertRecoveryFingerprint,
                      let started = metadata.embyConvertRecoveryStartedAtEpochSeconds,
                      let phase = metadata.embyConvertRecoveryPhase else { return nil }
                return .init(baselineJobIDs: Set(baseline), fingerprint: fingerprint,
                             attemptStartedAtEpochSeconds: started, phase: phase)
            })
    }

    private func executeEmbyConvertCleanup(
        _ intent: DurableDownloadCleanupIntent,
        identity: DurableDownloadCleanupIntent.EmbyConvertIdentity,
        live: BackendSession
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        guard let currentUserID = live.userID else { return .failed }
        let identityHeaders = appModel.identity.emby
        var list: EmbyConvertJobList?
        var claims = embyConvertClaims(for: intent)
        // The decision below must use claims read after the last await: a Convert create can
        // publish a job id or recovery identity while the job list is in flight (B49).
        while true {
            var needsList = !claims.recoveryIdentities.isEmpty
            if case .ambiguousCreate = identity { needsList = true }
            guard needsList, list == nil else { break }
            do {
                let request = try EmbyConvertRequest.jobListRequest(
                    server: live.baseURL, token: live.token, identity: identityHeaders)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return .failed
                }
                list = try EmbyConvertRequest.decodeJobList(from: data)
            } catch {
                return .failed
            }
            guard cleanupStillEligible(intent) else { return .waiting }
            claims = embyConvertClaims(for: intent)
        }
        if !claims.recoveryIdentities.isEmpty, list?.isComplete != true {
            return .failed // Cannot prove another row's recovery does not own the job.
        }
        let now = Date().timeIntervalSince1970
        let claimed = EmbyConvertRecoveryPolicy.claimedJobIDs(
            liveJobIDs: claims.jobIDs, liveRecoveryIdentities: claims.recoveryIdentities,
            jobs: list?.items ?? [], nowEpochSeconds: now)

        let jobToCancel: Int?
        switch identity {
        case .knownJob(let jobID):
            guard !claimed.contains(jobID) else { return .waiting }
            jobToCancel = jobID
        case .ambiguousCreate(let baseline, let fingerprint, let started, let phase):
            guard let list,
                  EmbyConvertRecoveryPolicy.publicUserMatches(
                    currentSessionUserID: currentUserID,
                    persistedBackendUserID: intent.server.userID,
                    fingerprintUserID: fingerprint.userId) else { return .failed }
            switch EmbyConvertRecoveryPolicy.cleanupAction(
                baselineJobIDs: Set(baseline), jobs: list.items, listIsComplete: list.isComplete,
                fingerprint: fingerprint, attemptStartedAtEpochSeconds: started, phase: phase,
                nowEpochSeconds: now, liveJobIDs: claimed
            ) {
            case .retainTombstone: return .failed
            case .discardTombstone: jobToCancel = nil
            case .cancel(let jobID): jobToCancel = jobID
            }
        }

        if let jobToCancel {
            do {
                let request = try EmbyConvertRequest.deleteJobRequest(
                    server: live.baseURL, token: live.token, identity: identityHeaders,
                    jobId: jobToCancel)
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) || [404, 410].contains(http.statusCode)
                else { return .failed }
            } catch {
                return .failed
            }
        }
        guard clearEmbyConvertMetadataIfExact(intent) else { return .failed }
        return await retire(intent)
    }

    private func plexClaimedTitles(for intent: DurableDownloadCleanupIntent) -> Set<String> {
        // Prep attempts register their title before a row exists. The intent's own registration
        // counts on the same terms as its row in `claimingRecords`.
        let ownRegistrationClaims: Bool
        if case .abandonment = intent.provenance { ownRegistrationClaims = true } else {
            ownRegistrationClaims = false
        }
        return Set(claimingRecords(for: intent).compactMap { $0.metadata?.optimizeQueueTitle })
            .union(serverPrepAttempts.protectedQueueTitles(
                excluding: ownRegistrationClaims ? [] : [intent.attemptKey]))
    }

    private func executePlexOptimizeCleanup(
        _ intent: DurableDownloadCleanupIntent,
        queueTitle: String,
        live: BackendSession
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        guard !plexClaimedTitles(for: intent).contains(queueTitle) else { return .waiting }

        let identity = appModel.identity
        guard let bgKey = await bgKeyForPolling(
            server: live.baseURL, token: live.token, identity: identity) else { return .failed }
        let trimmed = bgKey.hasPrefix("/") ? String(bgKey.dropFirst()) : bgKey
        let listRequest = PlexRequest(
            url: live.baseURL.appendingPathComponent(trimmed), method: "GET", queryItems: [],
            headers: PlexHeaders.standard(identity: identity, token: live.token))
        guard let queue = try? await appModel.client.send(
            listRequest, as: BackgroundProcessingItems.self) else { return .failed }
        // Re-read eligibility and claims after the awaits, immediately before acting.
        guard cleanupStillEligible(intent),
              !plexClaimedTitles(for: intent).contains(queueTitle) else { return .waiting }

        let outcome = queue.cleanupOutcome(queueTitle: queueTitle)
        recordDownloadDiagnostic("downloads.optimize_cleanup_outcome", fields: [
            "download_id": .identifier(intent.attemptKey.ratingKey),
            "outcome": .label(Self.plexOutcomeLabel(outcome)),
            "create": .label(intent.plexCreate?.rawValue ?? "unknown"),
        ])
        switch outcome {
        case .cancellable(let itemID):
            let delete = OptimizeRequest.removeBackgroundItem(
                server: live.baseURL, token: live.token, identity: identity,
                backgroundProcessingKey: bgKey, itemID: itemID)
            guard (try? await appModel.client.send(delete)) != nil else { return .failed }
            return await retire(intent)
        case .completed:
            // D2: a finished render stays on the server.
            return await retire(intent)
        case .absent where intent.plexCreate == .confirmed:
            return await retire(intent)
        case .absent, .malformed, .uncertain:
            // Only an unresolved create may expire; malformed or ambiguous evidence about an
            // item is retained (slowly) until it becomes decidable.
            let mayExpire = outcome == .absent
            switch CleanupIntentRetryPolicy.plexRetention(
                recordedAtEpochSeconds: intent.recordedAtEpochSeconds,
                nowEpochSeconds: Date().timeIntervalSince1970,
                mayRetire: mayExpire) {
            case .retire:
                recordDownloadDiagnostic("downloads.optimize_cleanup_expired", fields: [
                    "download_id": .identifier(intent.attemptKey.ratingKey),
                    "outcome": .label(Self.plexOutcomeLabel(outcome)),
                ])
                return await retire(intent)
            case .retain(let minimumDelay):
                return .retained(minimumDelaySeconds: minimumDelay)
            }
        }
    }

    nonisolated static func plexOutcomeLabel(_ outcome: BackgroundProcessingItems.CleanupOutcome) -> String {
        switch outcome {
        case .malformed: return "malformed"
        case .absent: return "absent"
        case .completed: return "completed"
        case .cancellable: return "cancellable"
        case .uncertain: return "uncertain"
        }
    }
}
