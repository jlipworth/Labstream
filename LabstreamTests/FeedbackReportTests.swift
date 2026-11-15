import Testing
@testable import Labstream

struct FeedbackReportTests {
    @Test func simulatorReportsItsModelAndADevelopmentInstall() {
        // Hosted tests run in the simulator from a debug build.
        #expect(DeviceEnvironment.modelIdentifier?.hasSuffix("(simulator)") == true)
        #expect(DeviceEnvironment.installSource == "Development (debug build)")
    }
}
