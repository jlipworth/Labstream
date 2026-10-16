import Testing
import Foundation
@testable import PMSKit

// MARK: - Music detection (issue #15)
//
// Music libraries (Plex `artist` sections) and music items (artist/album/track) route to
// the dedicated music experience instead of the video browse/player paths. These tests pin
// the single source of truth for that detection: `Section.isMusic` / `MediaItem.isMusic`
// (plus `MediaItem.isMusicContainer` for artist → album → track navigation).

// MARK: - Section.isMusic

@Test func artistSectionIsMusic() {
    #expect(Section(key: "3", title: "Music", type: "artist").isMusic == true)
}

@Test func videoAndPhotoSectionsAreNotMusic() {
    #expect(Section(key: "1", title: "Movies", type: "movie").isMusic == false)
    #expect(Section(key: "2", title: "TV Shows", type: "show").isMusic == false)
    #expect(Section(key: "4", title: "Photos", type: "photo").isMusic == false)
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

@Test func musicContainersAreArtistsAndAlbumsOnly() {
    // Music navigation drills artist → albums → tracks via dedicated music views;
    // a track is the playable leaf, and video types never route there.
    #expect(MediaItem(ratingKey: "1", title: "Radiohead", type: "artist").isMusicContainer == true)
    #expect(MediaItem(ratingKey: "2", title: "OK Computer", type: "album").isMusicContainer == true)
    #expect(MediaItem(ratingKey: "3", title: "Karma Police", type: "track").isMusicContainer == false)
    #expect(MediaItem(ratingKey: "10", title: "Arrival", type: "movie").isMusicContainer == false)
}

