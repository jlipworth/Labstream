import Testing
@testable import Labstream
@testable import PMSKit

@Suite("MediaBrowser Home provider routing")
@MainActor
struct MediaBrowserHomeProviderTests {
    @Test func plexCannotCreateMediaBrowserProvider() {
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "home-provider-plex"),
            activeBackend: .plex
        )

        if let _ = MediaBrowserHomeProvider(appModel: model) {
            Issue.record("Plex must use its native Home provider")
        }
    }

    @Test func providerKeepsOriginalMediaBrowserLaneAfterActiveBackendChanges() throws {
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "home-provider-snapshot"),
            activeBackend: .emby
        )
        let provider = try #require(MediaBrowserHomeProvider(appModel: model))

        model.activeBackend = .plex

        #expect(provider.backend == .emby)
    }
}
