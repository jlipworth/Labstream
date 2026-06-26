import Testing
import Foundation
@testable import PMSKit

@Test func originalEligibilityAcceptsWholeFileDirectPlayableMp4() {
    let decision = DecisionResponse(generalDecisionCode: 1000,
                                    generalDecisionText: "Direct Play",
                                    partDecision: "directplay")
    let part = Part(id: 1, key: "/library/parts/1/file.mp4", file: nil,
                    size: 123, container: "mp4")

    let eligibility = OfflineDownloadDecision.originalEligibility(decision: decision, part: part)

    #expect(eligibility.canDownloadOriginal == true)
    #expect(eligibility.route == "original")
    #expect(eligibility.optimizeReason == nil)
    #expect(eligibility.container == "mp4")
}

@Test func originalEligibilityRoutesDirectStreamAudioTranscodeToOptimizer() {
    let decision = DecisionResponse(generalDecisionCode: 1001,
                                    generalDecisionText: "Transcode",
                                    partDecision: "transcode",
                                    videoDecision: "copy",
                                    audioDecision: "transcode")
    let part = Part(id: 1, key: "/library/parts/1/file.mp4", file: nil,
                    size: 123, container: "mp4")

    let eligibility = OfflineDownloadDecision.originalEligibility(decision: decision, part: part)

    #expect(decision.savesVideoEncode == true)
    #expect(eligibility.canDownloadOriginal == false)
    #expect(eligibility.route == "optimize")
    #expect(eligibility.optimizeReason == "audio_remux")
}

@Test func originalEligibilityRejectsNonLocalPlayableContainerEvenWhenDirect() {
    let decision = DecisionResponse(generalDecisionCode: 1000,
                                    generalDecisionText: "Direct Play",
                                    partDecision: "directplay")
    let part = Part(id: 1, key: "/library/parts/1/file.mkv", file: nil,
                    size: 123, container: "mkv")

    let eligibility = OfflineDownloadDecision.originalEligibility(decision: decision, part: part)

    #expect(eligibility.playsWholeFileDirectly == true)
    #expect(eligibility.localPlayableContainer == false)
    #expect(eligibility.canDownloadOriginal == false)
    #expect(eligibility.optimizeReason == "container_not_playable")
}

@Test func containerLabelFallsBackToFileExtension() {
    let part = Part(id: 1, key: "/library/parts/1", file: "/media/Movie.M4V",
                    size: nil, container: nil)

    #expect(OfflineDownloadDecision.containerLabel(part: part) == "m4v")
    #expect(OfflineDownloadDecision.isLocallyPlayableOriginal(part: part) == true)
}

// MARK: - #125 existing server-version offline gate

@Test func existingVersionPlayableForMp4H264() {
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mp4", videoCodec: "h264") == true)
}

@Test func existingVersionPlayableForMp4Hevc() {
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mp4", videoCodec: "hevc") == true)
    // HEVC aliases normalize and pass too.
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mov", videoCodec: "h265") == true)
}

@Test func existingVersionNotPlayableForMkv() {
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mkv", videoCodec: "h264") == false)
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "ts", videoCodec: "hevc") == false)
}

@Test func existingVersionFailsClosedOnUnknownContainer() {
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: nil, videoCodec: "h264") == false)
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "", videoCodec: "h264") == false)
}

@Test func existingVersionFailsClosedOnExoticOrUnknownCodec() {
    // Right container, wrong/undecodable codec.
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mp4", videoCodec: "av1") == false)
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mp4", videoCodec: "mpeg2video") == false)
    // Fail closed when the codec token is missing too (no preflight on this lane).
    #expect(OfflineDownloadDecision.existingVersionPlayableOffline(container: "mp4", videoCodec: nil) == false)
}

// MARK: - #120 offline playback routing

@Test func offlinePlaybackDecisionPrefersCompletedLocalFile() {
    let item = MediaItem(ratingKey: "101", title: "Movie", type: "movie")
    let local = URL(fileURLWithPath: "/tmp/visionplay-offline-101.mp4")
    let record = DownloadRecord(ratingKey: "101", title: "Movie", localURL: local,
                                progress: 1, status: .complete)

    let route = OfflinePlaybackDecision.route(for: item, backend: .plex, records: [record]) { $0 == local }

    #expect(route == .localFile(local))
}

@Test func offlinePlaybackDecisionFallsBackWhenFileIsMissing() {
    let item = MediaItem(ratingKey: "101", title: "Movie", type: "movie")
    let record = DownloadRecord(ratingKey: "101", title: "Movie",
                                localURL: URL(fileURLWithPath: "/tmp/missing.mp4"),
                                progress: 1, status: .complete)

    let route = OfflinePlaybackDecision.route(for: item, backend: .plex, records: [record]) { _ in false }

    #expect(route == .remoteStream)
}

@Test func offlinePlaybackDecisionUsesBackendScopedKeys() {
    let item = MediaItem(ratingKey: "abc", title: "Movie", type: "movie")
    let plexRecord = DownloadRecord(ratingKey: "abc", title: "Wrong backend",
                                    localURL: URL(fileURLWithPath: "/tmp/plex.mp4"),
                                    progress: 1, status: .complete)
    let jfURL = URL(fileURLWithPath: "/tmp/jellyfin.mp4")
    let jellyfinRecord = DownloadRecord(ratingKey: "jellyfin:abc", title: "Right backend",
                                        localURL: jfURL, progress: 1, status: .complete)

    let route = OfflinePlaybackDecision.route(for: item, backend: .jellyfin,
                                              records: [plexRecord, jellyfinRecord]) { $0 == jfURL }

    #expect(route == .localFile(jfURL))
}
