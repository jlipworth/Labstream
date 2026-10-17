import Foundation
import PMSKit

/// Bridges the app delegate's `handleEventsForBackgroundURLSession` callback to the
/// `BackgroundDownloadSession` that owns the matching background `URLSession`.
///
/// When visionOS relaunches the app in the background to finish a transfer it calls
/// `application(_:handleEventsForBackgroundURLSessionWithIdentifier:completionHandler:)`.
/// The app must (1) recreate the background session (done lazily by reattaching the
/// `DownloadManager`) and (2) keep the completion handler until the session reports
/// `urlSessionDidFinishEvents`, then call it. The session object and the app delegate
/// are created independently, so this small main-actor registry connects them by
/// session identifier.
@MainActor
final class BackgroundDownloadCompletionRegistry {
    static let shared = BackgroundDownloadCompletionRegistry()

    /// Every system completion handler awaiting `didFinishEvents`, grouped by identifier.
    /// Same-identifier callbacks present at one finish transition form an exact token batch;
    /// callbacks supplied after that transition belong to the next release cycle.
    private var handlers = BackgroundDownloadCompletionHandlerStore()
    /// Live sessions keyed by their background-session identifier.
    private var sessions: [String: BackgroundDownloadSession] = [:]

    /// Production uses `shared`; internal construction keeps handler-cardinality tests isolated.
    private let clock: DownloadWakeClockHooks
    private let budget: DownloadWakeBudget
    private var receipts: [BackgroundDownloadCompletionHandlerToken: DownloadWakeHandlerReceipt] = [:]
    private var startupStates: [String: DownloadStartupWakeState] = [:]

    init(clockHooks: DownloadWakeClockHooks? = nil, budget: DownloadWakeBudget = .application) {
        clock = clockHooks ?? .live
        self.budget = budget
    }

    /// Record a live session so the delegate's identifier resolves to it. Registration is
    /// deliberately activation-neutral: during schema migration the session is dormant, and
    /// constructing/reattaching its URLSession here would admit callbacks before legacy tasks are
    /// cancelled. The manager alone owns startup activation and the initial reattach.
    func register(_ session: BackgroundDownloadSession) {
        sessions[BackgroundDownloadSession.identifier] = session
        AppDiagnostics.record(.downloads, "downloads.background_session_registered", fields: [
            "session": .label(BackgroundDownloadSession.identifier),
            "has_pending_handler": .bool(handlers.hasHandlers(
                for: BackgroundDownloadSession.identifier
            )),
        ])
        if let state = startupStates[BackgroundDownloadSession.identifier] {
            session.noteStartupWakeState(state)
        }
        for token in handlers.pendingTokens(for: BackgroundDownloadSession.identifier) {
            if let receipt = receipts[token] { session.noteBackgroundCompletionHandlerStored(receipt) }
        }
    }

    /// Store the system completion handler and make sure the matching session exists
    /// so its delegate will eventually fire `urlSessionDidFinishEvents`.
    @discardableResult
    func store(
        identifier: String,
        completion: @escaping () -> Void
    ) -> BackgroundDownloadCompletionHandlerToken {
        let token = handlers.append(identifier: identifier, handler: completion)
        AppDiagnostics.record(.downloads, "downloads.background_completion_stored", fields: [
            "session": .label(identifier),
            "has_session": .bool(sessions[identifier] != nil),
            "handler_count": .int(handlers.count(for: identifier)),
        ])
        let now = clock.now()
        let deadline = receipts.values.filter { $0.identifier == identifier }
            .map(\.absoluteDeadline).min()
            ?? DownloadWakeBudget.deadline(from: now, after: budget.wholeWake)
        let receipt = DownloadWakeHandlerReceipt(identifier: identifier, token: token,
                                                receivedAt: now, absoluteDeadline: deadline)
        receipts[token] = receipt
        if case .blockedBeforeTransport = startupStates[identifier],
           sessions[identifier]?.canReleaseStartupWithoutTransport != false {
            if let session = sessions[identifier] {
                session.noteBackgroundCompletionHandlerStored(receipt)
            } else {
                clock.terminalAcknowledged(.init(generation: .init(id: UUID()), outcome: .startupBlocked,
                    batches: [.init(identifier: identifier, tokens: [token])]))
            }
            fireCompletions(in: .init(identifier: identifier, tokens: [token]))
        } else if let session = sessions[identifier] {
            session.noteBackgroundCompletionHandlerStored(receipt)
            session.ensureSessionReady()
        }
        // Registration may never happen. Preserve the registry receipt rather than starting a
        // fresh budget when a session eventually appears. The session owns supervision thereafter.
        clock.register(.init(id: UUID(), deadline: deadline, kind: .absoluteDeadline)) { [weak self] in
            Task { @MainActor in
                guard let self, self.sessions[identifier] == nil, self.receipts[token] != nil else { return }
                let tokens = self.receipts.values.filter {
                    $0.identifier == identifier && $0.absoluteDeadline <= deadline
                }.map(\.token)
                let batch = BackgroundDownloadCompletionReleaseBatch(identifier: identifier, tokens: tokens)
                self.clock.terminalAcknowledged(.init(generation: .init(id: UUID()), outcome: .timedOut,
                                                       batches: [batch]))
                self.fireCompletions(in: batch)
            }
        }
        return token
    }

    /// Terminal pre-construction state survives both late registration and late OS delivery.
    func noteStartupWakeState(_ state: DownloadStartupWakeState, identifier: String) {
        guard state.supersedes(startupStates[identifier]) else { return }
        startupStates[identifier] = state
        sessions[identifier]?.noteStartupWakeState(state)
        if case .blockedBeforeTransport = state,
           sessions[identifier]?.canReleaseStartupWithoutTransport != false {
            let tokens = handlers.pendingTokens(for: identifier)
            if sessions[identifier] == nil, !tokens.isEmpty {
                clock.terminalAcknowledged(.init(generation: .init(id: UUID()), outcome: .startupBlocked,
                    batches: [.init(identifier: identifier, tokens: tokens)]))
            }
            fireCompletions(in: .init(identifier: identifier, tokens: tokens))
        }
    }

    func hasPendingHandler(identifier: String) -> Bool {
        handlers.hasHandlers(for: identifier)
    }

    /// Invoke and clear only the completion handlers claimed by one finish-events transition.
    /// A newer handler using the same stable identifier has a different token and remains queued.
    func fireCompletions(in batch: BackgroundDownloadCompletionReleaseBatch) {
        let pendingHandlers = handlers.drain(batch: batch)
        for token in batch.tokens { receipts.removeValue(forKey: token) }
        guard !pendingHandlers.isEmpty else { return }
        AppDiagnostics.record(.downloads, "downloads.background_completion_fired", fields: [
            "session": .label(batch.identifier),
            "handler_count": .int(pendingHandlers.count),
        ])
        for handler in pendingHandlers {
            handler()
        }
    }
}
