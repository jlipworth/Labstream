import Foundation
import Testing
@testable import PMSKit

@Suite("Download existing-version option policy")
struct DownloadExistingVersionOptionPolicyTests {
    @Test("Plex options skip source media, label alternates, and disable non-playable versions")
    func plexOptions() throws {
        let source = Media(id: 1, width: 3840, height: 2160, videoCodec: "hevc", container: "mkv",
                           part: [Part(id: 10, key: "/library/parts/source", size: 9_000, container: "mkv")])
        let playable = Media(id: 2, bitrate: 8000, width: 1920, height: 1080, videoCodec: "h264", container: "mp4",
                             part: [Part(id: 11, key: "/library/parts/optimized", size: 1_500_000, container: "mp4")])
        let blocked = Media(id: 3, bitrate: 4000, width: 1280, height: 720, videoCodec: "mpeg2video", container: "mp4",
                            part: [Part(id: 12, key: "/library/parts/blocked", size: 500_000, container: "mp4")])

        let options = DownloadExistingVersionOptionPolicy.plexOptions(media: [source, playable, blocked], sourceMediaIndex: 0)
        #expect(options.count == 2)
        #expect(options[0].label == "1080p · H264 · 8.0 Mbps")
        #expect(options[0].detail?.hasPrefix("MP4") == true)
        #expect(options[0].playableOffline)
        #expect(options[0].target == .plexMediaIndex(1))
        #expect(!options[1].playableOffline)
        #expect(options[1].target == .plexMediaIndex(2))
    }

    @Test("Emby options use MediaSource targets and preserve disabled-not-hidden gate")
    func embyOptions() throws {
        let playable = EmbyPlayback.EmbyExistingVersion(
            mediaSourceId: "converted-mp4", name: "Converted", container: "mp4", videoCodec: "h264",
            audioCodec: "aac", size: 1_288_179_275, width: 640, height: 368, bitrate: 2_146_124,
            supportsDirectPlay: true)
        let blocked = EmbyPlayback.EmbyExistingVersion(
            mediaSourceId: "converted-unknown", name: "Still blocked", container: "mp4", videoCodec: nil,
            audioCodec: "aac", size: nil, width: nil, height: nil, bitrate: nil,
            supportsDirectPlay: true)

        let options = DownloadExistingVersionOptionPolicy.embyOptions(
            versions: [playable, blocked], durationMilliseconds: 4_800_000)
        #expect(options.count == 2)
        #expect(options[0].bitrateKbps == 2_147)
        #expect(options[0].label == "640×368 · H264 · 2.1 Mbps avg")
        #expect(options[0].detail?.hasPrefix("MP4") == true)
        #expect(options[0].playableOffline)
        #expect(options[0].target == .embyMediaSource(id: "converted-mp4", sizeBytes: 1_288_179_275))
        #expect(options[1].label == "Still blocked")
        #expect(!options[1].playableOffline)
    }

    @Test("Emby matching derives whole-file average instead of raw MediaSource bitrate")
    func embyDerivedAverageBitrate() {
        #expect(DownloadExistingVersionOptionPolicy.averageWholeFileBitrateKbps(
            sizeBytes: 1_000_000_000, durationMilliseconds: 1_000_000) == 8_000)

        let version = EmbyPlayback.EmbyExistingVersion(
            mediaSourceId: "converted", name: "Converted", container: "mp4", videoCodec: "h264",
            audioCodec: "aac", size: 1_000_000_000, width: 1920, height: 1080,
            bitrate: 99_000_000, supportsDirectPlay: true)
        let option = DownloadExistingVersionOptionPolicy.embyOptions(
            versions: [version], durationMilliseconds: 1_000_000)[0]
        #expect(option.bitrateKbps == 8_000)
        #expect(option.label == "1080p · H264 · 8.0 Mbps avg")
        #expect(!option.label.contains("99.0"))
    }

    @Test(arguments: [
        (Optional<Int>.none, Optional(1_000)),
        (Optional(1_000_000), Optional<Int>.none),
        (Optional(1_000_000), Optional(0)),
        (Optional(0), Optional(1_000)),
    ])
    func embyUnavailableFactsDoNotUseRawBitrate(size: Int?, duration: Int?) {
        let version = EmbyPlayback.EmbyExistingVersion(
            mediaSourceId: "converted", name: "Converted", container: "mp4", videoCodec: "h264",
            audioCodec: "aac", size: size, width: 1280, height: 720,
            bitrate: 88_000_000, supportsDirectPlay: true)
        let option = DownloadExistingVersionOptionPolicy.embyOptions(
            versions: [version], durationMilliseconds: duration)[0]
        #expect(option.bitrateKbps == nil)
        #expect(option.label == "720p · H264")
        #expect(!option.label.contains("Mbps"))
    }

    @Test("MediaSource id extraction prefers selected part then other media parts")
    func selectedMediaSourceID() {
        let selected = Part(id: 1, key: "/Videos/item/stream.mp4?MediaSourceId=ignored")
        let sourcePart = Part(id: 2, key: "/Items/item/media/source-a")
        let media = Media(id: 1, part: [sourcePart])
        #expect(DownloadExistingVersionOptionPolicy.selectedMediaSourceID(media: media, part: selected) == "source-a")
        #expect(DownloadExistingVersionOptionPolicy.selectedMediaSourceID(media: media, part: sourcePart) == "source-a")
        #expect(DownloadExistingVersionOptionPolicy.selectedMediaSourceID(media: nil, part: nil) == nil)
    }
}
