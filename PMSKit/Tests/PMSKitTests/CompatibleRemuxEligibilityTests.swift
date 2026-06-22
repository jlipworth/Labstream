import Testing
import Foundation
@testable import PMSKit

// Decision core for the #83 "Original quality (compatible)" download lane: decide whether a
// Jellyfin/Emby source can be remuxed into an offline-playable MP4 while COPYING the video
// stream (preserving original video quality), transcoding only the audio/container as needed.
// Pure + privacy-safe (codec tokens only) so app UI, retry logic, and live probes share it.

@Test func remuxEligibleForHEVCWithAACCopiesVideoAndAudio() {
    let e = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "hevc", audioCodec: "aac", sourceContainer: "mkv")

    #expect(e.isEligible == true)
    #expect(e.copiesVideo == true)
    #expect(e.copiesAudio == true)
    #expect(e.needsAudioTranscode == false)
    #expect(e.isHEVC == true)            // drives the hvc1 tag fixup downstream
    #expect(e.codecSummary == "HEVC + AAC → MP4")
}

@Test func remuxEligibleForHEVCWithDTSTranscodesAudioOnly() {
    let e = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "hevc", audioCodec: "dts", sourceContainer: "mkv")

    #expect(e.isEligible == true)
    #expect(e.copiesVideo == true)
    #expect(e.copiesAudio == false)
    #expect(e.needsAudioTranscode == true)
    #expect(e.isHEVC == true)
    #expect(e.codecSummary == "HEVC + AAC → MP4")  // output audio is AAC after transcode
}

@Test func remuxEligibleForH264WithEAC3() {
    let e = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "h264", audioCodec: "eac3", sourceContainer: "mkv")

    #expect(e.isEligible == true)
    #expect(e.copiesVideo == true)
    #expect(e.copiesAudio == true)
    #expect(e.isHEVC == false)
    #expect(e.codecSummary == "H.264 + E-AC-3 → MP4")
}

@Test func remuxNotEligibleForUncopyableVideoCodec() {
    for codec in ["vp9", "av1", "mpeg2video", "vc1", "mpeg4"] {
        let e = OfflineDownloadDecision.compatibleRemuxEligibility(
            videoCodec: codec, audioCodec: "aac", sourceContainer: "mkv")
        #expect(e.isEligible == false, "\(codec) must not be remux-eligible")
        #expect(e.copiesVideo == false)
        #expect(e.codecSummary == nil)
    }
}

@Test func remuxNotEligibleWhenVideoCodecUnknown() {
    let e = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: nil, audioCodec: "aac", sourceContainer: "mkv")
    #expect(e.isEligible == false)
}

@Test func remuxNormalizesCodecCasingAndAliases() {
    // Jellyfin/Emby report codecs in mixed case; "h265"/"x265" are HEVC aliases seen in the wild.
    let upper = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "HEVC", audioCodec: "AAC", sourceContainer: "MKV")
    #expect(upper.isEligible == true)
    #expect(upper.isHEVC == true)

    let alias = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "h265", audioCodec: "ac3", sourceContainer: "mkv")
    #expect(alias.isEligible == true)
    #expect(alias.isHEVC == true)
    #expect(alias.copiesAudio == true)
}

@Test func remuxOfferedOnlyWhenOriginalNotAlreadyPlayable() {
    // The lane is meaningless when the raw container is ALREADY locally playable (mp4/m4v/mov):
    // that source should use the byte-for-byte original lane instead. `shouldOffer` encodes that.
    let mkv = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "hevc", audioCodec: "aac", sourceContainer: "mkv")
    #expect(mkv.shouldOffer(originalLocallyPlayable: false) == true)
    #expect(mkv.shouldOffer(originalLocallyPlayable: true) == false)

    let ineligible = OfflineDownloadDecision.compatibleRemuxEligibility(
        videoCodec: "av1", audioCodec: "aac", sourceContainer: "mkv")
    #expect(ineligible.shouldOffer(originalLocallyPlayable: false) == false)
}

@Test func remuxEligibilityFromPartDerivesCodecsFromStreams() {
    // Convenience entry that reads codecs off a Part's video/audio streams.
    let part = Part(id: 1, key: "/x/media/7", file: nil, size: 9_000, container: "mkv",
                    streams: [
                        Stream(id: 10, streamType: 1, codec: "hevc"),       // video
                        Stream(id: 11, streamType: 2, codec: "dts"),        // audio
                    ])
    let e = OfflineDownloadDecision.compatibleRemuxEligibility(part: part)
    #expect(e.isEligible == true)
    #expect(e.copiesVideo == true)
    #expect(e.needsAudioTranscode == true)
    #expect(e.isHEVC == true)
}
