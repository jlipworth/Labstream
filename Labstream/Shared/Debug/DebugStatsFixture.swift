#if DEBUG
import Foundation
import PMSKit

/// Synthetic Stats scenarios for the player fixtures (#331).
///
/// The fixture plays a generated local clip, so its real diagnostics only ever describe a
/// downloaded direct play. `--ui-testing-stats-scenario direct|copy|encode` seeds
/// representative, entirely synthetic facts (no titles, hosts, or identifiers) and freezes the
/// 1 s sampler so screenshots and UI tests see a stable panel. `--ui-testing-stats-reset`
/// clears the remembered compact/expanded choice. Release builds cannot see this type.
@MainActor
enum DebugStatsFixture {
    nonisolated static let scenarioFlag = "--ui-testing-stats-scenario"
    nonisolated static let resetFlag = "--ui-testing-stats-reset"

    enum Scenario: String {
        case direct, copy, encode
    }

    static var scenario: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard DebugUITestLaunchConfiguration.fixtureKind == .player,
              let index = arguments.firstIndex(of: scenarioFlag),
              arguments.indices.contains(index + 1) else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }

    /// Call once per fixture launch, before the player is presented.
    static func prepareLaunch() {
        guard DebugUITestLaunchConfiguration.fixtureKind == .player,
              ProcessInfo.processInfo.arguments.contains(resetFlag) else { return }
        UserDefaults.standard.removeObject(forKey: PlaybackStatsView.sectionDefaultsKey)
    }

    static var tracks: PlaybackStatsSummary.Tracks? {
        switch scenario {
        case nil: nil
        case .direct: .init(audioName: "English", subtitleName: nil, subtitlesOff: true)
        case .copy: .init(audioName: "English", subtitleName: "English", subtitlesOff: false)
        case .encode: .init(audioName: "English", subtitleName: "English (SDH)", subtitlesOff: false)
        }
    }

    /// Seeds once the local item is ready, so the controller's own static facts land first.
    static func seedWhenReady(_ controller: PlaybackController) {
        guard let scenario else { return }
        Task { @MainActor [weak controller] in
            for _ in 0..<80 {
                guard let controller else { return }
                if controller.player.currentItem?.status == .readyToPlay {
                    apply(scenario, to: controller.diagnostics)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    static func apply(_ scenario: Scenario, to d: PlaybackDiagnostics) {
        d.isFixtureFrozen = true
        let dolbyVision = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084", colorPrimaries: "bt2020", colorSpace: "bt2020nc",
            colorRange: "tv", bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1,
                                              rpuPresent: true, elPresent: false, blPresent: true),
            hdr10PlusPresent: nil, rangeDescribesHDR: true)
        let hdr10 = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084", colorPrimaries: "bt2020", colorSpace: "bt2020nc",
            colorRange: "tv", bitDepth: 10, dolbyVision: nil, hdr10PlusPresent: nil,
            rangeDescribesHDR: true)

        d.sourceResolution = "3840×2160"
        d.sourceWidth = 3840
        d.sourceHeight = 2160
        d.videoCodec = "hevc"
        d.container = "mkv"
        d.videoFormatText = "HEVC"
        d.connectionHost = "192.0.2.10:32400"
        d.applyHDRDisplayEligibility(true)

        switch scenario {
        case .direct:
            setSourceHDR(dolbyVision, on: d)
            setSourceAudio(codec: "truehd", profile: "atmos", channels: 8, on: d)
            d.connectionHost = "10.0.0.20:32400"
            d.isTranscoding = false
            d.modeText = "Direct Play"
            d.decisionText = "direct play"
            d.plexAudioDecision = nil
            d.playbackExplanation = .plex(decision: nil, maxVideoBitrateKbps: 0,
                                          subtitleBurnRequested: false,
                                          dolbyVisionGuardActive: false)
            d.sourceBitrateKbps = 58_200
            d.targetBitrateKbps = 0
            d.indicatedBitrateKbps = 58_200
            d.averageVideoBitrateKbps = 55_900
            d.observedBitrateKbps = 61_400
            d.observedBitrateState = .active
            d.bufferedAheadSeconds = 42
            d.stalls = 0
            d.droppedFrames = 0
            d.likelyToKeepUp = true
            d.deliveredWidth = 3840
            d.deliveredHeight = 2160
            d.applyRuntimeHDRProbe(.init(containsHDRVideo: true, transferFunction: "PQ",
                                         eligibleForHDRPlayback: true,
                                         sawVideoFormatDescriptions: true,
                                         videoCodecFourCC: "dvh1",
                                         audioCodecFourCC: nil, audioChannels: nil))
        case .copy:
            setSourceHDR(hdr10, on: d)
            setSourceAudio(codec: "dca", profile: "ma", channels: 8, on: d)
            d.connectionHost = "10.0.0.20:8096"
            d.isTranscoding = false
            d.modeText = "Direct Stream"
            d.decisionText = "video copy · audio transcode"
            d.plexAudioDecision = nil
            d.playbackExplanation = .mediaBrowser(playMethod: .transcode,
                                                  transcodeReasons: ["AudioCodecNotSupported"],
                                                  maxVideoBitrateKbps: 0,
                                                  dolbyVisionGuardActive: false)
                .refinedWithRuntimeVideoCopy()
            d.sourceBitrateKbps = 41_700
            d.targetBitrateKbps = 0
            d.indicatedBitrateKbps = 42_300
            d.indicatedAverageBitrateKbps = 39_000
            d.averageVideoBitrateKbps = 38_100
            d.usesLocalMediaProxy = true
            d.observedBitrateKbps = 0
            d.observedBitrateState = .localProxy
            d.bufferedAheadSeconds = 24
            d.stalls = 0
            d.droppedFrames = 2
            d.likelyToKeepUp = true
            d.deliveredWidth = 3840
            d.deliveredHeight = 2160
            d.applyRuntimeHDRProbe(.init(containsHDRVideo: true, transferFunction: "PQ",
                                         eligibleForHDRPlayback: true,
                                         sawVideoFormatDescriptions: true,
                                         videoCodecFourCC: "hvc1",
                                         audioCodecFourCC: "ec-3", audioChannels: 6))
        case .encode:
            setSourceHDR(dolbyVision, on: d)
            setSourceAudio(codec: "truehd", profile: "atmos", channels: 8, on: d)
            d.connectionHost = "198.51.100.7:32400"
            d.isTranscoding = true
            d.modeText = "Transcoding"
            d.decisionText = "video transcode · audio transcode"
            d.plexAudioDecision = "transcode"
            d.playbackExplanation = .plex(decision: nil, maxVideoBitrateKbps: 20_000,
                                          subtitleBurnRequested: true,
                                          dolbyVisionGuardActive: false,
                                          decisionUnavailableMeansTranscode: true)
            d.sourceBitrateKbps = 58_200
            d.targetBitrateKbps = 20_000
            d.indicatedBitrateKbps = 20_000
            d.indicatedAverageBitrateKbps = 17_200
            d.averageVideoBitrateKbps = 16_800
            d.observedBitrateKbps = 18_400
            d.observedBitrateState = .active
            d.bufferedAheadSeconds = 9.5
            d.stalls = 1
            d.droppedFrames = 14
            d.likelyToKeepUp = true
            d.deliveredWidth = 1920
            d.deliveredHeight = 1080
            d.applyRuntimeHDRProbe(.init(containsHDRVideo: false, transferFunction: nil,
                                         eligibleForHDRPlayback: true,
                                         sawVideoFormatDescriptions: true,
                                         videoCodecFourCC: "avc1",
                                         audioCodecFourCC: "aac ", audioChannels: 6))
        }
    }

    private static func setSourceHDR(_ hdr: VideoHDRMetadata?, on d: PlaybackDiagnostics) {
        d.sourceHDR = hdr
        d.sourceHDRFormat = hdr?.format
        d.sourceHDRLabel = hdr?.displayLabel
    }

    private static func setSourceAudio(codec: String, profile: String, channels: Int,
                                       on d: PlaybackDiagnostics) {
        d.audioCodec = codec
        d.sourceAudioProfile = profile
        d.sourceAudioChannels = channels
        d.audioFormatText = AVFormatLabels.audioDisplayName(codec: codec, channels: channels,
                                                           profile: profile) ?? "—"
    }
}
#endif
