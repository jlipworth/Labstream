import Testing
@testable import Labstream

struct FeedbackReportTests {
    @MainActor @Test func reportNamesTheHardwareModelAndADevelopmentInstall() throws {
        let model = try #require(DeviceEnvironment.modelIdentifier)
        #if os(macOS)
        // The Mac host runs natively: a real model code such as "Mac15,6".
        #expect(model.hasPrefix("Mac") || model.contains("Mac"))
        #else
        // Hosted tests run in the simulator.
        #expect(model.hasSuffix("(simulator)"))
        #endif
        let os = FeedbackReport.operatingSystem
        #expect(!os.contains("Version") && !os.contains("Build"))
        #expect(os.first?.isLetter == true && os.contains("."))
        // Hosted tests are debug builds.
        #expect(DeviceEnvironment.installSource == "Development (debug build)")
    }
}
