import Testing
import Foundation
@testable import PMSKit

/// #126: `EmbyPlayback.existingDownloadableVersions` enumerates the on-disk alternate MediaSources
/// (Emby "Convert Media" copies) that can be downloaded byte-for-byte, excluding the primary the
/// caller already offers. All fixtures use placeholder ids/titles (repo goes public).
@Suite("Emby existing versions (#126)")
struct EmbyExistingVersionsTests {
    private func response(_ json: String) throws -> EmbyPlaybackInfoResponse {
        try EmbyPlaybackInfoResponse.decode(from: Data(json.utf8))
    }

    /// Mirrors a real two-source item: an original mkv/hevc source plus a Convert-Media mp4/h264
    /// copy added "next to original files" as a second `File` MediaSource with its own Id.
    private let twoSourceJSON = """
    {
      "PlaySessionId": "sess1",
      "MediaSources": [
        { "Id": "mediasource_1", "Name": "Original", "Container": "mkv", "Protocol": "File",
          "SupportsDirectPlay": true, "Size": 421415383, "VideoCodec": "hevc",
          "MediaStreams": [ {"Type":"Video","Codec":"hevc","Width":640,"Height":368}, {"Type":"Audio","Codec":"mp3"} ] },
        { "Id": "mediasource_2", "Name": "Original - mobile", "Container": "mp4", "Protocol": "File",
          "SupportsDirectPlay": true, "Size": 1288179275, "VideoCodec": "h264", "Bitrate": 2146124,
          "MediaStreams": [ {"Type":"Video","Codec":"h264","Width":640,"Height":368}, {"Type":"Audio","Codec":"aac"} ] }
      ]
    }
    """

    @Test("Converted copy is offered as an existing version; the primary is excluded")
    func enumeratesNonPrimary() throws {
        let resp = try response(twoSourceJSON)
        let versions = EmbyPlayback.existingDownloadableVersions(response: resp, primaryMediaSourceId: "mediasource_1")
        #expect(versions.count == 1)
        let v = try #require(versions.first)
        #expect(v.mediaSourceId == "mediasource_2")
        #expect(v.container == "mp4")
        #expect(v.videoCodec == "h264")
        #expect(v.audioCodec == "aac")
        #expect(v.size == 1288179275)
        #expect(v.width == 640)
        #expect(v.bitrate == 2146124)
    }

    @Test("Whichever source is named primary is the one excluded")
    func excludesPrimaryEitherWay() throws {
        let resp = try response(twoSourceJSON)
        let v = EmbyPlayback.existingDownloadableVersions(response: resp, primaryMediaSourceId: "mediasource_2")
        // The mkv original is still enumerated (the UI gate shows it disabled, not hidden).
        #expect(v.map(\.mediaSourceId) == ["mediasource_1"])
    }

    @Test("Nil primary id offers every File source, order preserved")
    func nilPrimaryOffersAll() throws {
        let resp = try response(twoSourceJSON)
        let all = EmbyPlayback.existingDownloadableVersions(response: resp, primaryMediaSourceId: nil)
        #expect(all.map(\.mediaSourceId) == ["mediasource_1", "mediasource_2"])
    }

    @Test("Non-File protocol sources are excluded (a remote source isn't a static download)")
    func excludesNonFileProtocol() throws {
        let json = """
        { "PlaySessionId": "s", "MediaSources": [
          {"Id":"a","Container":"mkv","Protocol":"File","SupportsDirectPlay":true},
          {"Id":"remote","Container":"mp4","Protocol":"Http","SupportsDirectPlay":true}
        ] }
        """
        let v = try EmbyPlayback.existingDownloadableVersions(response: response(json), primaryMediaSourceId: "a")
        #expect(v.isEmpty)
    }

    @Test("Absent Protocol is treated as a local File")
    func absentProtocolTreatedAsFile() throws {
        let json = """
        { "PlaySessionId": "s", "MediaSources": [
          {"Id":"a","Container":"mkv","SupportsDirectPlay":true},
          {"Id":"b","Container":"mp4","SupportsDirectPlay":true}
        ] }
        """
        let v = try EmbyPlayback.existingDownloadableVersions(response: response(json), primaryMediaSourceId: "a")
        #expect(v.map(\.mediaSourceId) == ["b"])
    }

    @Test("Sources without an Id are skipped")
    func skipsSourcesWithoutId() throws {
        let json = """
        { "PlaySessionId": "s", "MediaSources": [
          {"Id":"a","Container":"mkv","SupportsDirectPlay":true},
          {"Container":"mp4","SupportsDirectPlay":true}
        ] }
        """
        let v = try EmbyPlayback.existingDownloadableVersions(response: response(json), primaryMediaSourceId: "a")
        #expect(v.isEmpty)
    }

    @Test("A single-source item yields no existing versions")
    func singleSourceYieldsNone() throws {
        let json = """
        { "PlaySessionId": "s", "MediaSources": [
          {"Id":"only","Container":"mp4","Protocol":"File","SupportsDirectPlay":true}
        ] }
        """
        let v = try EmbyPlayback.existingDownloadableVersions(response: response(json), primaryMediaSourceId: "only")
        #expect(v.isEmpty)
    }
}
