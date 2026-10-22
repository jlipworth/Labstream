#if DEBUG
import Testing
import PMSKit
@testable import Labstream

@Suite("Home mixed artwork fixture")
@MainActor
struct HomeShelfFixtureTests {
    @Test("Every backend exercises landscape-first posters and mixed episode artwork")
    func mixedSources() throws {
        for backend in [MediaBackendKind.plex, .jellyfin, .emby] {
            let hubs = DebugUIFixtureCatalog.mixedShapeHubs(backend: backend)
            #expect(hubs.count == 3)
            for hub in hubs {
                #expect(hub.metadata.count == 8)
                #expect(hub.metadata.first?.primaryImageAspectRatio == 16.0 / 9.0)
                #expect(hub.metadata[1].primaryImageAspectRatio == 2.0 / 3.0)
                #expect(hub.metadata[1].year == nil)
                #expect(hub.metadata[0].year != nil)
                #expect(HomeShelfPresentationPolicy.presentation(for: hub)
                        == (hub.type == "episode" ? .landscape : .poster))
            }
        }
    }
}
#endif
