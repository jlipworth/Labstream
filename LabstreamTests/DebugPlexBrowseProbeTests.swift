#if DEBUG
import Testing
@testable import Labstream

@Suite("Debug Plex browse probe report")
struct DebugPlexBrowseProbeTests {
    @Test func completeEvidencePassesWithOptionalEmptyOnDeckAndNoContainer() {
        var evidence = DebugPlexBrowseProbe.Evidence()
        evidence.libraryCount = 1
        evidence.pageCount = 2
        evidence.pageTotal = 20
        evidence.repeatedPageOrderMatches = true
        evidence.pageIDsPresent = true
        evidence.alphabetApplicable = true
        evidence.alphabetCount = 4
        evidence.hubCount = 2
        evidence.hubItemCount = 3
        evidence.searchHubCount = 1
        evidence.searchItemCount = 1
        evidence.searchContainsSeedID = true
        evidence.onDeckCount = 0
        evidence.onDeckIDsPresent = true
        evidence.metadataIDMatches = true
        evidence.childrenApplicable = false
        evidence.childIDsPresent = true
        evidence.sessionUnchanged = true

        #expect(evidence.countCoherent)
        #expect(evidence.passes)
    }

    @Test func evidenceRejectsOrderCountIDAndSessionRegressions() {
        var evidence = DebugPlexBrowseProbe.Evidence()
        evidence.libraryCount = 1
        evidence.pageCount = 2
        evidence.pageTotal = 1
        evidence.repeatedPageOrderMatches = false
        evidence.pageIDsPresent = false
        evidence.hubCount = 1
        evidence.hubItemCount = 1
        evidence.searchHubCount = 1
        evidence.searchItemCount = 1
        evidence.searchContainsSeedID = false
        evidence.metadataIDMatches = false
        evidence.sessionUnchanged = false

        #expect(!evidence.countCoherent)
        #expect(!evidence.passes)
    }
}
#endif
