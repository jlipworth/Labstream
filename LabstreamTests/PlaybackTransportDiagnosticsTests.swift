import Foundation
import Testing
@testable import Labstream

@MainActor
struct PlaybackTransportDiagnosticsTests {
    @Test(arguments: ["http://127.0.0.1:8000/a", "http://localhost:8000/a", "http://[::1]:8000/a"])
    func proxySamplesAreUnavailableBeforeAnAccessLogExists(address: String) throws {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.observedBitrateKbps = 4_000_000
        diagnostics.observedBitrateState = .active
        diagnostics.prepareTransport(url: try #require(URL(string: address)))
        #expect(diagnostics.usesLocalMediaProxy)
        #expect(diagnostics.observedBitrateState == .localProxy)
        #expect(diagnostics.observedBitrateLabel == "Unavailable (local proxy)")
        #expect(diagnostics.observedBitrateKbps == 0)
        #expect(diagnostics.currentObservedBitrateForAdaptationKbps == 0)
    }

    @Test func directReplacementDoesNotInheritProxyOrOldThroughput() throws {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.prepareTransport(url: URL(string: "http://127.0.0.1:8000/a"))
        diagnostics.prepareTransport(url: URL(string: "https://media.invalid/a"))
        #expect(!diagnostics.usesLocalMediaProxy)
        #expect(diagnostics.observedBitrateState == .unavailable)
        #expect(diagnostics.currentObservedBitrateForAdaptationKbps == 0)
        diagnostics.prepareTransport(url: nil)
        #expect(!diagnostics.usesLocalMediaProxy)
    }
}
