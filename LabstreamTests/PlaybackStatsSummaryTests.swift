import PMSKit
import Testing
@testable import Labstream

/// #331: the Stats signal chain presents existing diagnostics without changing their
/// meaning. Color/`converted` means only "the server changed this stream"; problems are only
/// real stalls; the expanded view keeps every row the old grid showed; Copy stays private.
@MainActor
struct PlaybackStatsSummaryTests {
    private func base() -> PlaybackDiagnostics {
        let d = PlaybackDiagnostics()
        d.sourceResolution = "3840×2160"
        d.sourceWidth = 3840
        d.sourceHeight = 2160
        d.videoCodec = "hevc"
        d.audioCodec = "truehd"
        d.sourceAudioProfile = "atmos"
        d.sourceAudioChannels = 8
        d.audioFormatText = "Dolby TrueHD Atmos 7.1"
        d.sourceBitrateKbps = 58_200
        d.connectionHost = "192.168.1.20:32400"
        return d
    }

    @Test func directPlayDeliversTheSourceUnchanged() {
        let d = base()
        d.playbackExplanation = .plex(decision: nil, maxVideoBitrateKbps: 0,
                                      subtitleBurnRequested: false, dolbyVisionGuardActive: false)
        d.bufferedAheadSeconds = 42
        let summary = PlaybackStatsSummary.make(d)
        #expect(summary.path == .direct)
        #expect(summary.reason == "Playing the original file")
        #expect(summary.source.video.value == "4K HEVC")
        #expect(summary.source.audio.value == "TrueHD Atmos")
        #expect(summary.device == summary.source)
        #expect(![summary.device.video, summary.device.hdr, summary.device.audio].contains { $0.converted })
        #expect(summary.bitrate.value == "58.2 Mbps")
        #expect(summary.bitrate.context == "Original")
        #expect(summary.buffer.value == "42 s")
        #expect(summary.buffer.context == "No stalls")
        #expect(!summary.buffer.isProblem)
        #expect(summary.connection.value == "Local")
    }

    @Test func encodeMarksOnlyServerConvertedStreamsFromRuntimeFacts() {
        let d = base()
        d.playbackExplanation = .plex(decision: nil, maxVideoBitrateKbps: 20_000,
                                      subtitleBurnRequested: false, dolbyVisionGuardActive: false,
                                      decisionUnavailableMeansTranscode: true)
        d.plexAudioDecision = "copy"
        d.targetBitrateKbps = 20_000
        d.indicatedBitrateKbps = 20_000
        d.deliveredWidth = 1920
        d.deliveredHeight = 1080
        d.applyRuntimeHDRProbe(.init(containsHDRVideo: false, transferFunction: nil,
                                     eligibleForHDRPlayback: true, sawVideoFormatDescriptions: true,
                                     videoCodecFourCC: "avc1"))
        d.stalls = 1
        let summary = PlaybackStatsSummary.make(d)
        #expect(summary.path == .encode)
        #expect(summary.reason == "Labstream requested a 20 Mbps quality cap")
        #expect(summary.device.video == .init(value: "1080p H.264", converted: true))
        #expect(summary.device.hdr == .init(value: "SDR", converted: true))
        // Plex says audio is copied: the device receives the source audio, uncolored.
        #expect(summary.device.audio == .init(value: "TrueHD Atmos", converted: false))
        #expect(summary.bitrate.value == "20 Mbps")
        #expect(summary.bitrate.context == "from 58.2")
        #expect(summary.buffer.context == "1 stall")
        #expect(summary.buffer.isProblem)
    }

    @Test func encodeBeforeRuntimeFactsDoesNotGuessTheOutput() {
        let d = base()
        d.playbackExplanation = .plex(decision: nil, maxVideoBitrateKbps: 8_000,
                                      subtitleBurnRequested: false, dolbyVisionGuardActive: false,
                                      decisionUnavailableMeansTranscode: true)
        d.plexAudioDecision = "transcode"
        let summary = PlaybackStatsSummary.make(d)
        #expect(summary.device.video == .init(value: "—", converted: true))
        #expect(summary.device.hdr == .init(value: "—", converted: true))
        #expect(summary.device.audio == .init(value: "Converted", converted: true))
    }

    @Test func audioOnlyCopyConvertsAudioAndReportsTheObservedFormat() {
        let d = base()
        d.playbackExplanation = .mediaBrowser(playMethod: .transcode,
                                              transcodeReasons: ["AudioCodecNotSupported"],
                                              maxVideoBitrateKbps: 0, dolbyVisionGuardActive: false)
        d.applyRuntimeHDRProbe(.init(containsHDRVideo: false, transferFunction: nil,
                                     eligibleForHDRPlayback: true, sawVideoFormatDescriptions: false,
                                     videoCodecFourCC: nil, audioCodecFourCC: "ec-3", audioChannels: 6))
        let summary = PlaybackStatsSummary.make(d)
        #expect(summary.path == .copy)
        #expect(summary.device.video == .init(value: "4K HEVC", converted: false))
        #expect(summary.device.audio == .init(value: "E-AC-3 5.1", converted: true))
        #expect(summary.audioTrack.context == "E-AC-3 5.1")
    }

    @Test func observedCopyThatLosesDolbyVisionIsFlagged() {
        let d = base()
        d.sourceHDR = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084", colorPrimaries: "bt2020", colorSpace: nil, colorRange: nil,
            bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: 8, level: nil, blCompatibilityID: 1,
                                              rpuPresent: nil, elPresent: nil, blPresent: nil),
            hdr10PlusPresent: nil, rangeDescribesHDR: true)
        d.playbackExplanation = PlaybackExplanation(
            lane: .directStream, evidence: [.init(reason: .videoCopy, provenance: .serverReported)])
        #expect(PlaybackStatsSummary.make(d).device.hdr == .init(value: "DV P8", converted: false))
        d.applyRuntimeHDRProbe(.init(containsHDRVideo: true, transferFunction: "PQ",
                                     eligibleForHDRPlayback: true, sawVideoFormatDescriptions: true,
                                     videoCodecFourCC: "hvc1"))
        #expect(PlaybackStatsSummary.make(d).device.hdr == .init(value: "HDR PQ", converted: true))
    }

    @Test func proxiedThroughputIsNotPresentedAsNetworkSpeed() {
        let d = base()
        d.playbackExplanation = PlaybackExplanation(
            lane: .directStream, evidence: [.init(reason: .videoCopy, provenance: .serverReported)])
        d.observedBitrateState = .localProxy
        #expect(PlaybackStatsSummary.make(d).connection.context == "Not measured")
        d.observedBitrateState = .active
        d.observedBitrateKbps = 18_400
        let connection = PlaybackStatsSummary.make(d).connection
        #expect(connection.context == "18.4 Mbps")
        #expect(connection.contextSymbol == "arrow.down")
    }

    @Test func routeIsNamedOnlyWhenTheHostProvesIt() {
        typealias Route = PlaybackConnectionRoute
        #expect(Route.classify(host: "Local file") == .downloaded)
        #expect(Route.classify(host: "192.168.1.20:32400") == .local)
        #expect(Route.classify(host: "10.0.0.5") == .local)
        #expect(Route.classify(host: "172.20.1.1:8096") == .local)
        #expect(Route.classify(host: "[fe80::1]:32400") == .local)
        #expect(Route.classify(host: "nas.local:8096") == .local)
        #expect(Route.classify(host: "192-168-1-20.0123abcd.plex.direct:32400") == .local)
        #expect(Route.classify(host: "198-51-100-7.0123abcd.plex.direct:32400") == .remote)
        #expect(Route.classify(host: "198.51.100.7:32400") == .remote)
        #expect(Route.classify(host: "media.example.com") == .unknown)
        #expect(Route.classify(host: "—") == .unknown)
    }

    @Test func expandedViewKeepsEveryLegacyStatsRow() {
        let d = base()
        d.decisionText = "video transcode · audio copy"
        d.indicatedAverageBitrateKbps = 17_000
        d.averageVideoBitrateKbps = 16_000
        d.sourceHDRFormat = .hdr10
        let summary = PlaybackStatsSummary.make(d)
        let labels = PlaybackStatsSummary.Section.allCases
            .flatMap { summary.groups(for: $0) }.flatMap(\.rows).map(\.label)
        for legacy in ["Mode", "Summary", "Decision", "Reasons", "Format", "Resolution", "Container",
                       "HDR", "Stream signal", "Display", "Source", "Target", "Observed",
                       "Indicated", "Indicated avg", "Avg video", "Dropped frames", "Stalls",
                       "Buffer ahead", "Keep up", "Route"] {
            #expect(labels.contains(legacy), "missing \(legacy)")
        }
        // The old Connection row showed host:port; the player UI now names only the route.
        let values = PlaybackStatsSummary.Section.allCases
            .flatMap { summary.groups(for: $0) }.flatMap(\.rows).map(\.value)
        #expect(!values.contains { $0.contains("192.168.1.20") })
    }

    @Test func copyTextOmitsServerAddressAndTrackTitles() {
        let d = base()
        let summary = PlaybackStatsSummary.make(
            d, tracks: .init(audioName: "Commentary track", subtitleName: "Forced signs",
                             subtitlesOff: false))
        let text = summary.copyText
        #expect(!text.contains("192.168.1.20"))
        #expect(!text.contains("Commentary track"))
        #expect(!text.contains("Forced signs"))
        #expect(text.contains("Server file: 4K HEVC"))
        #expect(text.contains("Dropped frames: 0"))
        #expect(summary.audioTrack.value == "Commentary track") // on screen only
    }

    @Test func bitrateAndBufferFormatting() {
        typealias F = PlaybackStatsSummary.Format
        #expect(F.bitrate(20_000) == "20 Mbps")
        #expect(F.bitrate(58_240) == "58.2 Mbps")
        #expect(F.bitrate(850) == "850 kbps")
        #expect(F.bitrate(0) == "—")
        #expect(F.bitrateNumber(58_200) == "58.2")
        #expect(F.seconds(9.54) == "9.5 s")
        #expect(F.seconds(42.4) == "42 s")
        #expect(F.resolutionName(width: 1920, height: 800) == "1080p")
        #expect(F.resolutionName(width: 3840, height: 1600) == "4K")
        #expect(F.resolutionName(width: 720, height: 480) == "480p")
    }
}
