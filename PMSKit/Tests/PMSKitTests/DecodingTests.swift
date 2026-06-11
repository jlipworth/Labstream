import Testing
import Foundation
@testable import PMSKit

@Test func decodesMediaContainerSections() throws {
    let json = """
    {"MediaContainer":{"size":2,"Directory":[
      {"key":"1","title":"Movies","type":"movie"},
      {"key":"2","title":"TV Shows","type":"show"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(SectionsResponse.self, from: json)
    #expect(c.mediaContainer.directory.count == 2)
    #expect(c.mediaContainer.directory[0].title == "Movies")
    #expect(c.mediaContainer.directory[0].type == "movie")
}

@Test func decodesMediaContainerSectionsWhenDirectoryMissing() throws {
    let json = """
    {"MediaContainer":{"size":0}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(SectionsResponse.self, from: json)
    #expect(c.mediaContainer.directory.isEmpty)
}

@Test func decodesMetadataWithMediaPart() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Blade Runner","type":"movie","duration":9540000,"viewOffset":120000,
       "Media":[{"id":1,"Part":[{"id":9,"key":"/library/parts/9/file.mkv","duration":9540000}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let item = c.mediaContainer.metadata[0]
    #expect(item.ratingKey == "101")
    #expect(item.viewOffset == 120000)
    #expect(item.media?[0].part[0].key == "/library/parts/9/file.mkv")
}

@Test func decodesMetadataOptionalFields() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"42","title":"Arrival","type":"movie","year":2016,
       "summary":"Linguist meets aliens.","thumb":"/library/metadata/42/thumb/1",
       "art":"/library/metadata/42/art/1",
       "Media":[{"id":7,"bitrate":12000,"width":1920,"height":1080,
                 "videoCodec":"hevc","audioCodec":"dts","container":"mkv",
                 "Part":[{"id":3,"key":"/library/parts/3/file.mkv","file":"/data/Arrival.mkv","size":123456,"container":"mkv"}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let item = c.mediaContainer.metadata[0]
    #expect(item.year == 2016)
    #expect(item.summary == "Linguist meets aliens.")
    #expect(item.thumb == "/library/metadata/42/thumb/1")
    #expect(item.media?[0].videoCodec == "hevc")
    #expect(item.media?[0].part[0].file == "/data/Arrival.mkv")
    #expect(item.media?[0].part[0].size == 123456)
}

@Test func decodesMetadataWithChapters() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Blade Runner","type":"movie","duration":9540000,
       "Chapter":[
         {"id":1,"tag":"Opening","startTimeOffset":0,"endTimeOffset":600000},
         {"id":2,"tag":"Chapter 2","startTimeOffset":600000,"endTimeOffset":1200000,"thumb":"/library/metadata/101/chapter/2"}],
       "Media":[{"id":1,"Part":[{"id":9,"key":"/library/parts/9/file.mkv"}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let item = c.mediaContainer.metadata[0]
    #expect(item.chapters?.count == 2)
    #expect(item.chapters?[0].tag == "Opening")
    #expect(item.chapters?[0].startTimeOffset == 0)
    #expect(item.chapters?[1].endTimeOffset == 1200000)
    #expect(item.chapters?[1].thumb == "/library/metadata/101/chapter/2")
}

@Test func decodesChaptersWithUnreliableIDs() throws {
    // Regression for the "every chapter shows Chapter 1 / 0:00" bug (#26): real PMS data
    // often repeats a single id (here `0`) across all chapters, or omits it entirely.
    // The non-optional `id: Int` model used the raw id as `Identifiable.id`, so SwiftUI
    // collapsed the ForEach into N copies of the first row. The hardened model keeps each
    // chapter distinct and synthesizes a UNIQUE identity from the start offset.
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Dupe IDs","type":"movie","duration":9540000,
       "Chapter":[
         {"id":0,"startTimeOffset":0,"endTimeOffset":600000},
         {"id":0,"startTimeOffset":600000,"endTimeOffset":1200000},
         {"startTimeOffset":1200000,"endTimeOffset":1800000}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let chapters = try #require(c.mediaContainer.metadata[0].chapters)
    #expect(chapters.count == 3)
    // Offsets survive intact (the data was always fine — the bug was identity).
    #expect(chapters.map(\.startTimeOffset) == [0, 600000, 1200000])
    // The missing-id chapter still decodes (id is optional now).
    #expect(chapters[2].chapterID == nil)
    // Crucially: identities are UNIQUE despite duplicate/absent raw ids.
    let ids = Set(chapters.map(\.id))
    #expect(ids.count == 3)
}

@Test func decodesMetadataWithoutChapters() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"77","title":"No Chapters","type":"movie"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.metadata[0].chapters == nil)
}

@Test func decodesMetadataWithoutMedia() throws {
    let json = """
    {"MediaContainer":{"size":1,"Metadata":[
      {"ratingKey":"500","title":"Breaking Bad","type":"show"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let item = c.mediaContainer.metadata[0]
    #expect(item.media == nil)
    #expect(item.duration == nil)
    #expect(item.type == "show")
}

@Test func decodesEmptyMetadataContainer() throws {
    let json = """
    {"MediaContainer":{"size":0}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.metadata.isEmpty)
}

@Test func decodesPagedContainerTotalSize() throws {
    let json = """
    {"MediaContainer":{"size":200,"totalSize":454,"Metadata":[
      {"ratingKey":"1","title":"ABBA","type":"artist"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.totalSize == 454)
}

@Test func totalSizeAbsentOnUnpagedContainer() throws {
    let json = """
    {"MediaContainer":{"size":1,"Metadata":[
      {"ratingKey":"1","title":"ABBA","type":"artist"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.totalSize == nil)
}

@Test func decodesHubs() throws {
    let json = """
    {"MediaContainer":{"size":2,"Hub":[
      {"hubKey":"/hubs/home/continueWatching","title":"Continue Watching","type":"mixed",
       "hubIdentifier":"home.continue","size":1,
       "Metadata":[{"ratingKey":"101","title":"Blade Runner","type":"movie","viewOffset":120000}]},
      {"key":"/library/sections/1/recentlyAdded","title":"Recently Added","type":"movie",
       "hubIdentifier":"movie.recentlyadded","Metadata":[]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(HubsResponse.self, from: json)
    #expect(c.mediaContainer.hub.count == 2)
    #expect(c.mediaContainer.hub[0].title == "Continue Watching")
    #expect(c.mediaContainer.hub[0].metadata[0].ratingKey == "101")
    #expect(c.mediaContainer.hub[1].metadata.isEmpty)
}

@Test func decodesPartStreams() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Blade Runner","type":"movie",
       "Media":[{"id":1,"Part":[{"id":9,"key":"/library/parts/9/file.mkv",
         "Stream":[
           {"id":100,"streamType":1,"codec":"hevc","index":0,"displayTitle":"4K HEVC"},
           {"id":200,"streamType":2,"index":1,"codec":"dts","channels":6,"language":"English","languageTag":"en","languageCode":"eng","displayTitle":"English (DTS 5.1)","selected":true,"default":true},
           {"id":201,"streamType":2,"index":2,"codec":"aac","channels":2,"language":"French"},
           {"id":300,"streamType":3,"index":3,"language":"English","languageCode":"eng","forced":false,"displayTitle":"English (SRT)"},
           {"id":301,"streamType":3,"index":4,"language":"Spanish","forced":true,"selected":true}
         ]}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let part = c.mediaContainer.metadata[0].media![0].part[0]
    #expect(part.streams?.count == 5)
    #expect(part.videoStreams.count == 1)
    #expect(part.audioStreams.count == 2)
    #expect(part.subtitleStreams.count == 2)
    #expect(part.videoStreams[0].kind == .video)
    let eng = part.audioStreams[0]
    #expect(eng.codec == "dts")
    #expect(eng.channels == 6)
    #expect(eng.language == "English")
    #expect(eng.languageTag == "en")
    #expect(eng.languageCode == "eng")
    #expect(eng.selected == true)
    #expect(eng.isDefault == true)
    #expect(part.subtitleStreams[1].forced == true)
    #expect(part.subtitleStreams[1].kind == .subtitle)
}

@Test func decodesPartWithoutStreams() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Blade Runner","type":"movie",
       "Media":[{"id":1,"Part":[{"id":9,"key":"/library/parts/9/file.mkv"}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let part = c.mediaContainer.metadata[0].media![0].part[0]
    #expect(part.streams == nil)
    #expect(part.audioStreams.isEmpty)
    #expect(part.subtitleStreams.isEmpty)
    #expect(part.videoStreams.isEmpty)
}

@Test func decodesMetadataWithMarkers() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Episode","type":"episode",
       "Marker":[
         {"id":1,"type":"intro","startTimeOffset":12000,"endTimeOffset":75000},
         {"id":2,"type":"credits","startTimeOffset":2500000,"endTimeOffset":2700000,"final":true},
         {"type":"commercial","startTimeOffset":900000,"endTimeOffset":920000}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let item = c.mediaContainer.metadata[0]
    #expect(item.markers?.count == 3)
    let intro = item.markers![0]
    #expect(intro.kind == .intro)
    #expect(intro.startTimeOffset == 12000)
    #expect(intro.endTimeOffset == 75000)
    #expect(intro.id == "1")
    let credits = item.markers![1]
    #expect(credits.kind == .credits)
    #expect(credits.isFinal == true)
    let commercial = item.markers![2]
    #expect(commercial.kind == .commercial)
    #expect(commercial.markerID == nil)
    // synthesized id when PMS omits the marker id
    #expect(commercial.id == "commercial-900000")
}

@Test func decodesUnknownMarkerType() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"1","title":"X","type":"episode",
       "Marker":[{"id":9,"type":"recap","startTimeOffset":0,"endTimeOffset":1000}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.metadata[0].markers![0].kind == .other("recap"))
}

@Test func decodesMetadataWithoutMarkers() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"77","title":"No Markers","type":"movie"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.metadata[0].markers == nil)
}

@Test func decodesHubWithoutMetadata() throws {
    let json = """
    {"MediaContainer":{"Hub":[
      {"title":"Empty Hub","hubIdentifier":"empty"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(HubsResponse.self, from: json)
    #expect(c.mediaContainer.hub[0].metadata.isEmpty)
    #expect(c.mediaContainer.hub[0].id == "empty")
}
