import Foundation

/// Pure decision for which top-level UI the main window should show (#90 finding 2).
///
/// The "switching to Plex bounces to Home" fix previously lived as hand-managed field
/// preservation inside `refreshServers` — an emergent property of *not nulling* the Plex
/// fields during the async discovery window. That made the real invariant — *a backend
/// switch must not drop the browse UI until the new lane is live* — a Plex-only carve-out
/// that a future async-restoring backend could silently reintroduce.
///
/// Centralizing the rule here makes it explicit and unit-testable: an ALREADY-READY browse
/// UI stays mounted through `isSwitchingBackend` regardless of which backend is switching or
/// whether its restore is sync/async, so no per-backend restore path can bounce the UI. A
/// genuinely-signed-out user (no prior ready lane) still sees the restore splash / login.
public enum BrowseUIGate {

    public enum State: Sendable, Equatable {
        /// Mount `RootView` (browse UI).
        case browse
        /// Show the neutral restore/connecting splash.
        case restoringSplash
        /// Show the sign-in screen.
        case login
    }

    /// Resolve the top-level UI state.
    ///
    /// - Parameters:
    ///   - isBrowseReady: the active backend's lane is fully live.
    ///   - isRestoring: launch-time session restore is still running.
    ///   - isSwitchingBackend: a backend switch is mid-flight (re-resolving the target lane).
    ///   - hasEverBeenBrowseReady: the browse UI has been mounted at least once this app run.
    ///     Distinguishes a switch FROM an already-ready UI (keep it mounted) from a first-ever
    ///     switch with no prior browse UI (still show the splash so we don't strand a blank RootView).
    public static func state(isBrowseReady: Bool,
                             isRestoring: Bool,
                             isSwitchingBackend: Bool,
                             hasEverBeenBrowseReady: Bool) -> State {
        if isBrowseReady { return .browse }
        // Keep an already-ready browse UI mounted through a switch instead of bouncing to the
        // splash — the new lane will flip `isBrowseReady` true again when it reports live.
        if isSwitchingBackend && hasEverBeenBrowseReady { return .browse }
        if isRestoring || isSwitchingBackend { return .restoringSplash }
        return .login
    }
}
