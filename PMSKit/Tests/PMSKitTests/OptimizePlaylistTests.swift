import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlay",
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

@Test func createOnPlaylistPutsToKeyWithItemGrammar() {
    let r = OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", title: "Blade Runner",
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
    #expect(v("Item[Location][uri]")?.contains("/library/metadata/101") == true)
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func createOnPlaylistCanCarryBuiltInTargetName() {
    let r = OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", title: "T", targetTagID: 3,
        targetName: "Original Quality",
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil))
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("Item[target]") == "Original Quality")
    #expect(v("Item[targetTagID]") == "3")
}

@Test func createOnPlaylistSupportsCustomDeviceProfileQuality() {
    let r = OptimizeRequest.createOnPlaylist(
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

@Test func createOnPlaylistOmitsAbsentMediaSettings() {
    let r = OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", title: "T", targetTagID: 3,
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil))
    func names() -> [String] { r.queryItems.map(\.name) }
    #expect(!names().contains("Item[MediaSettings][maxVideoBitrate]"))
    #expect(!names().contains("Item[MediaSettings][videoResolution]"))
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
    let r = OptimizeRequest.createOnPlaylist(
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
      {"id":7,"title":"Old Movie [VisionPlay aaaa1111]","Status":{"state":"pending"}},
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

@Test func staleItemIDsOnlyOurMarkedUnprotectedItems() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Abandoned A [VisionPlay aaaa1111]"},
      {"id":"2","title":"In Flight [VisionPlay bbbb2222]"},
      {"id":"3","title":"Someone Else's Job"},
      {"id":"4","title":"Abandoned B [VisionPlay cccc3333]"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let protected: Set<String> = ["In Flight [VisionPlay bbbb2222]"]
    let stale = q.staleItemIDs(marker: "[VisionPlay ", protectedTitles: protected)
    // Deletes our two abandoned items; never the protected in-flight one, never the
    // non-VisionPlay job (no marker).
    #expect(Set(stale) == ["1", "4"])
}

@Test func staleItemIDsSkipsCompletedJobsWhoseFileMayBeDownloading() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Pending Junk [VisionPlay aaaa1111]","Status":{"state":"pending"}},
      {"id":"2","title":"Just Finished [VisionPlay bbbb2222]","Status":{"state":"complete"}},
      {"id":"3","title":"Failed Junk [VisionPlay cccc3333]","Status":{"state":"error"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let stale = q.staleItemIDs(marker: "[VisionPlay ", protectedTitles: [])
    // Clears the pending + failed pileup, but NOT the completed job (its file may be in use).
    #expect(Set(stale) == ["1", "3"])
}

// MARK: - Safe cleanup (`removableItemIDs`): completed server renders are preserved

@Test func removableItemIDsPreservesCompletedServerRenders() throws {
    // Completed Plex optimize items are not inert clutter: deleting the type-42 item also
    // deletes the rendered server-side optimized version. Only non-completed marked clutter is
    // removable; completed jobs must remain discoverable for app relaunch/retry.
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Pending Junk [VisionPlay aaaa1111]","Status":{"state":"pending"}},
      {"id":"2","title":"Leftover A [VisionPlay bbbb2222]","Status":{"state":"complete"}},
      {"id":"3","title":"Leftover B [VisionPlay cccc3333]","Status":{"state":"completed"}},
      {"id":"4","title":"Failed Junk [VisionPlay dddd4444]","Status":{"state":"error"}},
      {"id":"5","title":"Leftover C [VisionPlay eeee5555]","Status":{"state":"successful"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let removable = q.removableItemIDs(marker: "[VisionPlay ", protectedTitles: [])
    // Only pending/failed items are cleared. Completed server renders stay available to be
    // discovered and downloaded after a long-running optimize or app relaunch.
    #expect(Set(removable) == ["1", "4"])
}

@Test func removableItemIDsNeverTouchesProtectedActiveDownloadEvenWhenCompleted() throws {
    // A completed item whose Part an active download is still pulling MUST survive: its title
    // is in `protectedTitles` for the full download lifetime, so deleting it (which removes the
    // optimized version + its file on the server) would yank the file out from under the transfer.
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Downloading Now [VisionPlay aaaa1111]","Status":{"state":"complete"}},
      {"id":"2","title":"Abandoned Leftover [VisionPlay bbbb2222]","Status":{"state":"complete"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let protected: Set<String> = ["Downloading Now [VisionPlay aaaa1111]"]
    let removable = q.removableItemIDs(marker: "[VisionPlay ", protectedTitles: protected)
    // Completed items are preserved whether or not they are currently protected.
    #expect(removable.isEmpty)
}

@Test func removableItemIDsNeverTouchesForeignClientItems() throws {
    let json = """
    {"MediaContainer":{"Item":[
      {"id":"1","title":"Ours Pending [VisionPlay aaaa1111]","Status":{"state":"pending"}},
      {"id":"2","title":"Ours Completed [VisionPlay bbbb2222]","Status":{"state":"complete"}},
      {"id":"3","title":"Someone Else's Optimize"},
      {"id":"4","title":"Another Client's Job","Status":{"state":"complete"}},
      {"id":"5","title":"Library Scan","Status":{"state":"running"}}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(BackgroundProcessingItems.self, from: json)
    let removable = q.removableItemIDs(marker: "[VisionPlay ", protectedTitles: [])
    // Only non-completed items carrying OUR marker are candidates — foreign jobs and completed
    // server renders are never touched.
    #expect(Set(removable) == ["1"])
}
