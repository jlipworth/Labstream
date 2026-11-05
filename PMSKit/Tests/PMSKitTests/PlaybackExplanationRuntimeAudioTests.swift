import Foundation
import Testing
@testable import PMSKit

@Suite("Playback explanation runtime audio conversion")
struct PlaybackExplanationRuntimeAudioTests {
    @Test func directStreamWithRuntimeAudioMismatchBecomesAudioOnlyTranscode() {
        let explanation = PlaybackExplanation.mediaBrowser(playMethod: .directStream,
                                                           transcodeReasons: ["ContainerNotSupported"],
                                                           maxVideoBitrateKbps: 0,
                                                           dolbyVisionGuardActive: false)
        let refined = explanation.refinedWithRuntimeAudioConversion()
        #expect(refined.lane == .audioOnlyTranscode)
        #expect(refined.headline == "Video is copied; audio is converted")
        #expect(refined.evidence.contains(.init(reason: .audioTranscode, provenance: .inferred)))
    }

    @Test func otherLanesAreUnchanged() {
        let explanation = PlaybackExplanation.mediaBrowser(playMethod: .directPlay,
                                                           transcodeReasons: [],
                                                           maxVideoBitrateKbps: 0,
                                                           dolbyVisionGuardActive: false)
        #expect(explanation.refinedWithRuntimeAudioConversion() == explanation)
    }

    @Test func runtimeAudioFamilyComparison() {
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: "dts", runtimeFourCC: "aac ") == true)
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: "truehd", runtimeFourCC: "ec-3") == true)
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: "ac3", runtimeFourCC: "ac-3") == false)
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: "eac3", runtimeFourCC: "ec-3") == false)
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: "aac", runtimeFourCC: "mp4a") == false)
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: nil, runtimeFourCC: "aac ") == nil)
        #expect(PlaybackAudioCodecFamily.runtimeDiffersFromSource(sourceCodec: "dts", runtimeFourCC: nil) == nil)
    }
}
