import Testing
@testable import PMSKit

struct PlexRailPathPolicyTests {
    @Test func acceptsSectionAndTypedHomeRecentlyAddedPaths() {
        #expect(PlexRailPathPolicy.recentlyAddedSelection("/library/sections/12/recentlyAdded") == .init(path: "/library/sections/12/recentlyAdded", type: nil))
        #expect(PlexRailPathPolicy.recentlyAddedSelection("/hubs/home/recentlyAdded?type=1") == .init(path: "/hubs/home/recentlyAdded", type: 1))
        #expect(PlexRailPathPolicy.recentlyAddedSelection("/hubs/home/recentlyAdded?type=2") == .init(path: "/hubs/home/recentlyAdded", type: 2))
    }

    @Test(arguments: ["https://server/library/sections/1/recentlyAdded", "/library/sections/../recentlyAdded", "/library/sections/1/all", "/hubs/home/recentlyAdded", "/hubs/home/recentlyAdded?type=8", "/hubs/home/recentlyAdded?type=1&personal=1", "/library/sections/1/recentlyAdded/extra"])
    func rejectsUnsafeOrUnsupportedPaths(path: String) {
        #expect(PlexRailPathPolicy.recentlyAddedSelection(path) == nil)
    }
}
