import Testing
@testable import PMSKit

@Suite("Emby download route plan")
struct EmbyDownloadRoutePlanTests {
    @Test("Non-transcode routes start transfer with correct session and range semantics")
    func transferRoutes() {
        #expect(EmbyDownloadRoutePlan.action(route: .original, choice: .optimize(targetName: "720p 4 Mbps")) == .startTransfer)
        #expect(EmbyDownloadRoutePlan.action(route: .compatibleRemux, choice: .optimizeCompatible) == .startTransfer)
        #expect(!EmbyDownloadRoutePlan.useServerSession(for: .original))
        #expect(EmbyDownloadRoutePlan.usesByteRangeCheckpoint(for: .original))
        #expect(EmbyDownloadRoutePlan.useServerSession(for: .compatibleRemux))
        #expect(!EmbyDownloadRoutePlan.usesByteRangeCheckpoint(for: .compatibleRemux))
    }

    @Test("Live transcode routes reroute optimizer choices into persistent convert jobs")
    func transcodeReroutesConvert() {
        #expect(EmbyDownloadRoutePlan.action(route: .transcode,
                                            choice: .optimize(targetName: "720p 4 Mbps"))
            == .rerouteConvert(targetName: "720p 4 Mbps"))
        #expect(EmbyDownloadRoutePlan.action(route: .transcode,
                                            choice: .optimizeCompatible)
            == .rerouteConvert(targetName: DownloadPresetPolicy.jellyfinDefaultDownloadPreset))
    }

    @Test("Static-only choices fail closed when they negotiate live transcode")
    func staticOnlyFailures() {
        #expect(EmbyDownloadRoutePlan.action(route: .transcode,
                                            choice: .existingVersion)
            == .fail(.convertedNotDirectlyDownloadable))
        #expect(EmbyDownloadRoutePlan.action(route: .transcode,
                                            choice: .original)
            == .fail(.originalNotDirectlyDownloadable))
        #expect(EmbyDownloadRoutePlan.FailureReason.convertedNotDirectlyDownloadable.userMessage
            == "Converted source not directly downloadable.")
        #expect(EmbyDownloadRoutePlan.FailureReason.originalNotDirectlyDownloadable.userMessage
            == "Original source no longer directly downloadable.")
    }

    @Test("Choice labels preserve route-specific user-visible semantics")
    func choiceLabels() {
        #expect(EmbyDownloadRoutePlan.diagnosticChoiceLabel(route: .original,
                                                           choice: .existingVersion,
                                                           choiceLabel: "existing_version") == "original")
        #expect(EmbyDownloadRoutePlan.diagnosticChoiceLabel(route: .compatibleRemux,
                                                           choice: .optimizeCompatible,
                                                           choiceLabel: "optimize_compatible") == "optimize_compatible")
        #expect(EmbyDownloadRoutePlan.diagnosticChoiceLabel(route: .transcode,
                                                           choice: .optimize(targetName: "720p 4 Mbps"),
                                                           choiceLabel: "optimize:720p 4 Mbps") == "optimize:720p 4 Mbps")
    }
}
