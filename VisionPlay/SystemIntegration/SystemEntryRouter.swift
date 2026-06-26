import Foundation
import Observation
import PMSKit

/// Bridges out-of-app entry points — App Intents (Siri/Shortcuts) and CoreSpotlight
/// results — plus Cinema exit routing — into the main browse UI (issue #24).
///
/// "Open item X" means: land on the Home tab and push X onto its NavigationStack. Intents
/// run in-process but outside the SwiftUI environment, and Cinema exit runs from an
/// `ImmersiveSpace`, so callers use this process-lifetime singleton instead of reaching
/// directly into view state. `ContentView` registers the app-owned `AppModel`/`AuthManager`
/// instances; `RootView` observes `pending` and performs the actual navigation.
@MainActor
@Observable
final class SystemEntryRouter {
    static let shared = SystemEntryRouter()

    /// One navigation request from an intent or a Spotlight result.
    ///
    /// `id` is a nonce so two consecutive requests for the SAME item still trip
    /// `.onChange` in RootView (Equatable on the payload alone would coalesce them).
    struct Route: Equatable, Identifiable {
        enum Target: Equatable {
            /// A fully-formed item (an intent that already holds the metadata).
            case item(MediaItem)
            /// A backend/server/rating-key route (a Spotlight hit / entity id); the
            /// consumer fetches the metadata before navigating. Legacy bare ids parse as Plex.
            case routeKey(BackendScopedMediaID)
        }
        let id = UUID()
        let target: Target
        /// When true the destination should start playback, not just show detail.
        let autoPlay: Bool
        /// Which browse tab to land on. `nil` keeps the legacy behavior (Home), used by
        /// intents/Spotlight and the system-entry Cinema-exit fallback; Cinema exit from an
        /// online browse tab sets this so it returns to the originating tab (#87).
        let originTab: CinemaTab?

        init(target: Target, autoPlay: Bool, originTab: CinemaTab? = nil) {
            self.target = target
            self.autoPlay = autoPlay
            self.originTab = originTab
        }
    }

    /// The route waiting to be performed. RootView consumes it (resets to `nil`)
    /// once handled; it survives here untouched if set before RootView mounts
    /// (cold launch from an intent while the restore splash is still up).
    var pending: Route?

    /// One offline-return request from Cinema exit (#87): land on the Offline tab and focus
    /// the identified download with NO server fetch. Kept separate from `pending` because the
    /// online route's consumer is hard-wired to Home + online metadata, which is exactly what an
    /// offline origin must avoid. RootView consumes it (resets to `nil`) once handled.
    struct OfflineReturn: Equatable, Identifiable {
        let id = UUID()
        let ratingKey: String
    }
    var offlinePending: OfflineReturn?

    // MARK: - Live app objects

    /// Registered by ContentView with the app-owned instances. Weak: the router is
    /// a process-lifetime singleton and must never extend object lifetimes —
    /// AppModel/AuthManager are owned by `VisionPlay.App`.
    private(set) weak var appModel: AppModel?
    private(set) weak var authManager: AuthManager?

    func register(appModel: AppModel, authManager: AuthManager) {
        self.appModel = appModel
        self.authManager = authManager
    }

    /// Everything an intent/entity query needs to issue browse requests, or `nil`
    /// when there's no signed-in, resolved server. Tokens stay inside — callers
    /// pass this straight to the `BrowseAPI` builders and never persist any of it.
    struct BrowseContext {
        let server: URL
        let token: String
        let identity: ClientIdentity
        let client: PlexClient
    }

    var browseContext: BrowseContext? {
        guard let appModel,
              let server = appModel.serverBaseURL,
              let token = appModel.serverToken else { return nil }
        return BrowseContext(server: server, token: token,
                             identity: appModel.identity, client: appModel.client)
    }

    // MARK: - Requests

    func open(ratingKey: String, autoPlay: Bool) {
        open(routeKey: BackendScopedMediaID(backend: .plex, ratingKey: ratingKey), autoPlay: autoPlay)
    }

    func open(routeKey: BackendScopedMediaID, autoPlay: Bool) {
        pending = Route(target: .routeKey(routeKey), autoPlay: autoPlay)
    }

    func open(item: MediaItem, autoPlay: Bool) {
        pending = Route(target: .item(item), autoPlay: autoPlay)
    }

    /// Cinema exit from an online browse tab (#87): return to `tab`'s detail for `item` instead of
    /// always landing on Home.
    func open(item: MediaItem, autoPlay: Bool, onTab tab: CinemaTab) {
        pending = Route(target: .item(item), autoPlay: autoPlay, originTab: tab)
    }

    /// Cinema exit from an offline download (#87): return to the Offline tab and focus the
    /// download. No server fetch, no Home tab.
    func openOffline(ratingKey: String) {
        offlinePending = OfflineReturn(ratingKey: ratingKey)
    }

    // MARK: - AutoPlay handshake

    /// "Play X" intents need DetailView to start playback once it's on screen.
    /// RootView arms this right before pushing the item; DetailView consumes it
    /// from its `.task`. The pure one-shot/time-box behavior lives in PMSKit so it
    /// stays covered by tests instead of being hidden in SwiftUI side effects.
    private var autoPlayGate = PendingAutoPlayGate()

    func requestAutoPlay(forRatingKey ratingKey: String) {
        autoPlayGate.arm(ratingKey: ratingKey)
    }

    func consumeAutoPlay(for ratingKey: String) -> Bool {
        autoPlayGate.consume(ratingKey: ratingKey)
    }

    // MARK: - Session readiness (for intents)

    /// One-shot guard so the router only ever kicks a single restore of its own.
    private var didKickRestore = false

    /// Wait until the app has a signed-in, resolved server — the precondition for
    /// every intent/entity query. Returns `false` (never throws) when it can't get
    /// there, so callers surface their own user-facing error.
    ///
    /// Launch sequencing: ContentView's `.task` normally runs `restoreSession()`
    /// itself, so we first just wait for that to land. If it hasn't after a short
    /// grace (e.g. the system launched us in the background for Shortcuts parameter
    /// resolution, where the scene may not be connected), kick one restore directly.
    func ensureBrowseReady(timeout: Duration = .seconds(12)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let graceUntil = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let appModel, appModel.isBrowseReady { return true }
            if clock.now >= graceUntil, !didKickRestore, let authManager {
                didKickRestore = true
                _ = await authManager.restoreSession()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return appModel?.isBrowseReady ?? false
    }
}
