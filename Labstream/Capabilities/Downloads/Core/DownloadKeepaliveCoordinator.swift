import Foundation
import PMSKit

/// Owns the process-lifetime control-plane keepalives used by Jellyfin transcodes and Emby
/// compatible remuxes. Task slots are exact-attempt keyed; rating keys are used only for the
/// credential-generation quarantine that prevents an auth-dead refresh loop.
@MainActor
final class DownloadKeepaliveCoordinator {
    private struct TaskHandle {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let appModel: AppModel
    private let store: DownloadStore
    private var jellyfinTasks: [DownloadAttemptKey: TaskHandle] = [:]
    private var embyTasks: [DownloadAttemptKey: TaskHandle] = [:]
    private var jellyfinAuthQuarantine: [String: String] = [:]
    private var embyAuthQuarantine: [String: String] = [:]

    init(appModel: AppModel, store: DownloadStore) {
        self.appModel = appModel
        self.store = store
    }

    func reconcile(records: [DownloadRecord]) {
        ensureJellyfinDownloadKeepalives(for: records)
        ensureEmbyDownloadKeepalives(for: records)
    }

    func cancel(_ attemptKey: DownloadAttemptKey) {
        jellyfinTasks.removeValue(forKey: attemptKey)?.task.cancel()
        embyTasks.removeValue(forKey: attemptKey)?.task.cancel()
    }

    func clearAuthQuarantine(forRatingKey ratingKey: String) {
        jellyfinAuthQuarantine.removeValue(forKey: ratingKey)
        embyAuthQuarantine.removeValue(forKey: ratingKey)
    }

    func activeCount(for backend: DownloadBackendKind) -> Int {
        switch backend {
        case .jellyfin: jellyfinTasks.count
        case .emby: embyTasks.count
        case .plex: 0
        }
    }

    private func attemptKey(for record: DownloadRecord) -> DownloadAttemptKey? {
        record.attemptID.map { DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0) }
    }

    private func recordDownloadDiagnostic(
        _ name: String,
        fields: [String: DiagnosticFieldValue] = [:]
    ) {
        AppDiagnostics.record(.downloads, name, fields: fields)
    }

    private func ensureJellyfinDownloadKeepalives(for records: [DownloadRecord]) {
        // Session and auth generation are loop-invariant: resolve once, not per record per refresh.
        guard let session = appModel.backendSession(for: .jellyfin),
              let userId = session.userID else { return }
        let authGeneration = Self.keepaliveAuthGeneration(session)
        for record in records {
            guard let metadata = record.metadata,
                  let key = attemptKey(for: record),
                  session.matchesPersistedServer(metadata)
            else { continue }
            switch DownloadKeepaliveLifecyclePolicy.authQuarantineAction(
                quarantinedGeneration: jellyfinAuthQuarantine[record.ratingKey],
                currentGeneration: authGeneration) {
            case .suppress:
                continue
            case .clear:
                jellyfinAuthQuarantine.removeValue(forKey: record.ratingKey)
            case .none:
                break
            }
            guard let candidate = JellyfinDownloadKeepalivePolicy.candidate(
                for: record,
                hasExistingTask: jellyfinTasks[key] != nil)
            else { continue }

            startJellyfinDownloadKeepalive(
                attemptKey: key,
                itemId: candidate.itemID,
                mediaSourceId: candidate.mediaSourceID,
                playSessionId: candidate.playSessionID,
                userId: userId,
                durationMs: candidate.durationMs)
        }
    }

    private func ensureEmbyDownloadKeepalives(for records: [DownloadRecord]) {
        // Session and auth generation are loop-invariant: resolve once, not per record per refresh.
        guard let session = appModel.backendSession(for: .emby),
              let userId = session.userID else { return }
        let authGeneration = Self.keepaliveAuthGeneration(session)
        for record in records {
            guard let metadata = record.metadata,
                  let key = attemptKey(for: record),
                  session.matchesPersistedServer(metadata),
                  EmbyDownloadKeepalivePolicy.matchesPersistedUser(
                    metadata.backendUserID, currentUserID: userId)
            else { continue }
            switch DownloadKeepaliveLifecyclePolicy.authQuarantineAction(
                quarantinedGeneration: embyAuthQuarantine[record.ratingKey],
                currentGeneration: authGeneration) {
            case .suppress:
                continue
            case .clear:
                embyAuthQuarantine.removeValue(forKey: record.ratingKey)
            case .none:
                break
            }
            guard let candidate = EmbyDownloadKeepalivePolicy.candidate(
                for: record,
                hasExistingTask: embyTasks[key] != nil)
            else { continue }

            startEmbyDownloadKeepalive(
                attemptKey: key,
                playSessionId: candidate.playSessionID,
                userId: userId)
        }
    }

    private nonisolated static func keepaliveAuthGeneration(_ session: BackendSession) -> String {
        return DiagnosticRedactor.stableIdentifier(
            for: "\(session.serverID ?? "")|\(session.baseURL.absoluteString)|\(session.userID ?? "")|\(session.token)")
    }

    private func startEmbyDownloadKeepalive(
        attemptKey: DownloadAttemptKey,
        playSessionId: String,
        userId: String
    ) {
        let ratingKey = attemptKey.ratingKey
        embyTasks.removeValue(forKey: attemptKey)?.task.cancel()
        let identity = appModel.identity.emby
        let enqueueUserId = userId
        let generation = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.removeTaskIfCurrent(
                        for: attemptKey,
                        backend: .emby,
                        completingGeneration: generation)
                }
            }
            var lastTickOutcome: JellyfinKeepaliveTickOutcome?
            while !Task.isCancelled {
                guard !self.store.isDeletionPending(for: attemptKey),
                      let record = self.store.record(for: attemptKey),
                      EmbyDownloadKeepalivePolicy.candidate(for: record, hasExistingTask: false) != nil
                else { return }
                // Re-resolve every tick so token rotation, sign-out, or server replacement stops
                // the old control plane rather than silently pinging with stale credentials.
                guard let liveSession = self.appModel.backendSession(for: .emby),
                      record.metadata.map(liveSession.matchesPersistedServer) != false,
                      EmbyDownloadKeepalivePolicy.matchesPersistedUser(
                        record.metadata?.backendUserID, currentUserID: liveSession.userID) else {
                    self.recordDownloadDiagnostic("downloads.emby_keepalive_degraded", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("emby_session_mismatch_or_unavailable"),
                        "action": .label("stopped"),
                    ])
                    return
                }
                let server = liveSession.baseURL
                let token = liveSession.token
                let liveUserId = liveSession.userID ?? enqueueUserId
                var statuses: [Int?] = []
                do {
                    // Live evidence: Ping alone keeps Emby's compatible-remux encoder alive past
                    // its ~60s idle deadline. Do not send Playing/Progress here: those mutate the
                    // user's resume position/watch history for what is only a file download.
                    let ping = try EmbyPlayback.pingRequest(
                        server: server, token: token, identity: identity,
                        userId: liveUserId, playSessionId: playSessionId)
                    guard !self.store.isDeletionPending(for: attemptKey) else { return }
                    statuses.append(await Self.controlPlaneRequestStatus(ping))
                } catch {
                    self.recordDownloadDiagnostic("downloads.emby_keepalive_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "error": .error(error),
                    ])
                }
                let outcome = JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: statuses)
                switch JellyfinDownloadKeepalivePolicy.healthAction(previous: lastTickOutcome,
                                                                    outcome: outcome) {
                case .none:
                    break
                case .emitDegraded(let reason):
                    self.recordDownloadDiagnostic("downloads.emby_keepalive_degraded", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label(reason),
                    ])
                case .emitRecovered:
                    self.recordDownloadDiagnostic("downloads.emby_keepalive_recovered", fields: [
                        "download_id": .identifier(ratingKey),
                    ])
                case .stopAuthDead(let statusCode):
                    self.embyAuthQuarantine[ratingKey] =
                        Self.keepaliveAuthGeneration(liveSession)
                    self.recordDownloadDiagnostic("downloads.emby_keepalive_degraded", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("auth_dead"),
                        "status_code": .int(statusCode),
                        "action": .label("stopped"),
                    ])
                    return
                }
                lastTickOutcome = outcome
                do {
                    try await Task.sleep(for: .seconds(EmbyDownloadKeepalivePolicy.intervalSeconds))
                } catch { return }
            }
        }
        embyTasks[attemptKey] = TaskHandle(generation: generation, task: task)
        recordDownloadDiagnostic("downloads.emby_keepalive_start", fields: [
            "download_id": .identifier(ratingKey),
        ])
    }

    func startJellyfinDownloadKeepalive(
        attemptKey: DownloadAttemptKey,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        userId: String,
        durationMs: Int?
    ) {
        let ratingKey = attemptKey.ratingKey
        jellyfinTasks.removeValue(forKey: attemptKey)?.task.cancel()
        let identity = appModel.identity.jellyfin
        let enqueueUserId = userId
        let generation = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                // Self-remove on ANY exit (auth-dead, session mismatch, natural). Leaving the
                // entry behind made `ensureJellyfinDownloadKeepalives` see hasExistingTask forever
                // and never restart the keepalive after re-login — the server then idle-killed the
                // transcode mid-download.
                Task { @MainActor [weak self] in
                    self?.removeTaskIfCurrent(
                        for: attemptKey,
                        backend: .jellyfin,
                        completingGeneration: generation)
                }
            }
            var sentPlaying = false
            // N2/F2c: report an advancing position, not a stationary one. Forward-only rows have
            // no progress fraction (no Content-Length), so `positionTicks(progress:)` pinned every
            // ping to 0 and the server saw a frozen session it could idle-kill mid-download — the
            // very truncation these keepalives exist to prevent. Derive position from received
            // bytes vs the transcode size estimate, falling back to elapsed wall clock, kept
            // monotonic across pings.
            let keepaliveStartedAt = Date()
            var lastReportedTicks = 0
            var lastTickOutcome: JellyfinKeepaliveTickOutcome?
            while !Task.isCancelled {
                guard !self.store.isDeletionPending(for: attemptKey),
                      let record = self.store.record(for: attemptKey),
                      record.status == .queued || record.status == .downloading else { return }
                // A-2 (audit lens 8): re-resolve the Jellyfin lane per tick — token rotation or a
                // re-login mid-download must not keep pinging with the enqueue-time snapshot (the
                // server sees silence and idle-kills the encoder with no diagnostic trail).
                guard let liveSession = self.appModel.backendSession(for: .jellyfin),
                      record.metadata.map(liveSession.matchesPersistedServer) != false else {
                    self.recordDownloadDiagnostic("downloads.jellyfin_keepalive_degraded", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("jellyfin_session_mismatch_or_unavailable"),
                        "action": .label("stopped"),
                    ])
                    return
                }
                let server = liveSession.baseURL
                let token = liveSession.token
                let liveUserId = liveSession.userID ?? enqueueUserId
                let progress = max(0, min(record.progress, 1))
                let positionTicks = JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
                    progress: progress,
                    bytes: record.bytes,
                    estimatedTotalBytes: DownloadPresetPolicy.estimatedTranscodeBytes(for: record),
                    elapsedSeconds: Date().timeIntervalSince(keepaliveStartedAt),
                    durationMs: durationMs,
                    lastReportedTicks: lastReportedTicks)
                lastReportedTicks = positionTicks
                var statuses: [Int?] = []
                do {
                    if !sentPlaying {
                        let playing = try JellyfinPlayback.playingRequest(
                            server: server,
                            token: token,
                            identity: identity,
                            userId: liveUserId,
                            itemId: itemId,
                            mediaSourceId: mediaSourceId,
                            playSessionId: playSessionId,
                            playMethod: .transcode,
                            positionTicks: positionTicks)
                        guard !self.store.isDeletionPending(for: attemptKey) else { return }
                        let status = await Self.controlPlaneRequestStatus(playing)
                        statuses.append(status)
                        // Only mark the session opened once the server actually accepted it, so a
                        // transient failure retries the open instead of orphaning the session.
                        if let status, (200..<300).contains(status) { sentPlaying = true }
                    }
                    let progressReq = try JellyfinPlayback.progressRequest(
                        server: server,
                        token: token,
                        identity: identity,
                        userId: liveUserId,
                        itemId: itemId,
                        mediaSourceId: mediaSourceId,
                        playSessionId: playSessionId,
                        playMethod: .transcode,
                        positionTicks: positionTicks,
                        isPaused: false)
                    guard !self.store.isDeletionPending(for: attemptKey) else { return }
                    statuses.append(await Self.controlPlaneRequestStatus(progressReq))
                    let ping = try JellyfinPlayback.pingRequest(server: server,
                                                                token: token,
                                                                identity: identity,
                                                                playSessionId: playSessionId)
                    guard !self.store.isDeletionPending(for: attemptKey) else { return }
                    statuses.append(await Self.controlPlaneRequestStatus(ping))
                } catch {
                    recordDownloadDiagnostic("downloads.jellyfin_keepalive_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "error": .error(error),
                    ])
                }
                let outcome = JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: statuses)
                switch JellyfinDownloadKeepalivePolicy.healthAction(previous: lastTickOutcome,
                                                                    outcome: outcome) {
                case .none:
                    break
                case .emitDegraded(let reason):
                    self.recordDownloadDiagnostic("downloads.jellyfin_keepalive_degraded", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label(reason),
                    ])
                case .emitRecovered:
                    self.recordDownloadDiagnostic("downloads.jellyfin_keepalive_recovered", fields: [
                        "download_id": .identifier(ratingKey),
                    ])
                case .stopAuthDead(let statusCode):
                    // Quarantine THIS credential generation so refreshRecords doesn't immediately
                    // recreate the task and hammer the server; a re-login mints a new generation
                    // and the ensure gate clears the sentinel and restarts the keepalive.
                    self.jellyfinAuthQuarantine[ratingKey] =
                        Self.keepaliveAuthGeneration(liveSession)
                    self.recordDownloadDiagnostic("downloads.jellyfin_keepalive_degraded", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("auth_dead"),
                        "status_code": .int(statusCode),
                        "action": .label("stopped"),
                    ])
                    return
                }
                lastTickOutcome = outcome
                do {
                    try await Task.sleep(for: .seconds(JellyfinDownloadKeepalivePolicy.intervalSeconds))
                } catch {
                    return
                }
            }
        }
        jellyfinTasks[attemptKey] = TaskHandle(generation: generation, task: task)
        recordDownloadDiagnostic("downloads.jellyfin_keepalive_start", fields: [
            "download_id": .identifier(ratingKey),
        ])
    }

    private func removeTaskIfCurrent(
        for key: DownloadAttemptKey,
        backend: DownloadBackendKind,
        completingGeneration: UUID
    ) {
        switch backend {
        case .jellyfin:
            guard DownloadKeepaliveLifecyclePolicy.shouldRemoveTask(
                completingGeneration: completingGeneration,
                currentGeneration: jellyfinTasks[key]?.generation) else { return }
            jellyfinTasks.removeValue(forKey: key)
        case .emby:
            guard EmbyDownloadKeepalivePolicy.shouldRemoveTask(
                completingGeneration: completingGeneration,
                currentGeneration: embyTasks[key]?.generation) else { return }
            embyTasks.removeValue(forKey: key)
        case .plex:
            break
        }
    }

    /// Send one control-plane request (keepalive/report ping) and surface its HTTP status
    /// (nil = transport failure). Control-plane traffic is deliberately EXEMPT from the
    /// Wi-Fi-only download policy — tiny bodies that keep the server encoder alive.
    private nonisolated static func controlPlaneRequestStatus(_ request: URLRequest) async -> Int? {
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }


    #if DEBUG
    @discardableResult
    func registerTaskForTesting(
        _ task: Task<Void, Never>,
        for key: DownloadAttemptKey,
        backend: DownloadBackendKind
    ) -> UUID? {
        let generation = UUID()
        let handle = TaskHandle(generation: generation, task: task)
        switch backend {
        case .jellyfin:
            jellyfinTasks.removeValue(forKey: key)?.task.cancel()
            jellyfinTasks[key] = handle
        case .emby:
            embyTasks.removeValue(forKey: key)?.task.cancel()
            embyTasks[key] = handle
        case .plex:
            return nil
        }
        return generation
    }

    func removeTaskForTesting(
        for key: DownloadAttemptKey,
        backend: DownloadBackendKind,
        completingGeneration: UUID
    ) {
        removeTaskIfCurrent(
            for: key,
            backend: backend,
            completingGeneration: completingGeneration)
    }
    #endif
}
