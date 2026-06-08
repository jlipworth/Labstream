import Testing
import Foundation
@testable import PlexKit

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

@Test func decodesHubWithoutMetadata() throws {
    let json = """
    {"MediaContainer":{"Hub":[
      {"title":"Empty Hub","hubIdentifier":"empty"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(HubsResponse.self, from: json)
    #expect(c.mediaContainer.hub[0].metadata.isEmpty)
    #expect(c.mediaContainer.hub[0].id == "empty")
}
