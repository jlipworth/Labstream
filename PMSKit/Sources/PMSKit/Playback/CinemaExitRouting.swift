import Foundation

/// Where playback was launched from when Cinema mode was entered.
///
/// Cinema exit used to always route to the Home tab's online detail page, which is wrong for any
/// non-Home origin and outright broken for an offline download (the Home tab needs a live server
/// session, and the online detail fetches metadata over the network — neither works offline).
/// Threading an origin from the launching surface through the Cinema session lets exit return to
/// the place playback actually started (issue #87).
///
/// This is a backend-agnostic descriptor: the browse tabs are modeled as `CinemaTab` rather than
/// the app's own tab enum so the routing decision stays a pure, unit-testable PMSKit function with
/// no dependency on the SwiftUI layer.
public enum CinemaOrigin: Equatable, Sendable {
    /// An out-of-app entry (App Intent / Spotlight) or any caller that wants the legacy behavior:
    /// land on Home and push the item's online detail. This is the safe default.
    case systemEntry
    /// An online browse origin on a specific tab — return to that tab's detail page, not Home.
    case onlineTab(CinemaTab)
    /// An offline download (Offline tab, or a "Play Offline" from detail). Exit must return to the
    /// Offline tab with no server fetch; `ratingKey` identifies the download to re-present.
    case offline(ratingKey: String)
}

/// The browse tabs Cinema can be launched from and returned to. Mirrors the app's tab strip but is
/// owned by PMSKit so `CinemaExitRouting` is testable without the app target.
public enum CinemaTab: String, Equatable, Sendable, CaseIterable {
    case home
    case libraries
    case search
}

/// The resolved destination for a Cinema exit — what the navigation layer should actually do.
public enum CinemaExitDestination: Equatable, Sendable {
    /// Route through the system-entry path: land on Home and push the item's online detail.
    /// Carries `autoPlay` for the "play next on exit" case.
    case systemEntryItem(autoPlay: Bool)
    /// Land on the given browse tab and push the item's online detail (carrying `autoPlay`).
    case onlineTabItem(tab: CinemaTab, autoPlay: Bool)
    /// Land on the Offline tab and re-present the identified download. Never fetches from a server,
    /// and never auto-advances to an online "next" item (there is no offline next to resolve here).
    case offlineDownload(ratingKey: String)
    /// Nothing to return to (no preserved item) — just foreground the main window.
    case none
}

/// Pure resolution of a Cinema exit: given where playback started and whether the exit is a
/// "play next episode" advance, decide where to land. Kept free of UIKit/SwiftUI so the branching
/// (especially the offline special-casing of Up Next) is covered by unit tests rather than hidden
/// in view side effects.
public enum CinemaExitRouting {
    /// - Parameters:
    ///   - origin: where Cinema was launched from.
    ///   - hasReturnItem: whether the session still holds an item to return to.
    ///   - autoPlay: the requested autoplay flag (true for an Up Next advance, false otherwise).
    ///   - advancingToNext: true when this exit is an Up Next advance to a *different* online item.
    public static func resolve(origin: CinemaOrigin,
                               hasReturnItem: Bool,
                               autoPlay: Bool,
                               advancingToNext: Bool) -> CinemaExitDestination {
        switch origin {
        case .offline(let ratingKey):
            // Offline never routes through the online router. An Up Next advance would hand an
            // online "next" `MediaItem` to the server-fetching path, so for offline we ignore the
            // advance entirely and simply return to the download's Offline row.
            return .offlineDownload(ratingKey: ratingKey)
        case .onlineTab(let tab):
            guard hasReturnItem else { return .none }
            return .onlineTabItem(tab: tab, autoPlay: autoPlay && !isNoop(advancingToNext: advancingToNext, autoPlay: autoPlay))
        case .systemEntry:
            guard hasReturnItem else { return .none }
            return .systemEntryItem(autoPlay: autoPlay)
        }
    }

    /// A trivial guard kept explicit for clarity/testing: an online-tab exit that is NOT an advance
    /// should not autoplay even if `autoPlay` was somehow set, since only the Up Next path sets it.
    private static func isNoop(advancingToNext: Bool, autoPlay: Bool) -> Bool {
        autoPlay && !advancingToNext
    }
}
