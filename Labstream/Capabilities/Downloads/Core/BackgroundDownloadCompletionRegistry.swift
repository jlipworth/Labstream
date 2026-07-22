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
    init() {}

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
        for token in handlers.pendingTokens(for: BackgroundDownloadSession.identifier) {
            session.noteBackgroundCompletionHandlerStored(
                identifier: BackgroundDownloadSession.identifier,
                token: token
            )
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
        sessions[identifier]?.noteBackgroundCompletionHandlerStored(
            identifier: identifier,
            token: token
        )
        // Active sessions need their lazy URLSession bound so the OS can finish delivering events.
        // This is a safe no-op while startup admission is dormant; never reattach autonomously.
        sessions[identifier]?.ensureSessionReady()
        return token
    }

    func hasPendingHandler(identifier: String) -> Bool {
        handlers.hasHandlers(for: identifier)
    }

    /// Invoke and clear only the completion handlers claimed by one finish-events transition.
    /// A newer handler using the same stable identifier has a different token and remains queued.
    func fireCompletions(in batch: BackgroundDownloadCompletionReleaseBatch) {
        let pendingHandlers = handlers.drain(batch: batch)
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
