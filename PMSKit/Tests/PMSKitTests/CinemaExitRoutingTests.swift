import XCTest
@testable import PMSKit

/// Cinema exit must return to the ORIGIN playback was launched from, not always Home detail (#87).
final class CinemaExitRoutingTests: XCTestCase {

    private struct Case {
        let name: String
        let origin: CinemaOrigin
        let hasReturnItem: Bool
        let autoPlay: Bool
        let advancingToNext: Bool
        let expected: CinemaExitDestination
    }

    func testResolveTable() {
        let cases: [Case] = [
            // MARK: Offline origin (the outright-broken case)
            Case(name: "offline origin returns to offline download, no server fetch",
                 origin: .offline(ratingKey: "abc123"),
                 hasReturnItem: true, autoPlay: false, advancingToNext: false,
                 expected: .offlineDownload(ratingKey: "abc123")),
            // An Up Next advance hands an ONLINE next item to the server path — for offline we must
            // never do that; exit falls back to the offline download row instead.
            Case(name: "offline origin ignores Up Next advance",
                 origin: .offline(ratingKey: "abc123"),
                 hasReturnItem: true, autoPlay: true, advancingToNext: true,
                 expected: .offlineDownload(ratingKey: "abc123")),
            // Jellyfin/Emby offline rows are keyed by a namespaced download id, which can differ from
            // the reconstructed MediaItem.ratingKey. Preserve the row id exactly so the app can focus
            // the correct Offline row without touching the server.
            Case(name: "offline origin preserves namespaced download key",
                 origin: .offline(ratingKey: "jellyfin:item-42"),
                 hasReturnItem: true, autoPlay: false, advancingToNext: false,
                 expected: .offlineDownload(ratingKey: "jellyfin:item-42")),
            // The offline download is identified by ratingKey on the origin itself, not the session
            // item, so an exit still has somewhere to land.
            Case(name: "offline origin without return item still returns to download",
                 origin: .offline(ratingKey: "xyz"),
                 hasReturnItem: false, autoPlay: false, advancingToNext: false,
                 expected: .offlineDownload(ratingKey: "xyz")),

            // MARK: Online tab origins
            Case(name: "libraries origin returns to libraries tab",
                 origin: .onlineTab(.libraries),
                 hasReturnItem: true, autoPlay: false, advancingToNext: false,
                 expected: .onlineTabItem(tab: .libraries, autoPlay: false)),
            Case(name: "search origin returns to search tab",
                 origin: .onlineTab(.search),
                 hasReturnItem: true, autoPlay: false, advancingToNext: false,
                 expected: .onlineTabItem(tab: .search, autoPlay: false)),
            Case(name: "online tab Up Next advance carries autoPlay",
                 origin: .onlineTab(.home),
                 hasReturnItem: true, autoPlay: true, advancingToNext: true,
                 expected: .onlineTabItem(tab: .home, autoPlay: true)),
            Case(name: "online tab non-advance never autoplays",
                 origin: .onlineTab(.home),
                 hasReturnItem: true, autoPlay: true, advancingToNext: false,
                 expected: .onlineTabItem(tab: .home, autoPlay: false)),
            Case(name: "online tab without return item is none",
                 origin: .onlineTab(.libraries),
                 hasReturnItem: false, autoPlay: false, advancingToNext: false,
                 expected: .none),

            // MARK: System entry (legacy default — intents / Spotlight)
            Case(name: "system entry returns to Home detail",
                 origin: .systemEntry,
                 hasReturnItem: true, autoPlay: false, advancingToNext: false,
                 expected: .systemEntryItem(autoPlay: false)),
            Case(name: "system entry carries autoPlay",
                 origin: .systemEntry,
                 hasReturnItem: true, autoPlay: true, advancingToNext: true,
                 expected: .systemEntryItem(autoPlay: true)),
            Case(name: "system entry without return item is none",
                 origin: .systemEntry,
                 hasReturnItem: false, autoPlay: false, advancingToNext: false,
                 expected: .none),
        ]

        for testCase in cases {
            let destination = CinemaExitRouting.resolve(origin: testCase.origin,
                                                        hasReturnItem: testCase.hasReturnItem,
                                                        autoPlay: testCase.autoPlay,
                                                        advancingToNext: testCase.advancingToNext)
            XCTAssertEqual(destination, testCase.expected, testCase.name)
        }
    }

    // MARK: - CinemaTab mapping completeness

    func testCinemaTabRawValuesStable() {
        // The app maps RootView.AppTab <-> CinemaTab by these cases; guard against silent drift.
        XCTAssertEqual(Set(CinemaTab.allCases), [.home, .libraries, .search])
    }
}
