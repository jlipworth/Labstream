import Foundation
import Testing
@testable import Labstream
import PMSKit

@Suite("Search publication identity")
@MainActor
struct SearchDisplayStateTests {
    private func model() -> AppModel {
        let model = AppModel(identity: ClientIdentity(clientIdentifier: "search-test", product: "Labstream",
                                                       version: "1", deviceName: "Test"), activeBackend: .plex)
        model.serverBaseURL = URL(string: "https://plex.example.test")!
        model.serverToken = "fixture-token"
        return model
    }

    private var results: SearchResults {
        SearchResults(groups: [SearchResultGroup(id: "library", libraryID: "1", title: "Movies",
            hubs: [Hub(title: "Movies", metadata: [MediaItem(ratingKey: "1", title: "Paper Moon", type: "movie")])])])
    }

    @Test func rapidTypingPinsDisplayedQueryUntilCurrentPublication() {
        let model = model()
        let a = SearchLoadIdentity(appModel: model, query: " paper ")
        let b = SearchLoadIdentity(appModel: model, query: "paper moon")
        var display = SearchDisplayState()
        display.publish(results, for: a, current: a, isCancelled: false)
        #expect(display.isVisible(in: b))
        #expect(display.identity?.query == "paper") // View All uses this, not b.
        display.publish(.empty, for: a, current: b, isCancelled: false)
        #expect(display.groups.count == 1)
        display.publish(.empty, for: b, current: b, isCancelled: false)
        #expect(display.identity == b)
        #expect(display.groups.isEmpty) // Empty-state copy also belongs to b.
        // An older backend completion arriving after the new result must not win.
        display.publish(results, for: a, current: b, isCancelled: false)
        #expect(display.identity == b)
        #expect(display.groups.isEmpty)
    }

    @Test func cancellationAndClearCannotResurrectOldResults() {
        let model = model()
        let a = SearchLoadIdentity(appModel: model, query: "paper")
        let empty = SearchLoadIdentity(appModel: model, query: " \n ")
        var display = SearchDisplayState()
        display.publish(results, for: a, current: a, isCancelled: false)
        #expect(!display.isVisible(in: empty))
        display.clear()
        display.publish(results, for: a, current: empty, isCancelled: false)
        display.publish(results, for: a, current: a, isCancelled: true)
        #expect(display.identity == nil)
        #expect(display.groups.isEmpty)
    }

    @Test func sessionAndBackendChangesHideAndRejectOldPublication() {
        let model = model()
        let a = SearchLoadIdentity(appModel: model, query: "paper")
        var display = SearchDisplayState()
        display.publish(results, for: a, current: a, isCancelled: false)
        model.serverToken = "replacement-fixture-token"
        let b = SearchLoadIdentity(appModel: model, query: "paper")
        #expect(!display.isVisible(in: b))
        display.publish(.empty, for: a, current: b, isCancelled: false)
        #expect(display.identity == a)
        model.activeBackend = .jellyfin
        let c = SearchLoadIdentity(appModel: model, query: "paper")
        #expect(!display.isVisible(in: c))
        display.publish(.empty, for: b, current: c, isCancelled: false)
        #expect(display.identity == a)
    }
}
