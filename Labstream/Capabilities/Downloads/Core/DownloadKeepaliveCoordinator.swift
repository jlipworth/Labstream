import Foundation
import PMSKit

/// One exact-attempt lifecycle. Backend policy supplies candidate eligibility and request bodies;
/// ownership, transfer grace, auth quarantine and generation removal are common.
@MainActor
final class DownloadKeepaliveCoordinator {
    private struct Key: Hashable {
        let backend: DownloadBackendKind
        let attempt: DownloadAttemptKey
    }
    private struct TaskHandle {
        let generation: UUID
        let task: Task<Void, Never>
        let playSessionID: String?
        init(generation: UUID, task: Task<Void, Never>, playSessionID: String? = nil) {
            self.generation = generation; self.task = task; self.playSessionID = playSessionID
        }
    }
    private let appModel: AppModel
    private let store: DownloadStore
    private let isTrackingTransfer: @MainActor (DownloadAttemptKey) -> Bool
    private var tasks: [Key: TaskHandle] = [:]
    private var authQuarantine: [DownloadBackendKind: [String: String]] = [:]

    init(appModel: AppModel, store: DownloadStore,
         isTrackingTransfer: @escaping @MainActor (DownloadAttemptKey) -> Bool) {
        self.appModel = appModel
        self.store = store
        self.isTrackingTransfer = isTrackingTransfer
    }

    func reconcile(records: [DownloadRecord]) {
        for backend in [DownloadBackendKind.jellyfin, .emby] {
            guard let session = appModel.backendSession(for: backend), session.userID != nil else { continue }
            let authGeneration = Self.keepaliveAuthGeneration(session)
            for record in records {
                guard let attemptID = record.attemptID, let metadata = record.metadata,
                      session.matchesPersistedServer(metadata) else { continue }
                let key = Key(backend: backend, attempt: .init(ratingKey: record.ratingKey, attemptID: attemptID))
                switch DownloadKeepaliveLifecyclePolicy.authQuarantineAction(
                    quarantinedGeneration: authQuarantine[backend]?[record.ratingKey],
                    currentGeneration: authGeneration) {
                case .suppress: continue
                case .clear: authQuarantine[backend]?.removeValue(forKey: record.ratingKey)
                case .none: break
                }
                if let handle = tasks[key], handle.playSessionID != metadata.playSessionID {
                    tasks.removeValue(forKey: key)?.task.cancel()
                }
                guard tasks[key] == nil, candidate(record, backend: backend),
                      DownloadKeepaliveTransferGate.shouldStart(isTrackingTransfer: isTrackingTransfer(key.attempt)) else { continue }
                start(key)
            }
        }
    }

    func cancel(_ attemptKey: DownloadAttemptKey) {
        for backend in [DownloadBackendKind.jellyfin, .emby] {
            tasks.removeValue(forKey: Key(backend: backend, attempt: attemptKey))?.task.cancel()
        }
    }

    func clearAuthQuarantine(forRatingKey ratingKey: String) {
        for backend in [DownloadBackendKind.jellyfin, .emby] {
            authQuarantine[backend]?.removeValue(forKey: ratingKey)
        }
    }

    func activeCount(for backend: DownloadBackendKind) -> Int {
        tasks.keys.filter { $0.backend == backend }.count
    }

    private func candidate(_ record: DownloadRecord, backend: DownloadBackendKind) -> Bool {
        switch backend {
        case .jellyfin: JellyfinDownloadKeepalivePolicy.candidate(for: record, hasExistingTask: false) != nil
        case .emby: EmbyDownloadKeepalivePolicy.candidate(for: record, hasExistingTask: false) != nil
        case .plex: false
        }
    }

    private nonisolated static func keepaliveAuthGeneration(_ session: BackendSession) -> String {
        DiagnosticRedactor.stableIdentifier(
            for: "\(session.serverID ?? "")|\(session.baseURL.absoluteString)|\(session.userID ?? "")|\(session.token)")
    }

    /// Kept for the existing manager adapter. Reconciliation owns start eligibility, including
    /// the live-transfer gate, so pre-transfer publication cannot keep an idle encoder alive.
    func startJellyfinDownloadKeepalive(attemptKey: DownloadAttemptKey, itemId: String,
                                      mediaSourceId: String, playSessionId: String,
                                      userId: String, durationMs: Int?) {
        guard let record = store.record(for: attemptKey) else { return }
        reconcile(records: [record])
    }

    private func start(_ key: Key) {
        let generation = UUID()
        let playSessionID = store.record(for: key.attempt)?.metadata?.playSessionID
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.removeTaskIfCurrent(for: key.attempt, backend: key.backend,
                                            completingGeneration: generation) }
            var sentPlaying = false
            var previous: JellyfinKeepaliveTickOutcome?
            var transferGate = DownloadKeepaliveTransferGate()
            while !Task.isCancelled {
                guard !self.store.isDeletionPending(for: key.attempt),
                      let record = self.store.record(for: key.attempt),
                      self.candidate(record, backend: key.backend),
                      record.metadata?.playSessionID == playSessionID else { return }
                switch transferGate.evaluate(isTrackingTransfer: self.isTrackingTransfer(key.attempt)) {
                case .stop:
                    self.diagnostic("degraded", key, reason: "no_tracked_transfer")
                    return
                case .skip:
                    do { try await Task.sleep(for: .seconds(JellyfinDownloadKeepalivePolicy.intervalSeconds)) }
                    catch { return }
                    continue
                case .send: break
                }
                guard let liveSession = self.appModel.backendSession(for: key.backend),
                      let userID = liveSession.userID,
                      let metadata = record.metadata,
                      liveSession.matchesPersistedServer(metadata) else {
                    self.diagnostic("degraded", key, reason: "session_mismatch_or_unavailable")
                    return
                }
                var statuses: [Int?] = []
                do {
                    let requests = try self.requests(for: record, backend: key.backend,
                                                     session: liveSession, userID: userID,
                                                     sentPlaying: sentPlaying)
                    for (index, request) in requests.enumerated() {
                        // A request may suspend while the attempt or owning login is replaced.
                        guard !Task.isCancelled, self.tasks[key]?.generation == generation,
                              !self.store.isDeletionPending(for: key.attempt),
                              let current = self.store.record(for: key.attempt),
                              self.candidate(current, backend: key.backend),
                              current.metadata?.playSessionID == playSessionID,
                              self.appModel.backendSession(for: key.backend) == liveSession else { return }
                        let status = await Self.controlPlaneRequestStatus(request)
                        guard !Task.isCancelled, self.tasks[key]?.generation == generation,
                              self.appModel.backendSession(for: key.backend) == liveSession,
                              self.store.ownsAttempt(key.attempt) else { return }
                        statuses.append(status)
                        if key.backend == .jellyfin, !sentPlaying, index == 0,
                           let status, (200..<300).contains(status) { sentPlaying = true }
                        if status == 401 || status == 403 { break }
                    }
                } catch {
                    AppDiagnostics.record(.downloads, "downloads.\(key.backend.rawValue)_keepalive_failed", fields: [
                        "download_id": .identifier(key.attempt.ratingKey), "error": .error(error)])
                }
                let outcome = JellyfinDownloadKeepalivePolicy.tickOutcome(statuses: statuses)
                switch JellyfinDownloadKeepalivePolicy.healthAction(previous: previous, outcome: outcome) {
                case .none: break
                case .emitDegraded(let reason): self.diagnostic("degraded", key, reason: reason)
                case .emitRecovered: self.diagnostic("recovered", key)
                case .stopAuthDead(let statusCode):
                    self.authQuarantine[key.backend, default: [:]][key.attempt.ratingKey] =
                        Self.keepaliveAuthGeneration(liveSession)
                    AppDiagnostics.record(.downloads, "downloads.\(key.backend.rawValue)_keepalive_degraded", fields: [
                        "download_id": .identifier(key.attempt.ratingKey), "reason": .label("auth_dead"),
                        "status_code": .int(statusCode), "action": .label("stopped")])
                    return
                }
                previous = outcome
                do { try await Task.sleep(for: .seconds(JellyfinDownloadKeepalivePolicy.intervalSeconds)) }
                catch { return }
            }
        }
        tasks[key] = TaskHandle(generation: generation, task: task, playSessionID: playSessionID)
        diagnostic("start", key)
    }

    private func requests(for record: DownloadRecord, backend: DownloadBackendKind,
                          session: BackendSession, userID: String, sentPlaying: Bool) throws -> [URLRequest] {
        switch backend {
        case .emby:
            guard let candidate = EmbyDownloadKeepalivePolicy.candidate(for: record, hasExistingTask: false) else { return [] }
            // Emby is Ping-only. Jellyfin retains D3's fixed-zero interim pending live A/B evidence.
            return [try EmbyPlayback.pingRequest(server: session.baseURL, token: session.token,
                identity: appModel.identity.emby, userId: userID, playSessionId: candidate.playSessionID)]
        case .jellyfin:
            guard let candidate = JellyfinDownloadKeepalivePolicy.candidate(for: record, hasExistingTask: false) else { return [] }
            let identity = appModel.identity.jellyfin
            var requests: [URLRequest] = []
            if !sentPlaying {
                requests.append(try JellyfinPlayback.playingRequest(server: session.baseURL, token: session.token,
                    identity: identity, userId: userID, itemId: candidate.itemID,
                    mediaSourceId: candidate.mediaSourceID, playSessionId: candidate.playSessionID,
                    playMethod: .transcode, positionTicks: JellyfinDownloadKeepalivePolicy.reportedPositionTicks))
            }
            requests.append(try JellyfinPlayback.progressRequest(server: session.baseURL, token: session.token,
                identity: identity, userId: userID, itemId: candidate.itemID,
                mediaSourceId: candidate.mediaSourceID, playSessionId: candidate.playSessionID,
                playMethod: .transcode, positionTicks: JellyfinDownloadKeepalivePolicy.reportedPositionTicks, isPaused: false))
            requests.append(try JellyfinPlayback.pingRequest(server: session.baseURL, token: session.token,
                identity: identity, playSessionId: candidate.playSessionID))
            return requests
        case .plex: return []
        }
    }

    private func diagnostic(_ event: String, _ key: Key, reason: String? = nil) {
        var fields: [String: DiagnosticFieldValue] = ["download_id": .identifier(key.attempt.ratingKey)]
        if let reason { fields["reason"] = .label(reason) }
        AppDiagnostics.record(.downloads, "downloads.\(key.backend.rawValue)_keepalive_\(event)", fields: fields)
    }

    private func removeTaskIfCurrent(for key: DownloadAttemptKey, backend: DownloadBackendKind,
                                     completingGeneration: UUID) {
        let slot = Key(backend: backend, attempt: key)
        guard DownloadKeepaliveLifecyclePolicy.shouldRemoveTask(
            completingGeneration: completingGeneration, currentGeneration: tasks[slot]?.generation) else { return }
        tasks.removeValue(forKey: slot)
    }

    private nonisolated static func controlPlaneRequestStatus(_ request: URLRequest) async -> Int? {
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    #if DEBUG
    @discardableResult
    func registerTaskForTesting(_ task: Task<Void, Never>, for key: DownloadAttemptKey,
                                backend: DownloadBackendKind) -> UUID? {
        guard backend != .plex else { return nil }
        let slot = Key(backend: backend, attempt: key)
        let generation = UUID()
        tasks.removeValue(forKey: slot)?.task.cancel()
        tasks[slot] = TaskHandle(generation: generation, task: task)
        return generation
    }
    func removeTaskForTesting(for key: DownloadAttemptKey, backend: DownloadBackendKind,
                              completingGeneration: UUID) {
        removeTaskIfCurrent(for: key, backend: backend, completingGeneration: completingGeneration)
    }
    #endif
}
