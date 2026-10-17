import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "Labstream",
                               version: "0.1.0", deviceName: "AVP")

@Test func backgroundProcessingRequestTargetsType42Playlists() {
    let r = OptimizeRequest.backgroundProcessingRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/playlists")
    #expect(r.method == "GET")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "42")
    #expect(r.headers["Accept"] == "application/json")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func mediaProcessingTargetsRequestAsksForJSON() {
    let r = OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/media/processing/targets")
    #expect(r.method == "GET")
    #expect(r.headers["Accept"] == "application/json")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func createOnPlaylistPutsToKeyWithItemGrammar() throws {
    let r = try OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", serverMachineIdentifier: "MACHINE", title: "Blade Runner",
        targetTagID: 7,
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: 8000,
                             videoResolution: "1920x1080"))
    #expect(r.url.path == "/playlists/9/items")
    #expect(r.method == "PUT")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("Item[type]") == "42")
    #expect(v("Item[title]") == "Blade Runner")
    #expect(v("Item[target]") == "")
    // targetTagID is the SERVER-RESOLVED id passed in — NOT a hardcoded enum default.
    #expect(v("Item[targetTagID]") == "7")
    #expect(v("Item[MediaSettings][maxVideoBitrate]") == "8000")
    #expect(v("Item[MediaSettings][videoResolution]") == "1920x1080")
    #expect(v("Item[locationID]") == "-1")
    #expect(v("Item[Policy][scope]") == "all")
    // B38: the fallback Location URI names the SERVER (machine identifier), never the client.
    #expect(v("Item[Location][uri]")
        == "server://MACHINE/com.plexapp.plugins.library/library/metadata/101")
    #expect(v("Item[Location][uri]")?.contains("CID") == false)
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func createOnPlaylistCanCarryBuiltInTargetName() throws {
    let r = try OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", serverMachineIdentifier: "MACHINE", title: "T", targetTagID: 3,
        targetName: "Original Quality",
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil))
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("Item[target]") == "Original Quality")
    #expect(v("Item[targetTagID]") == "3")
}

@Test func createOnPlaylistSupportsCustomDeviceProfileQuality() throws {
    let r = try OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", sourceURI: "library://section/item/%2Flibrary%2Fmetadata%2F101",
        locationID: 6,
        title: "T", targetTagID: nil, targetName: "Custom: Universal TV",
        deviceProfile: "Universal TV",
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: 20_000,
                             videoResolution: "1920x1080"))
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(r.method == "PUT")
    #expect(v("Item[target]") == "Custom: Universal TV")
    #expect(v("Item[targetTagID]") == "")
    #expect(v("Item[Device][profile]") == "Universal TV")
    #expect(v("Item[MediaSettings][maxVideoBitrate]") == "20000")
    #expect(v("Item[locationID]") == "6")
    #expect(v("Item[Location][uri]") == "library://section/item/%2Flibrary%2Fmetadata%2F101")
}

@Test func createOnPlaylistOmitsAbsentMediaSettings() throws {
    let r = try OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", serverMachineIdentifier: "MACHINE", title: "T", targetTagID: 3,
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil))
    func names() -> [String] { r.queryItems.map(\.name) }
    #expect(!names().contains("Item[MediaSettings][maxVideoBitrate]"))
    #expect(!names().contains("Item[MediaSettings][videoResolution]"))
}

@Test func createOnPlaylistFailsClosedWithoutAnyServerSourceIdentity() {
    // B38: with no library source URI and no server machine identifier there is no URI PMS can
    // resolve. Fail clearly instead of sending a client-identifier URI the server ignores.
    #expect(throws: OptimizeRequest.CreateError.missingSourceLocation) {
        try OptimizeRequest.createOnPlaylist(
            server: server, token: "tok", identity: id,
            backgroundProcessingKey: "/playlists/9/items",
            ratingKey: "101", serverMachineIdentifier: "  ", title: "T", targetTagID: 3,
            mediaSettings: .init())
    }
    #expect(throws: OptimizeRequest.CreateError.missingSourceLocation) {
        try OptimizeRequest.createOnPlaylist(
            server: server, token: "tok", identity: id,
            backgroundProcessingKey: "/playlists/9/items",
            ratingKey: "101", title: "T", targetTagID: 3,
            mediaSettings: .init())
    }
}

@Test func decodesBackgroundProcessingPlaylistKey() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"playlistType":"42","key":"/playlists/9/items","title":"Background Processing"}
    ]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(BackgroundProcessingPlaylist.self, from: json)
    #expect(r.key == "/playlists/9/items")
}

@Test func decodesMediaProcessingTargets() throws {
    // Best-known shape; Phase 0 confirms the real element/field names against live PMS.
    let json = """
    {"MediaContainer":{"MediaProcessingTarget":[
      {"id":7,"tag":"Optimized for TV"},
      {"id":8,"tag":"Optimized for Mobile"}
    ]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(MediaProcessingTargets.self, from: json)
    #expect(r.targets.count == 2)
    #expect(r.targets.first?.id == 7)
    #expect(r.targets.first?.name == "Optimized for TV")
    // Case-insensitive name lookup helper used by the manager to resolve a chosen preset.
    #expect(r.tagID(forName: "optimized for tv") == 7)
    #expect(r.tagID(forName: "nonexistent") == nil)
}

@Test func urlRequestEscapesOptimizerReservedQueryValueSeparators() throws {
    let r = try OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "31518",
        sourceURI: "library://62bf/item/%2Flibrary%2Fmetadata%2F31518",
        title: "Vaccine Court; The Tequila Heist; This Is Rob Reiner",
        targetTagID: nil, targetName: "Custom: Universal TV",
        deviceProfile: "Universal TV",
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: 4_000,
                             videoResolution: "1280x720"))
    let absolute = try #require(r.urlRequest().url?.absoluteString)
    #expect(absolute.contains("Vaccine%20Court%3B%20The%20Tequila"))
    #expect(absolute.contains("Custom%3A%20Universal%20TV"))
    #expect(absolute.contains("library%3A%2F%2F62bf%2Fitem%2F%252Flibrary%252Fmetadata%252F31518"))
    #expect(!absolute.contains("Vaccine%20Court;%20"))
}

// MARK: - Stale background-job cleanup (slow-start fix)

@Test func removeBackgroundItemBuildsDeleteUnderItemsKey() {
    let r = OptimizeRequest.removeBackgroundItem(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items", itemID: "1234")
    #expect(r.method == "DELETE")
    #expect(r.url.path == "/playlists/9/items/1234")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func backgroundItemsDecodeLenientlyWithIntIdAndStatusState() throws {
    let json = """
    {"MediaContainer":{"size":2,"Item":[
      {"id":7,"title":"Old Movie [Labstream aaaa1111]","Status":{"state":"pending"}},
      {"id":"8","title":"Library Scan"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    #expect(q.items.count == 2)
    #expect(q.items[0].id == "7")           // Int id tolerated
    #expect(q.items[0].state == "pending")
    #expect(q.items[1].id == "8")           // String id tolerated
    #expect(q.items[1].state == nil)
}

@Test func backgroundItemsGarbageShapeDoesNotThrow() throws {
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self,
                                     from: #"{"nope":1}"#.data(using: .utf8)!)
    #expect(q.items.isEmpty)
}

@Test func backgroundItemFlexibleIdTreatsNullMalformedAndMissingAsNil() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":null,"title":"Null"},
      {"id":{"unexpected":1},"title":"Malformed"},
      {"title":"Missing"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    #expect(q.items.map(\.title) == ["Null", "Malformed", "Missing"])
    #expect(q.items.map(\.id) == [nil, nil, nil])
}

@Test func staleItemIDsOnlyOurMarkedUnprotectedItems() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Abandoned A [Labstream aaaa1111]"},
      {"id":"2","title":"In Flight [Labstream bbbb2222]"},
      {"id":"3","title":"Someone Else's Job"},
      {"id":"4","title":"Abandoned B [Labstream cccc3333]"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let protected: Set<String> = ["In Flight [Labstream bbbb2222]"]
    let stale = q.staleItemIDs(marker: "[Labstream ", protectedTitles: protected)
    // Deletes our two abandoned items; never the protected in-flight one, never the
    // non-Labstream job (no marker).
    #expect(Set(stale) == ["1", "4"])
}

@Test func staleItemIDsSkipsCompletedJobsWhoseFileMayBeDownloading() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Pending Junk [Labstream aaaa1111]","Status":{"state":"pending"}},
      {"id":"2","title":"Just Finished [Labstream bbbb2222]","Status":{"state":"complete"}},
      {"id":"3","title":"Failed Junk [Labstream cccc3333]","Status":{"state":"error"}},
      {"id":"4","title":"Leftover B [Labstream dddd4444]","Status":{"state":"completed"}},
      {"id":"5","title":"Leftover C [Labstream eeee5555]","Status":{"state":"successful"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let stale = q.staleItemIDs(marker: "[Labstream ", protectedTitles: [])
    // Clears the pending + failed pileup, but NOT completed jobs in any completed-state spelling.
    // Live Plex evidence showed that deleting a completed type-42 item removes the rendered
    // optimized version before a relaunched client can download it.
    #expect(Set(stale) == ["1", "3"])
}

// MARK: - Delete-time targeted cancel (`cancellableItemID`)

@Test func cancellableItemIDMatchesExactTitleOnly() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Movie A [Labstream aaaa1111]","Status":{"state":"pending"}},
      {"id":"2","title":"Movie B [Labstream bbbb2222]","Status":{"state":"processing"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    #expect(q.cancellableItemID(queueTitle: "Movie B [Labstream bbbb2222]") == "2")
    #expect(q.cancellableItemID(queueTitle: "Movie C [Labstream dddd4444]") == nil)
}

@Test func cancellableItemIDRefusesCompletedRenders() throws {
    // A completed type-42 item IS the rendered server-side version; delete-time cancel must
    // never remove it even when the queue title matches the deleted row exactly.
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"9","title":"Done Movie [Labstream eeee5555]","Status":{"state":"complete"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    #expect(q.cancellableItemID(queueTitle: "Done Movie [Labstream eeee5555]") == nil)
}

// MARK: - downloadURL

@Test func downloadURLPercentEncodesReservedQuerySeparators() throws {
    let url = OptimizeRequest.downloadURL(server: server,
                                          token: "tok;download=0&x=/",
                                          partKey: "/library/parts/55/file.mp4")
    let query = try #require(URLComponents(url: url,
                                           resolvingAgainstBaseURL: false)?.percentEncodedQuery)

    #expect(query == "download=1&X-Plex-Token=tok%3Bdownload%3D0%26x%3D%2F")
    #expect(!query.contains(";"))
    #expect(!query.contains("&x="))
}

@Test func downloadURLPlacesPartKeyInPath() {
    let url = OptimizeRequest.downloadURL(server: server, token: "tok",
                                          partKey: "/library/parts/55/file.mp4")
    #expect(url.path == "/library/parts/55/file.mp4")
    #expect(url.host == "192.0.2.10")
}
