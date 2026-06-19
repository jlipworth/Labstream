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
