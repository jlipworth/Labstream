#if DEBUG
import Foundation

/// Production-isolated launch configuration for deterministic agent and UI-test runs.
///
/// The shared browse fixture lets every product exercise its real Home/Libraries/Detail composition
/// without a server or credentials. The remaining fixture kinds are tvOS-only surfaces selected by
/// `ContentView`. Release builds cannot see this type, and the placeholder session below is never
/// persisted.
@MainActor
enum DebugUITestLaunchConfiguration {
    nonisolated static let enabledFlag = "--ui-testing"
    nonisolated static let backendFlag = "--ui-testing-backend"
    nonisolated static let fixtureFlag = "--ui-testing-fixture"
    nonisolated static let downloadCompositionEvidenceFlag = "--ui-testing-download-composition-evidence"

    static var isEnabled: Bool {
        isEnabled(in: ProcessInfo.processInfo.arguments)
    }

    /// Browse-fixture capture routes for headless layout evidence (iPhone/iPad shell): select a
    /// tab at launch (`home`, `libraries`, `search`, `music`, `offline`), push the fixture's
    /// first library grid, or seed the Search query. Nothing deep-links to these screens and
    /// simulator taps are not scriptable, so these make folded/appResize captures possible.
    nonisolated static let initialTabFlag = "--ui-testing-initial-tab"
    nonisolated static let openFirstLibraryFlag = "--ui-testing-open-first-library"
    nonisolated static let searchQueryFlag = "--ui-testing-search-query"
    /// Push a fixture item (movie, show or fixture season, by rating key) onto Home at launch.
    nonisolated static let openItemFlag = "--ui-testing-open-item"

    nonisolated static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        guard isEnabled(in: arguments),
              let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static var initialTab: String? {
        argumentValue(initialTabFlag, in: ProcessInfo.processInfo.arguments)
    }

    static var opensFirstLibrary: Bool {
        usesBrowseFixture && ProcessInfo.processInfo.arguments.contains(openFirstLibraryFlag)
    }

    static var initialOpenItemKey: String? {
        usesBrowseFixture ? argumentValue(openItemFlag, in: ProcessInfo.processInfo.arguments) : nil
    }

    static var initialSearchQuery: String? {
        usesBrowseFixture ? argumentValue(searchQueryFlag, in: ProcessInfo.processInfo.arguments) : nil
    }

    static var initialBackend: MediaBackendKind? {
        initialBackend(in: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func isEnabled(in arguments: [String]) -> Bool {
        arguments.contains(enabledFlag)
    }

    nonisolated static func initialBackend(in arguments: [String]) -> MediaBackendKind? {
        guard isEnabled(in: arguments) else { return nil }
        guard let index = arguments.firstIndex(of: backendFlag),
              arguments.indices.contains(index + 1) else { return .plex }
        return MediaBackendKind(rawValue: arguments[index + 1]) ?? .plex
    }

    /// Deterministic launch surfaces for UI tests. `browse` seeds synthetic credentials and
    /// catalog data through the real views; `player` presents the shared custom player over a
    /// generated local file (tvOS, macOS dev identities, and iPhone/iPad).
    enum FixtureKind: String {
        case browse
        /// Real season container browser with deterministic episode children. This fixture
        /// protects the streaming-only product contract: tvOS must not expose Offline actions.
        case season
        case player
        /// Restricted cold-launch Offline surface (banner + Offline library) without a
        /// reachable server. Not available on tvOS, which has no Offline surface.
        case offline
    }

    static var fixtureKind: FixtureKind? {
        fixtureKind(in: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func fixtureKind(in arguments: [String]) -> FixtureKind? {
        guard isEnabled(in: arguments),
              let index = arguments.firstIndex(of: fixtureFlag),
              arguments.indices.contains(index + 1) else { return nil }
        return FixtureKind(rawValue: arguments[index + 1])
    }

    static var usesBrowseFixture: Bool {
        fixtureKind == .browse
    }

    /// Opt-in launch marker used by the TV UI smoke to prove that the streaming-only
    /// composition path reached first render. Requiring both flags keeps test evidence out of
    /// ordinary Debug launches just like the fixture catalog itself.
    static var requestsDownloadCompositionEvidence: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(downloadCompositionEvidenceFlag)
    }

    /// Player-fixture variant: pins the controller's transport status in `.buffering` (or
    /// `.pausedBuffering` with the paused flag on iPhone/iPad) through the real presentation
    /// timing, so the spinner and escalated card can be reviewed deterministically (TVUI-025).
    static var playerFixtureStartsBuffering: Bool {
        fixtureKind == .player && ProcessInfo.processInfo.arguments.contains("--ui-testing-player-buffering")
    }

    /// Mobile player-fixture source aspect (#258). Each value maps to an even encoded size of the
    /// synthetic local clip so chrome geometry can be compared across source aspects.
    enum PlayerFixtureAspect: String, CaseIterable {
        case widescreen = "16x9"
        case scope = "239x100"
        case academy = "4x3"

        var encodedSize: (width: Int, height: Int) {
            switch self {
            case .widescreen: (1280, 720)
            case .scope: (1280, 536)
            case .academy: (960, 720)
            }
        }
    }

    nonisolated static let playerAspectFlag = "--ui-testing-player-aspect"
    nonisolated static let playerPausedFlag = "--ui-testing-player-paused"
    nonisolated static let playerGeometryFlag = "--ui-testing-player-geometry"
    nonisolated static let playerAllMenusFlag = "--ui-testing-player-all-menus"
    nonisolated static let playerPresentDelayFlag = "--ui-testing-player-present-delay"

    /// Seconds the player fixture waits before presenting the player (default 0). A host-side
    /// `devicectl device appResize` session can only start while the app is portrait and
    /// frontmost, so the iPhone Duo resize proxy starts it during this window, before the player
    /// applies its landscape lock.
    nonisolated static func playerFixturePresentDelaySeconds(in arguments: [String]) -> Int {
        guard fixtureKind(in: arguments) == .player,
              let index = arguments.firstIndex(of: playerPresentDelayFlag),
              arguments.indices.contains(index + 1),
              let seconds = Int(arguments[index + 1]) else { return 0 }
        return min(max(seconds, 0), 60)
    }

    static var playerFixturePresentDelaySeconds: Int {
        playerFixturePresentDelaySeconds(in: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func playerFixtureAspect(in arguments: [String]) -> PlayerFixtureAspect {
        guard fixtureKind(in: arguments) == .player,
              let index = arguments.firstIndex(of: playerAspectFlag),
              arguments.indices.contains(index + 1) else { return .widescreen }
        return PlayerFixtureAspect(rawValue: arguments[index + 1]) ?? .widescreen
    }

    static var playerFixtureAspect: PlayerFixtureAspect {
        playerFixtureAspect(in: ProcessInfo.processInfo.arguments)
    }

    /// Holds the fixture paused once playback is ready, so the chrome stays visible in one
    /// deterministic state for geometry comparison.
    static var playerFixtureStartsPaused: Bool {
        fixtureKind == .player && ProcessInfo.processInfo.arguments.contains(playerPausedFlag)
    }

    /// Debug-only privacy-safe chrome/video geometry log (labels and frames only). Requires the
    /// UI-testing flag, so ordinary Debug launches stay quiet.
    static var logsPlayerGeometry: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains(playerGeometryFlag)
    }

    /// Player-fixture variant: offers the Quality menu even though a local file cannot reopen a
    /// stream, so the fixture can hold the full streaming menu set (the widest bottom row).
    static var playerFixtureShowsAllMenus: Bool {
        fixtureKind == .player && ProcessInfo.processInfo.arguments.contains(playerAllMenusFlag)
    }

    static func configure(appModel: AppModel, bootstrap: SessionBootstrap) {
        guard let initialBackend else { return }
        appModel.activeBackend = initialBackend
        if usesBrowseFixture {
            let fixtureURL = URL(string: "https://fixture.invalid")!
            switch initialBackend {
            case .plex:
                appModel.token = "ui-test-token"
                appModel.serverToken = "ui-test-server-token"
                appModel.serverBaseURL = fixtureURL
            case .jellyfin:
                appModel.jellyfinServerBaseURL = fixtureURL
                appModel.jellyfinAccessToken = "ui-test-token"
                appModel.jellyfinUserID = "ui-test-user"
                appModel.jellyfinServerID = "ui-test-server"
            case .emby:
                appModel.embyServerBaseURL = fixtureURL
                appModel.embyAccessToken = "ui-test-token"
                appModel.embyUserID = "ui-test-user"
                appModel.embyServerID = "ui-test-server"
            }
            bootstrap.hasEverBeenBrowseReady = true
        }
        bootstrap.didStartRestore = true
        bootstrap.isRestoring = false
    }
}
#endif
