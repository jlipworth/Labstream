import Testing
@testable import Labstream

struct FeedbackReportTests {
    @Test func reportNamesTheHardwareModelAndADevelopmentInstall() throws {
        let model = try #require(DeviceEnvironment.modelIdentifier)
        #if os(macOS)
        // The Mac host runs natively: a real model code such as "Mac15,6".
        #expect(model.hasPrefix("Mac") || model.contains("Mac"))
        #else
        // Hosted tests run in the simulator.
        #expect(model.hasSuffix("(simulator)"))
        #endif
        // Hosted tests are debug builds.
        #expect(DeviceEnvironment.installSource == "Development (debug build)")
    }
}
