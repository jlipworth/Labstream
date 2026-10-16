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

    @Test func playerFixtureAspectParsesOnlyForThePlayerFixture() {
        let base = ["Labstream", "--ui-testing", "--ui-testing-fixture", "player"]
        #expect(DebugUITestLaunchConfiguration.playerFixtureAspect(in: base) == .widescreen)
        #expect(DebugUITestLaunchConfiguration.playerFixtureAspect(
            in: base + ["--ui-testing-player-aspect", "239x100"]) == .scope)
        #expect(DebugUITestLaunchConfiguration.playerFixtureAspect(
            in: base + ["--ui-testing-player-aspect", "4x3"]) == .academy)
        #expect(DebugUITestLaunchConfiguration.playerFixtureAspect(
            in: base + ["--ui-testing-player-aspect", "bogus"]) == .widescreen)
        #expect(DebugUITestLaunchConfiguration.playerFixtureAspect(
            in: ["Labstream", "--ui-testing", "--ui-testing-fixture", "browse",
                 "--ui-testing-player-aspect", "4x3"]) == .widescreen)
        for aspect in DebugUITestLaunchConfiguration.PlayerFixtureAspect.allCases {
            let size = aspect.encodedSize
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
        }
    }
}
#endif
