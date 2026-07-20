#if os(tvOS) && DEBUG
import Foundation

/// Production-isolated launch configuration for deterministic tvOS UI tests. These arguments
/// never mint credentials or alter the release path; they only choose a signed-out backend and
/// bypass asynchronous Keychain restore so focus tests always start from the same surface.
@MainActor
enum TVUITestLaunchConfiguration {
    static let enabledFlag = "--ui-testing"
    static let backendFlag = "--ui-testing-backend"
    static let fixtureFlag = "--ui-testing-fixture"

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

    static var usesBrowseFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard isEnabled,
              let index = arguments.firstIndex(of: fixtureFlag),
              arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == "browse"
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
