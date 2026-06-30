import Testing
@testable import PMSKit

@Suite("Download choice policy")
struct DownloadChoicePolicyTests {
    @Test("Diagnostic labels are stable")
    func diagnosticLabels() {
        #expect(DownloadChoicePolicy.diagnosticChoiceLabel(.original) == "original")
        #expect(DownloadChoicePolicy.diagnosticChoiceLabel(.existingVersion) == "existing_version")
        #expect(DownloadChoicePolicy.diagnosticChoiceLabel(.optimize(targetName: "720p 4 Mbps")) == "optimize:720p 4 Mbps")
        #expect(DownloadChoicePolicy.diagnosticChoiceLabel(.optimizeCompatible) == "optimize_compatible")
    }

    @Test("Persisted lanes preserve transfer semantics")
    func lanes() {
        #expect(DownloadChoicePolicy.downloadLane(for: .original) == .original)
        #expect(DownloadChoicePolicy.downloadLane(for: .existingVersion) == .original)
        #expect(DownloadChoicePolicy.downloadLane(for: .optimize(targetName: "1080p")) == .optimize)
        #expect(DownloadChoicePolicy.downloadLane(for: .optimizeCompatible) == .compatibleRemux)
    }

    @Test("Only existing versions are server prepared by choice alone")
    func serverPreparedFlag() {
        #expect(!DownloadChoicePolicy.isServerPreparedVersion(for: .original))
        #expect(DownloadChoicePolicy.isServerPreparedVersion(for: .existingVersion))
        #expect(!DownloadChoicePolicy.isServerPreparedVersion(for: .optimize(targetName: "1080p")))
        #expect(!DownloadChoicePolicy.isServerPreparedVersion(for: .optimizeCompatible))
    }
}
