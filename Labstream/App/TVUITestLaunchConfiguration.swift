#if os(tvOS) && DEBUG
import Foundation

/// Production-isolated launch configuration for deterministic tvOS UI tests. These arguments
/// never mint credentials or alter the release path; they only choose a signed-out backend and
/// bypass asynchronous Keychain restore so focus tests always start from the same surface.
@MainActor
enum TVUITestLaunchConfiguration {
    nonisolated static let enabledFlag = "--ui-testing"
    nonisolated static let backendFlag = "--ui-testing-backend"
    nonisolated static let fixtureFlag = "--ui-testing-fixture"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(enabledFlag)
    }

    static var initialBackend: MediaBackendKind? {
        guard isEnabled else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
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
        case player
        case keyboard
        /// TVUI-004 shell bisection: the replica field passes in isolation, so this variant
        /// rebuilds the Search tab's hosting shell (TabView + NavigationStack + results
        /// ScrollView + conditional trailing button) around it to find the layer that kills
        /// system-keyboard insertion.
        case keyboardShell = "keyboard-shell"
    }

    static var fixtureKind: FixtureKind? {
        let arguments = ProcessInfo.processInfo.arguments
        guard isEnabled,
              let index = arguments.firstIndex(of: fixtureFlag),
              arguments.indices.contains(index + 1) else { return nil }
        return FixtureKind(rawValue: arguments[index + 1])
    }

    static var usesBrowseFixture: Bool {
        fixtureKind == .browse
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
