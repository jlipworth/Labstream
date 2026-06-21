import XCTest
@testable import PMSKit

/// Cinema exit must return to the ORIGIN playback was launched from, not always Home detail (#87).
final class CinemaExitRoutingTests: XCTestCase {

    // MARK: - Offline origin (the outright-broken case)

    func testOfflineOriginReturnsToOfflineDownloadNoServerFetch() {
        let dest = CinemaExitRouting.resolve(origin: .offline(ratingKey: "abc123"),
                                             hasReturnItem: true,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .offlineDownload(ratingKey: "abc123"))
    }

    func testOfflineOriginIgnoresUpNextAdvance() {
        // An Up Next advance hands an ONLINE next item to the server path — for offline we must
        // never do that; exit falls back to the offline download row instead.
        let dest = CinemaExitRouting.resolve(origin: .offline(ratingKey: "abc123"),
                                             hasReturnItem: true,
                                             autoPlay: true,
                                             advancingToNext: true)
        XCTAssertEqual(dest, .offlineDownload(ratingKey: "abc123"))
    }

    func testOfflineOriginPreservesNamespacedDownloadKey() {
        // Jellyfin/Emby offline rows are keyed by a namespaced download id, which can differ from
        // the reconstructed MediaItem.ratingKey. Preserve the row id exactly so the app can focus
        // the correct Offline row without touching the server.
        let dest = CinemaExitRouting.resolve(origin: .offline(ratingKey: "jellyfin:item-42"),
                                             hasReturnItem: true,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .offlineDownload(ratingKey: "jellyfin:item-42"))
    }

    func testOfflineOriginEvenWithoutReturnItemStillReturnsToDownload() {
        // The offline download is identified by ratingKey on the origin itself, not the session
        // item, so an exit still has somewhere to land.
        let dest = CinemaExitRouting.resolve(origin: .offline(ratingKey: "xyz"),
                                             hasReturnItem: false,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .offlineDownload(ratingKey: "xyz"))
    }

    // MARK: - Online tab origins

    func testLibrariesOriginReturnsToLibrariesTab() {
        let dest = CinemaExitRouting.resolve(origin: .onlineTab(.libraries),
                                             hasReturnItem: true,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .onlineTabItem(tab: .libraries, autoPlay: false))
    }

    func testSearchOriginReturnsToSearchTab() {
        let dest = CinemaExitRouting.resolve(origin: .onlineTab(.search),
                                             hasReturnItem: true,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .onlineTabItem(tab: .search, autoPlay: false))
    }

    func testOnlineTabUpNextAdvanceCarriesAutoPlay() {
        let dest = CinemaExitRouting.resolve(origin: .onlineTab(.home),
                                             hasReturnItem: true,
                                             autoPlay: true,
                                             advancingToNext: true)
        XCTAssertEqual(dest, .onlineTabItem(tab: .home, autoPlay: true))
    }

    func testOnlineTabNonAdvanceNeverAutoPlays() {
        let dest = CinemaExitRouting.resolve(origin: .onlineTab(.home),
                                             hasReturnItem: true,
                                             autoPlay: true,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .onlineTabItem(tab: .home, autoPlay: false))
    }

    func testOnlineTabWithoutReturnItemIsNone() {
        let dest = CinemaExitRouting.resolve(origin: .onlineTab(.libraries),
                                             hasReturnItem: false,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .none)
    }

    // MARK: - System entry (legacy default — intents / Spotlight)

    func testSystemEntryReturnsToHomeDetail() {
        let dest = CinemaExitRouting.resolve(origin: .systemEntry,
                                             hasReturnItem: true,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .systemEntryItem(autoPlay: false))
    }

    func testSystemEntryCarriesAutoPlay() {
        let dest = CinemaExitRouting.resolve(origin: .systemEntry,
                                             hasReturnItem: true,
                                             autoPlay: true,
                                             advancingToNext: true)
        XCTAssertEqual(dest, .systemEntryItem(autoPlay: true))
    }

    func testSystemEntryWithoutReturnItemIsNone() {
        let dest = CinemaExitRouting.resolve(origin: .systemEntry,
                                             hasReturnItem: false,
                                             autoPlay: false,
                                             advancingToNext: false)
        XCTAssertEqual(dest, .none)
    }

    // MARK: - CinemaTab mapping completeness

    func testCinemaTabRawValuesStable() {
        // The app maps RootView.AppTab <-> CinemaTab by these cases; guard against silent drift.
        XCTAssertEqual(Set(CinemaTab.allCases), [.home, .libraries, .search])
    }
}
