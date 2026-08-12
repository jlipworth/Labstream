import Testing
@testable import PMSKit

@Suite("Subtitle presentation policies")
struct SubtitlePresentationPolicyTests {
    @Test("soft and offline text routes never claim burn-in")
    func clientRenderedRoutes() {
        for route in [SubtitleDeliveryRoute.avFoundationSoft, .offlineTextSidecar, .off] {
            #expect(SubtitleBurnRiskPolicy.verdict(route: route,
                                                   isCurrentSelection: false,
                                                   serverEvidence: .unavailable) == .none)
        }
    }

    @Test("Emby encoded-selection profile proves burn before selection")
    func embyProfileEvidence() {
        #expect(SubtitleBurnRiskPolicy.verdict(route: .embyEncodedSelection,
                                               isCurrentSelection: false,
                                               serverEvidence: .unavailable) == .required)
    }

    @Test("Plex structured burn decision proves active burn")
    func plexDecisionEvidence() {
        #expect(SubtitleBurnRiskPolicy.verdict(
            route: .plexMetadata,
            isCurrentSelection: true,
            serverEvidence: .videoTranscode(subtitleDecision: "burn", reasons: [])) == .required)
        #expect(SubtitleBurnRiskPolicy.verdict(
            route: .plexMetadata,
            isCurrentSelection: false,
            serverEvidence: .videoTranscode(subtitleDecision: "burn", reasons: [])) == .uncertain)
    }

    @Test("Jellyfin subtitle-specific transcode reason proves active burn")
    func jellyfinDecisionEvidence() {
        #expect(SubtitleBurnRiskPolicy.verdict(
            route: .jellyfinMetadata,
            isCurrentSelection: true,
            serverEvidence: .videoTranscode(
                subtitleDecision: nil,
                reasons: ["SubtitleCodecNotSupported"])) == .required)
        #expect(SubtitleBurnRiskPolicy.verdict(
            route: .jellyfinMetadata,
            isCurrentSelection: true,
            serverEvidence: .videoTranscode(
                subtitleDecision: nil,
                reasons: ["ContainerNotSupported"])) == .uncertain)
    }

    @Test("confirmation is limited to a material lane change")
    func confirmationPolicy() {
        #expect(SubtitleBurnRiskPolicy.shouldConfirm(candidate: .required,
                                                     isAlreadySelected: false,
                                                     activeVideoIsTranscoding: false))
        #expect(!SubtitleBurnRiskPolicy.shouldConfirm(candidate: .required,
                                                      isAlreadySelected: true,
                                                      activeVideoIsTranscoding: false))
        #expect(!SubtitleBurnRiskPolicy.shouldConfirm(candidate: .required,
                                                      isAlreadySelected: false,
                                                      activeVideoIsTranscoding: true))
        #expect(!SubtitleBurnRiskPolicy.shouldConfirm(candidate: .uncertain,
                                                      isAlreadySelected: false,
                                                      activeVideoIsTranscoding: false))
    }

    @Test("style ownership remains distinct from burn risk")
    func styleCapability() {
        #expect(SubtitleStyleCapabilityPolicy.capability(
            route: .avFoundationSoft, burnVerdict: .none) == .nativeAVFoundationPreview)
        #expect(SubtitleStyleCapabilityPolicy.capability(
            route: .offlineTextSidecar, burnVerdict: .none) == .offlineSystemProfile)
        #expect(SubtitleStyleCapabilityPolicy.capability(
            route: .plexMetadata, burnVerdict: .uncertain) == .unavailableUntilDeliveryIsKnown)
        #expect(SubtitleStyleCapabilityPolicy.capability(
            route: .jellyfinMetadata, burnVerdict: .required)
            == .unavailableServerOrSourceRendered)
        #expect(SubtitleStyleCapabilityPolicy.capability(
            route: .avFoundationSoft, burnVerdict: .none, isImageOrAuthoredStyle: true)
            == .unavailableServerOrSourceRendered)
    }
}
