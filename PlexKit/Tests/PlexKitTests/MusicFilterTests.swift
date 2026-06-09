import Testing
import Foundation
@testable import PlexKit

// MARK: - Music detection (issue #15)
//
// Music libraries (Plex `artist` sections) and music items (artist/album/track) are
// hidden from the UI until a dedicated Plexamp-style experience exists. These tests pin
// the single source of truth for that detection: `Section.isMusic` / `MediaItem.isMusic`.

// MARK: - Section.isMusic

@Test func artistSectionIsMusic() {
    #expect(Section(key: "3", title: "Music", type: "artist").isMusic == true)
}

@Test func videoAndPhotoSectionsAreNotMusic() {
    #expect(Section(key: "1", title: "Movies", type: "movie").isMusic == false)
    #expect(Section(key: "2", title: "TV Shows", type: "show").isMusic == false)
    #expect(Section(key: "4", title: "Photos", type: "photo").isMusic == false)
}

@Test func decodedSectionsClassifyMusic() throws {
    let json = """
    {"MediaContainer":{"size":3,"Directory":[
      {"key":"1","title":"Movies","type":"movie"},
      {"key":"2","title":"TV Shows","type":"show"},
      {"key":"3","title":"Music","type":"artist"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(SectionsResponse.self, from: json)
    let sections = c.mediaContainer.directory
    #expect(sections[0].isMusic == false)
    #expect(sections[1].isMusic == false)
    #expect(sections[2].isMusic == true)
    // The browse filter drops only the music section, keeping video libraries.
    #expect(sections.filter { !$0.isMusic }.map(\.type) == ["movie", "show"])
}

// MARK: - MediaItem.isMusic

@Test func musicItemTypesAreMusic() {
    #expect(MediaItem(ratingKey: "1", title: "Radiohead", type: "artist").isMusic == true)
    #expect(MediaItem(ratingKey: "2", title: "OK Computer", type: "album").isMusic == true)
    #expect(MediaItem(ratingKey: "3", title: "Karma Police", type: "track").isMusic == true)
}

@Test func videoItemTypesAreNotMusic() {
    #expect(MediaItem(ratingKey: "10", title: "Arrival", type: "movie").isMusic == false)
    #expect(MediaItem(ratingKey: "11", title: "Breaking Bad", type: "show").isMusic == false)
    #expect(MediaItem(ratingKey: "12", title: "Season 1", type: "season").isMusic == false)
    #expect(MediaItem(ratingKey: "13", title: "Pilot", type: "episode").isMusic == false)
    #expect(MediaItem(ratingKey: "14", title: "Trailer", type: "clip").isMusic == false)
}

@Test func decodedMixedHubFiltersMusicItems() throws {
    // A mixed hub carrying both a movie and a track; the browse filter keeps only the
    // movie so music never reaches the video player.
    let json = """
    {"MediaContainer":{"Hub":[
      {"title":"Mixed","hubIdentifier":"mixed","Metadata":[
        {"ratingKey":"101","title":"Blade Runner","type":"movie"},
        {"ratingKey":"102","title":"Karma Police","type":"track"},
        {"ratingKey":"103","title":"OK Computer","type":"album"}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(HubsResponse.self, from: json)
    let items = c.mediaContainer.hub[0].metadata
    #expect(items.filter { !$0.isMusic }.map(\.ratingKey) == ["101"])
}
