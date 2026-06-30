import Testing
@testable import PMSKit

@Suite("Plex download router")
struct PlexDownloadRouterTests {
    @Test("Download choices map to Plex intents")
    func choiceIntentMapping() {
        #expect(PlexDownloadRouter.intent(for: .original) == .original)
        #expect(PlexDownloadRouter.intent(for: .existingVersion) == .existingVersion)
        #expect(PlexDownloadRouter.intent(for: .optimize(targetName: "720p 4 Mbps")) ==
            .optimize(targetName: "720p 4 Mbps"))
        #expect(PlexDownloadRouter.intent(for: .optimizeCompatible) == .optimizeCompatible)
    }

    @Test("Original requires a concrete part and an AV preflight before static transfer")
    func originalRequiresPartAndPreflight() {
        #expect(PlexDownloadRouter.initialRoute(intent: .original,
                                                hasPart: false,
                                                compatibleFallbackTarget: "Original") ==
            .missingPart(reason: .noMediaPart))
        #expect(PlexDownloadRouter.initialRoute(intent: .original,
                                                hasPart: true,
                                                compatibleFallbackTarget: "Original") ==
            .preflightOriginal)
    }

    @Test("Existing Plex versions are static downloads that skip original preflight")
    func existingVersionIsStaticOrMissingPart() {
        #expect(PlexDownloadRouter.initialRoute(intent: .existingVersion,
                                                hasPart: false,
                                                compatibleFallbackTarget: "Original") ==
            .missingPart(reason: .noExistingVersionPart))
        #expect(PlexDownloadRouter.initialRoute(intent: .existingVersion,
                                                hasPart: true,
                                                compatibleFallbackTarget: "Original") ==
            .staticExistingVersion)
    }

    @Test("Plex optimize-compatible maps onto the regular optimizer target")
    func compatibleIntentUsesPlexOptimizerFallback() {
        #expect(PlexDownloadRouter.initialRoute(intent: .optimizeCompatible,
                                                hasPart: false,
                                                compatibleFallbackTarget: "Original quality compatible") ==
            .optimize(targetName: "Original quality compatible"))
    }

    @Test("Explicit optimize target is preserved")
    func explicitOptimizeTargetIsPreserved() {
        #expect(PlexDownloadRouter.initialRoute(intent: .optimize(targetName: "720p 4 Mbps"),
                                                hasPart: false,
                                                compatibleFallbackTarget: "Original") ==
            .optimize(targetName: "720p 4 Mbps"))
    }

    @Test("Original preflight failure falls back to optimizer")
    func originalPreflightFallback() {
        #expect(PlexDownloadRouter.routeAfterOriginalPreflight(passed: true,
                                                               fallbackOptimizeTarget: "Original") == .staticOriginal)
        #expect(PlexDownloadRouter.routeAfterOriginalPreflight(passed: false,
                                                               fallbackOptimizeTarget: "Original") == .optimizeFallback(targetName: "Original"))
    }
}
