import SwiftUI

/// App delegate whose ONLY job is to receive background `URLSession` relaunch events.
///
/// When visionOS relaunches the app in the background to finish an offline download,
/// it calls `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
/// We must hold the system-supplied completion handler until the matching background
/// session reports that it has delivered all its queued events
/// (`urlSessionDidFinishEvents`), then call the handler so the OS can snapshot a
/// fresh UI and let the app suspend again. Calling it too early (or never) leaves the
/// transfer in a bad state and can get background execution throttled.
///
/// SwiftUI has no scene hook for this callback, so we bridge it through
/// `BackgroundDownloadCompletionRegistry`, which resolves the identifier to the live
/// `BackgroundDownloadSession` owned by `DownloadManager` and recreates the session
/// (via `reattach()`) so its delegate fires `urlSessionDidFinishEvents`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // The completion handler must be invoked on the main thread once events drain.
        Task { @MainActor in
            BackgroundDownloadCompletionRegistry.shared.store(identifier: identifier,
                                                              completion: completionHandler)
        }
    }
}
