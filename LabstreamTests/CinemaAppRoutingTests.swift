#if os(visionOS)
// This suite intentionally compiles only with a visionOS-hosted test target. The repository's
// current native matrix records that target as planned, so these assertions are preserved without
// pretending that the iOS/macOS hosted copies execute app-only Cinema composition.
import PMSKit
import Testing
@testable import Labstream

@Suite("Cinema app routing")
struct CinemaAppRoutingTests {
    private enum RecordedAction: Equatable {
        case online(MediaItem, autoPlay: Bool, tab: CinemaTab)
        case systemEntry(MediaItem, autoPlay: Bool)
        case offline(ratingKey: String)
    }

    @Test("Online playback retains its exact browse-tab origin")
    func onlineOriginComposition() {
        #expect(CinemaAppRouting.onlineOrigin(for: .home) == .onlineTab(.home))
        #expect(CinemaAppRouting.onlineOrigin(for: .libraries) == .onlineTab(.libraries))
        #expect(CinemaAppRouting.onlineOrigin(for: .search) == .onlineTab(.search))
        #expect(CinemaAppRouting.onlineOrigin(for: nil) == .systemEntry)
    }

    @Test("Offline exit writes only the offline return action")
    @MainActor
    func offlineDispatch() {
        let actions = record(.offlineDownload(ratingKey: "jellyfin:item-42"), returnItem: nil)
        #expect(actions == [.offline(ratingKey: "jellyfin:item-42")])
    }

    @Test("Online exit retains item, autoplay, and originating tab")
    @MainActor
    func onlineDispatch() {
        let item = MediaItem(ratingKey: "movie-1", title: "Movie", type: "movie")
        let actions = record(.onlineTabItem(tab: .libraries, autoPlay: true), returnItem: item)
        #expect(actions == [.online(item, autoPlay: true, tab: .libraries)])
    }

    @Test("System-entry exit retains item and autoplay without inventing a browse tab")
    @MainActor
    func systemEntryDispatch() {
        let item = MediaItem(ratingKey: "movie-2", title: "Movie 2", type: "movie")
        let actions = record(.systemEntryItem(autoPlay: false), returnItem: item)
        #expect(actions == [.systemEntry(item, autoPlay: false)])
    }

    @Test("Item destinations cannot dispatch without the resolved return item")
    @MainActor
    func missingItemDoesNotDispatch() {
        #expect(record(.onlineTabItem(tab: .search, autoPlay: true), returnItem: nil).isEmpty)
        #expect(record(.systemEntryItem(autoPlay: true), returnItem: nil).isEmpty)
        #expect(record(.none, returnItem: nil).isEmpty)
    }

    @MainActor
    private func record(_ destination: CinemaExitDestination,
                        returnItem: MediaItem?) -> [RecordedAction] {
        var actions: [RecordedAction] = []
        CinemaAppRouting.dispatch(
            destination,
            returnItem: returnItem,
            openOnlineTabItem: { actions.append(.online($0, autoPlay: $1, tab: $2)) },
            openSystemEntryItem: { actions.append(.systemEntry($0, autoPlay: $1)) },
            openOfflineDownload: { actions.append(.offline(ratingKey: $0)) })
        return actions
    }
}
#endif
