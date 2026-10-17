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

    /// Backends with at least one journaled cleanup intent (read once per recovery pass).
    func journaledCleanupBackends() -> Set<DownloadBackendKind> {
        guard case .loaded(let intents) = cleanupIntentJournal.load() else { return [] }
        return Set(intents.map(\.backend))
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

    /// The live session for `kind` when it targets `server`; otherwise a session for that server
    /// carrying the caller's credentials (identity only — never used to pick a different server).
    func cleanupSession(kind: DownloadBackendKind, server: URL, token: String,
                        userID: String?) -> BackendSession {
        if let live = appModel.backendSession(for: kind),
           BackendURLIdentity.sameBaseURL(live.baseURL, server) {
            return live
        }
        return BackendSession(kind: kind, baseURL: server, token: token, userID: userID,
                              serverID: nil)
    }

    // MARK: - Launch barriers

    /// Runs once per process after startup recovery is ready: migrate legacy tombstones and
    /// legacy quarantined Plex intents into the journal, then open the runner. Until both
    /// barriers have run, the runner executes nothing.
    func prepareCleanupRunnerIfNeeded() {
        guard startupRecoveryState == .ready, !cleanupRunnerPrepared else { return }
        cleanupRunnerPrepared = true
        migrateLegacyEmbyCleanupTombstones()
        legacyCleanupImport = cleanupIntentJournal.importLegacyQuarantinedPlexIntents()
        if legacyCleanupImport.importedCount > 0 || legacyCleanupImport.blocksAllPlex
            || !legacyCleanupImport.blockedIDs.isEmpty {
            recordDownloadDiagnostic("downloads.cleanup_legacy_plex_import", fields: [
                "imported": .int(legacyCleanupImport.importedCount),
                "blocked": .int(legacyCleanupImport.blockedIDs.count),
                "blocks_all": .bool(legacyCleanupImport.blocksAllPlex),
            ])
        }
        cleanupRunner?.enable()
    }

    /// P2.5: each legacy tombstone becomes an `ambiguousCreate` abandonment intent with the
    /// tombstone's UUID and a synthetic attempt, then the tombstone is removed. Until that removal
    /// is durable the runner skips the intent (`cleanupIntentIsBlocked`), so a retained tombstone
    /// can never recreate an intent that already drained. Tombstones that cannot be converted are
    /// kept as evidence; an unreadable tombstone file is left untouched.
    func migrateLegacyEmbyCleanupTombstones() {
        guard case .loaded(let tombstones) = store.loadEmbyConvertCleanupTombstones(),
              !tombstones.isEmpty else { return }
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

    /// Rows other than the intent's own attempt (and its abandoning origin) that may claim the
    /// same server resource. Rows being deleted claim nothing.
    private func claimingRecords(for intent: DurableDownloadCleanupIntent) -> [DownloadRecord] {
        var excluded: Set<DownloadAttemptKey> = [intent.attemptKey]
        if case .abandonment(let origin) = intent.provenance { excluded.insert(origin) }
        return store.records.filter { record in
            guard let attemptID = record.attemptID else { return false }
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
            guard !excluded.contains(key), !store.isDeletionPending(for: key) else { return false }
            return record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey) == intent.backend
        }
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

    private func executeEmbyConvertCleanup(
        _ intent: DurableDownloadCleanupIntent,
        identity: DurableDownloadCleanupIntent.EmbyConvertIdentity,
        live: BackendSession
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        guard let currentUserID = live.userID else { return .failed }
        let others = claimingRecords(for: intent).compactMap(\.metadata)
        let otherJobIDs = Set(others.compactMap(\.embyConvertJobID))
        let otherRecoveryIdentities: [EmbyConvertRecoveryPolicy.LiveRecoveryIdentity] =
            others.compactMap { metadata in
                guard metadata.embyConvertJobID == nil,
                      let baseline = metadata.embyConvertJobBaselineIDs,
                      let fingerprint = metadata.embyConvertRecoveryFingerprint,
                      let started = metadata.embyConvertRecoveryStartedAtEpochSeconds,
                      let phase = metadata.embyConvertRecoveryPhase else { return nil }
                return .init(baselineJobIDs: Set(baseline), fingerprint: fingerprint,
                             attemptStartedAtEpochSeconds: started, phase: phase)
            }
        let identityHeaders = appModel.identity.emby
        let needsList: Bool
        if case .ambiguousCreate = identity { needsList = true } else {
            needsList = !otherRecoveryIdentities.isEmpty
        }
        var list: EmbyConvertJobList?
        if needsList {
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
        }
        let now = Date().timeIntervalSince1970
        let claimed = EmbyConvertRecoveryPolicy.claimedJobIDs(
            liveJobIDs: otherJobIDs, liveRecoveryIdentities: otherRecoveryIdentities,
            jobs: list?.items ?? [], nowEpochSeconds: now)
        if !otherRecoveryIdentities.isEmpty, list?.isComplete != true {
            return .failed // Cannot prove another row's recovery does not own the job.
        }

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

    private func executePlexOptimizeCleanup(
        _ intent: DurableDownloadCleanupIntent,
        queueTitle: String,
        live: BackendSession
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        var excluded: Set<DownloadAttemptKey> = [intent.attemptKey]
        if case .abandonment(let origin) = intent.provenance { excluded.insert(origin) }
        let claimedTitles = Set(claimingRecords(for: intent).compactMap {
            $0.metadata?.optimizeQueueTitle
        }).union(serverPrepAttempts.protectedQueueTitles(excluding: excluded))
        guard !claimedTitles.contains(queueTitle) else { return .waiting }

        let identity = appModel.identity
        guard let bgKey = await bgKeyForPolling(
            server: live.baseURL, token: live.token, identity: identity) else { return .failed }
        let trimmed = bgKey.hasPrefix("/") ? String(bgKey.dropFirst()) : bgKey
        let listRequest = PlexRequest(
            url: live.baseURL.appendingPathComponent(trimmed), method: "GET", queryItems: [],
            headers: PlexHeaders.standard(identity: identity, token: live.token))
        guard let queue = try? await appModel.client.send(
            listRequest, as: BackgroundProcessingItems.self) else { return .failed }

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
            switch CleanupIntentRetryPolicy.plexRetention(
                recordedAtEpochSeconds: intent.recordedAtEpochSeconds,
                nowEpochSeconds: Date().timeIntervalSince1970) {
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
