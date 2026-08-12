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

    /// Deterministic launch surfaces for tvOS UI tests. `browse` seeds synthetic credentials and
    /// catalog data through the real views; `player` presents the shared custom player over a
    /// generated local file; `keyboard` shows a minimal native `TextField` used to classify the
    /// system-keyboard insertion defect (TVUI-004) as app versus runtime behavior.
    enum FixtureKind: String {
        case browse
        /// Real season container browser with deterministic episode children. This fixture
        /// protects the streaming-only product contract: tvOS must not expose Offline actions.
        case season
        case player
        case keyboard
        /// TVUI-004 shell bisection: the replica field passes in isolation, so this variant
        /// rebuilds the Search tab's hosting shell (TabView + NavigationStack + results
        /// ScrollView + conditional trailing button) around it to find the layer that kills
        /// system-keyboard insertion.
        case keyboardShell = "keyboard-shell"
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

    /// Player-fixture variant: holds the controller's transport status in `.buffering` so the
    /// buffering overlay can be reviewed deterministically (TVUI-025).
    static var playerFixtureStartsBuffering: Bool {
        fixtureKind == .player && ProcessInfo.processInfo.arguments.contains("--ui-testing-player-buffering")
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
