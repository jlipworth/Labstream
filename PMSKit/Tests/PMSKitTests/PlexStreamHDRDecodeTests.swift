import Testing
import Foundation
@testable import PMSKit

// GH #195 — Plex `Stream` HDR/color/Dolby Vision attribute decoding.
// Fixtures are sanitized: no real hostnames, tokens, titles, or ids.

/// Decode a single sanitized `Stream` JSON object. Wrapped in a `Part` because a bare
/// `Stream` type reference is ambiguous with `Foundation.Stream` in this file; the
/// `PlexStream` alias disambiguates.
private func decodeStream(_ json: String) throws -> PlexStream {
    let part = try JSONDecoder().decode(
        Part.self,
        from: """
        {"id":1,"key":"/library/parts/1","Stream":[\(json)]}
        """.data(using: .utf8)!)
    return try #require(part.streams?.first)
}

@Suite("Plex Stream HDR decode")
struct PlexStreamHDRDecodeTests {

    @Test func decodesDolbyVisionVideoStream() throws {
        let stream = try decodeStream("""
        {"id":1001,"streamType":1,"codec":"hevc","bitDepth":10,
         "colorPrimaries":"bt2020","colorRange":"tv","colorSpace":"bt2020nc","colorTrc":"smpte2084",
         "DOVIPresent":true,"DOVIProfile":8,"DOVILevel":6,"DOVIBLCompatID":1,
         "DOVIBLPresent":true,"DOVIELPresent":false,"DOVIRPUPresent":true}
        """)
        #expect(stream.bitDepth == 10)
        #expect(stream.colorTrc == "smpte2084")
        #expect(stream.doviPresent == true)
        #expect(stream.doviProfile == 8)
        #expect(stream.doviBLCompatID == 1)
        let hdr = try #require(stream.hdrMetadata)
        #expect(hdr.format == .dolbyVision)
        #expect(hdr.displayLabel == "Dolby Vision P8 (HDR10 fallback)")
    }

    @Test func decodesNumericBooleanDOVIFlags() throws {
        // Some PMS endpoints emit 1/0 instead of true/false for these attributes.
        let stream = try decodeStream("""
        {"id":1002,"streamType":1,"codec":"hevc",
         "DOVIPresent":1,"DOVIProfile":5,"DOVIBLCompatID":0,
         "DOVIBLPresent":"1","DOVIELPresent":"0","DOVIRPUPresent":1}
        """)
        #expect(stream.doviPresent == true)
        #expect(stream.doviBLPresent == true)
        #expect(stream.doviELPresent == false)
        #expect(stream.hdrMetadata?.format == .dolbyVision)
        #expect(stream.hdrMetadata?.displayLabel == "Dolby Vision P5 (no fallback)")
    }

    @Test func decodesHDR10VideoStream() throws {
        let stream = try decodeStream("""
        {"id":1003,"streamType":1,"codec":"hevc","bitDepth":10,
         "colorPrimaries":"bt2020","colorSpace":"bt2020nc","colorTrc":"smpte2084"}
        """)
        #expect(stream.hdrMetadata?.format == .hdr10)
        #expect(stream.hdrMetadata?.displayLabel == "HDR10 · PQ · BT.2020 · 10-bit")
    }

    @Test func plainSDRStreamStaysNilOrSDR() throws {
        let bt709 = try decodeStream("""
        {"id":1004,"streamType":1,"codec":"h264","bitDepth":8,"colorTrc":"bt709"}
        """)
        #expect(bt709.hdrMetadata?.format == .sdr)

        let bare = try decodeStream("""
        {"id":1005,"streamType":1,"codec":"h264"}
        """)
        #expect(bare.hdrMetadata == nil)
    }

    @Test func audioStreamNeverReportsHDRAndDecodesProfile() throws {
        let stream = try decodeStream("""
        {"id":1006,"streamType":2,"codec":"dca","channels":6,"profile":"ma","colorTrc":"smpte2084"}
        """)
        #expect(stream.profile == "ma")
        #expect(stream.hdrMetadata == nil)
    }

    @Test func legacyStreamWithoutNewKeysStillDecodes() throws {
        let stream = try decodeStream("""
        {"id":1007,"streamType":2,"codec":"aac","channels":2,"displayTitle":"English (AAC Stereo)"}
        """)
        #expect(stream.codec == "aac")
        #expect(stream.bitDepth == nil)
        #expect(stream.doviPresent == nil)
        #expect(stream.profile == nil)
    }
}
