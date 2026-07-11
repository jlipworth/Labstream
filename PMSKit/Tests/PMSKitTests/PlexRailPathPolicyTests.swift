import Testing
@testable import PMSKit

struct PlexRailPathPolicyTests {
    @Test func acceptsSectionRecentlyAddedPath() {
        #expect(PlexRailPathPolicy.safeRecentlyAddedPath("/library/sections/12/recentlyAdded") == "/library/sections/12/recentlyAdded")
    }

    @Test(arguments: [
        "https://server/library/sections/1/recentlyAdded",
        "/library/sections/../recentlyAdded",
        "/library/sections/1/all",
        "/hubs/sections/1/recentlyAdded",
        "/library/sections/1/recentlyAdded/extra",
    ])
    func rejectsUnsafeOrUnsupportedPaths(path: String) {
        #expect(PlexRailPathPolicy.safeRecentlyAddedPath(path) == nil)
    }
}
