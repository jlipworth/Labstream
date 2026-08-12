#if DEBUG
import Testing
@testable import Labstream

@MainActor
struct DebugUITestLaunchConfigurationTests {
    @Test func disabledArgumentsDoNotSelectFixtureState() {
        let arguments = ["Labstream", "--ui-testing-backend", "emby",
                         "--ui-testing-fixture", "browse"]

        #expect(!DebugUITestLaunchConfiguration.isEnabled(in: arguments))
        #expect(DebugUITestLaunchConfiguration.initialBackend(in: arguments) == nil)
        #expect(DebugUITestLaunchConfiguration.fixtureKind(in: arguments) == nil)
    }

    @Test func browseFixtureParsesForEveryBackend() {
        for backend in MediaBackendKind.allCases {
            let arguments = ["Labstream", "--ui-testing", "--ui-testing-backend",
                             backend.rawValue, "--ui-testing-fixture", "browse"]

            #expect(DebugUITestLaunchConfiguration.isEnabled(in: arguments))
            #expect(DebugUITestLaunchConfiguration.initialBackend(in: arguments) == backend)
            #expect(DebugUITestLaunchConfiguration.fixtureKind(in: arguments) == .browse)
        }
    }

    @Test func enabledArgumentsUseSafeDefaultsForMissingOrUnknownValues() {
        #expect(DebugUITestLaunchConfiguration.initialBackend(in: ["Labstream", "--ui-testing"]) == .plex)
        #expect(DebugUITestLaunchConfiguration.initialBackend(
            in: ["Labstream", "--ui-testing", "--ui-testing-backend", "unknown"]) == .plex)
        #expect(DebugUITestLaunchConfiguration.fixtureKind(
            in: ["Labstream", "--ui-testing", "--ui-testing-fixture", "unknown"]) == nil)
    }
}
#endif
