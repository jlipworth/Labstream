import Foundation

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

    /// identifier -> system completion handler awaiting `didFinishEvents`.
    private var handlers: [String: () -> Void] = [:]
    /// Live sessions keyed by their background-session identifier.
    private var sessions: [String: BackgroundDownloadSession] = [:]

    private init() {}

    /// Record a live session so the delegate's identifier resolves to it.
    func register(_ session: BackgroundDownloadSession) {
        sessions[BackgroundDownloadSession.identifier] = session
        AppDiagnostics.record(.downloads, "downloads.background_session_registered", fields: [
            "session": .label(BackgroundDownloadSession.identifier),
            "has_pending_handler": .bool(handlers[BackgroundDownloadSession.identifier] != nil),
        ])
        if handlers[BackgroundDownloadSession.identifier] != nil {
            session.noteBackgroundCompletionHandlerStored(identifier: BackgroundDownloadSession.identifier)
            session.ensureSessionReady()
            session.reattach()
        }
    }

    /// Store the system completion handler and make sure the matching session exists
    /// so its delegate will eventually fire `urlSessionDidFinishEvents`.
    func store(identifier: String, completion: @escaping () -> Void) {
        handlers[identifier] = completion
        AppDiagnostics.record(.downloads, "downloads.background_completion_stored", fields: [
            "session": .label(identifier),
            "has_session": .bool(sessions[identifier] != nil),
        ])
        sessions[identifier]?.noteBackgroundCompletionHandlerStored(identifier: identifier)
        sessions[identifier]?.ensureSessionReady()
        sessions[identifier]?.reattach()
    }

    /// Invoke and clear the stored completion handler for `identifier`.
    func fireCompletion(for identifier: String) {
        guard let handler = handlers.removeValue(forKey: identifier) else { return }
        AppDiagnostics.record(.downloads, "downloads.background_completion_fired", fields: [
            "session": .label(identifier),
        ])
        handler()
    }
}

