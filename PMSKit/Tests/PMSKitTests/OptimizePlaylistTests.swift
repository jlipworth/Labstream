import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlex",
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
    // targetTagID is the SERVER-RESOLVED id passed in — NOT a hardcoded enum default.
    #expect(v("Item[targetTagID]") == "7")
    #expect(v("Item[MediaSettings][maxVideoBitrate]") == "8000")
    #expect(v("Item[MediaSettings][videoResolution]") == "1920x1080")
    #expect(v("Item[locationID]") == "-1")
    #expect(v("Item[Policy][scope]") == "all")
    #expect(v("Item[Location][uri]")?.contains("/library/metadata/101") == true)
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func createOnPlaylistSupportsCustomDeviceProfileQuality() {
    let r = OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", sourceURI: "library://section/item/%2Flibrary%2Fmetadata%2F101",
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
