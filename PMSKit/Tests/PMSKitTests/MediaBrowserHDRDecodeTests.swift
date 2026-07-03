import Testing
import Foundation
@testable import PMSKit

// GH #195 — Jellyfin/Emby MediaStream HDR field decoding and propagation into
// the playback source-metadata carriers. Fixtures are sanitized.

private func decodeMediaStream(_ json: String) throws -> MediaBrowserItemMediaStreamDto {
    try JSONDecoder().decode(MediaBrowserItemMediaStreamDto.self, from: json.data(using: .utf8)!)
}

@Suite("MediaBrowser MediaStream HDR decode")
struct MediaBrowserHDRDecodeTests {

    @Test func jellyfinDolbyVisionWithHDR10Fallback() throws {
        let stream = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,
         "ColorPrimaries":"bt2020","ColorSpace":"bt2020nc","ColorTransfer":"smpte2084","ColorRange":"tv",
         "VideoRange":"HDR","VideoRangeType":"DOVIWithHDR10","VideoDoViTitle":"DV Profile 8.1",
         "DvProfile":8,"DvLevel":6,"DvBlSignalCompatibilityId":1,
         "RpuPresentFlag":1,"ElPresentFlag":0,"BlPresentFlag":1}
        """)
        #expect(stream.videoRangeType == "DOVIWithHDR10")
        #expect(stream.dvProfile == 8)
        let hdr = try #require(stream.hdrMetadata)
        #expect(hdr.format == .dolbyVision)
        #expect(hdr.displayLabel == "Dolby Vision P8 (HDR10 fallback)")
    }

    @Test func jellyfinRangeTypeAloneClassifiesDV() throws {
        // Older servers may omit the Dv* numeric fields but still send VideoRangeType.
        let stream = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"HDR","VideoRangeType":"DOVIWithHLG"}
        """)
        let hdr = try #require(stream.hdrMetadata)
        #expect(hdr.format == .dolbyVision)
        #expect(hdr.displayLabel == "Dolby Vision (HLG fallback)")
    }

    @Test func jellyfinHDR10ViaRangeType() throws {
        let stream = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,
         "ColorPrimaries":"bt2020","ColorTransfer":"smpte2084",
         "VideoRange":"HDR","VideoRangeType":"HDR10"}
        """)
        #expect(stream.hdrMetadata?.format == .hdr10)
    }

    @Test func jellyfinHDR10PlusViaRangeTypeOrFlag() throws {
        let viaType = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"HDR","VideoRangeType":"HDR10Plus"}
        """)
        #expect(viaType.hdrMetadata?.format == .hdr10Plus)

        let viaFlag = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","ColorTransfer":"smpte2084","Hdr10PlusPresentFlag":true}
        """)
        #expect(viaFlag.hdrMetadata?.format == .hdr10Plus)
    }

    @Test func jellyfinGenericHDRRangeWithoutTypeIsUnknownHDR() throws {
        let stream = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"HDR"}
        """)
        #expect(stream.hdrMetadata?.format == .unknownHDR)
    }

    @Test func embyExtendedVideoTypeClassifies() throws {
        let hdr10Plus = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","ExtendedVideoType":"Hdr10Plus","ExtendedVideoSubType":"None"}
        """)
        #expect(hdr10Plus.hdrMetadata?.format == .hdr10Plus)

        let dovi = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DolbyVisionProfile5"}
        """)
        #expect(dovi.hdrMetadata?.format == .dolbyVision)

        let hlg = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","ExtendedVideoType":"HdrHlg"}
        """)
        #expect(hlg.hdrMetadata?.format == .hlg)
    }

    @Test func embyDoviProfileSubtypesFromLiveWireShape() throws {
        // Real Emby wire shape (live probe 2026-07-03): VideoRange="DolbyVision",
        // ExtendedVideoSubType="DoviProfile76"/"DoviProfile81" — the two digits are
        // profile + BL-compatibility id, NOT a two-digit profile number.
        let p76 = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,"ColorTransfer":"smpte2084",
         "VideoRange":"DolbyVision","ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DoviProfile76"}
        """)
        #expect(p76.hdrMetadata?.format == .dolbyVision)
        #expect(p76.hdrMetadata?.displayLabel == "Dolby Vision P7 (HDR10 fallback)")

        let p81 = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,"ColorTransfer":"smpte2084",
         "VideoRange":"DolbyVision","ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DoviProfile81"}
        """)
        #expect(p81.hdrMetadata?.displayLabel == "Dolby Vision P8 (HDR10 fallback)")

        let p5 = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"DolbyVision",
         "ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DoviProfile5"}
        """)
        #expect(p5.hdrMetadata?.displayLabel == "Dolby Vision P5")
    }

    @Test func embyDolbyVisionRangeAloneIsDVEvidence() throws {
        let stream = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"DolbyVision"}
        """)
        #expect(stream.hdrMetadata?.format == .dolbyVision)
    }

    @Test func sdrAndLegacyStreams() throws {
        let sdr = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"h264","VideoRange":"SDR","VideoRangeType":"SDR","BitDepth":8}
        """)
        #expect(sdr.hdrMetadata?.format == .sdr)

        let legacy = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"h264"}
        """)
        #expect(legacy.hdrMetadata == nil)

        let audio = try decodeMediaStream("""
        {"Index":1,"Type":"Audio","Codec":"eac3","Channels":6,"Profile":"Dolby Digital Plus + Dolby Atmos","VideoRange":"HDR"}
        """)
        #expect(audio.hdrMetadata == nil)
        #expect(audio.profile == "Dolby Digital Plus + Dolby Atmos")
    }
}

@Suite("MediaBrowser canonical stream HDR bridging")
struct MediaBrowserCanonicalHDRTests {

    @Test func canonicalStreamPreservesDVClassification() throws {
        let dto = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,"ColorTransfer":"smpte2084",
         "ColorPrimaries":"bt2020","VideoRange":"HDR","VideoRangeType":"DOVIWithHDR10",
         "DvProfile":8,"DvLevel":6,"DvBlSignalCompatibilityId":1}
        """)
        let canonical = try #require(dto.toCanonicalStream(fallbackID: 1))
        #expect(canonical.hdrMetadata?.format == .dolbyVision)
        #expect(canonical.hdrMetadata?.displayLabel == dto.hdrMetadata?.displayLabel)
    }

    @Test func canonicalStreamPreservesHDR10PlusAndEmbySubtypeDV() throws {
        let plus = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","ColorTransfer":"smpte2084","Hdr10PlusPresentFlag":true}
        """)
        #expect(plus.toCanonicalStream(fallbackID: 1)?.hdrMetadata?.format == .hdr10Plus)

        // Emby subtype-only DV (live wire shape) must survive the canonical bridge even
        // though the canonical Stream has no ExtendedVideoType field.
        let emby = try decodeMediaStream("""
        {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"DolbyVision",
         "ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DoviProfile76"}
        """)
        let canonical = try #require(emby.toCanonicalStream(fallbackID: 1))
        #expect(canonical.hdrMetadata?.displayLabel == "Dolby Vision P7 (HDR10 fallback)")
    }

    @Test func canonicalStreamCarriesAudioProfile() throws {
        let audio = try decodeMediaStream("""
        {"Index":1,"Type":"Audio","Codec":"dts","Channels":8,"Profile":"DTS-HD MA"}
        """)
        #expect(audio.toCanonicalStream(fallbackID: 1)?.profile == "DTS-HD MA")
    }
}

@Suite("MediaBrowser HDR carrier propagation")
struct MediaBrowserHDRCarrierTests {

    private func jellyfinSource() throws -> JellyfinMediaSourceInfo {
        try JSONDecoder().decode(JellyfinMediaSourceInfo.self, from: """
        {"Id":"ms1","Container":"mkv","SupportsDirectPlay":true,"SupportsDirectStream":true,
         "SupportsTranscoding":true,"Bitrate":25000000,"Width":3840,"Height":2160,
         "MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,"ColorTransfer":"smpte2084",
            "ColorPrimaries":"bt2020","VideoRange":"HDR","VideoRangeType":"HDR10"},
           {"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"Profile":"Dolby TrueHD + Dolby Atmos"}]}
        """.data(using: .utf8)!)
    }

    @Test func jellyfinSourceMetadataCarriesHDR() throws {
        let metadata = try jellyfinSource().playbackSourceMetadata()
        let hdr = try #require(metadata.hdr)
        #expect(hdr.format == .hdr10)
        #expect(metadata.audioProfile == "Dolby TrueHD + Dolby Atmos")
    }

    @Test func mediaBrowserCarrierBridgesHDR() throws {
        let jf = try jellyfinSource().playbackSourceMetadata()
        let bridged = MediaBrowserPlaybackSourceMetadata(jf)
        #expect(bridged.hdr?.format == .hdr10)
        #expect(bridged.audioProfile == "Dolby TrueHD + Dolby Atmos")
    }
}
