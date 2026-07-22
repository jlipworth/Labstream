import Testing
@testable import PMSKit

struct DownloadStorageSnapshotTests {
    @Test func provenanceKeepsDisplayAndCapMeaningsSeparate() {
        let snapshot = DownloadStorageSnapshot(
            durableMediaBytes: 100, durableSideAssetBytes: 20,
            heldOrResumeArtifactBytes: .known(30), liveOSTemporaryBytes: .unknown,
            expectedReservationBytes: .known(500))

        #expect(snapshot.displayBytes == nil)
        #expect(snapshot.capEnforcementBytes == 120)
        #expect(snapshot.hasUnknownPhysicalBytes)
        #expect(snapshot.components.last?.provenance == .expectedReservation)
        #expect(snapshot.components.last?.measurement == .known(500))
    }

    @Test func nonApplicableComponentsDoNotMakeKnownPhysicalTotalUnknown() {
        let snapshot = DownloadStorageSnapshot(
            durableMediaBytes: 100, durableSideAssetBytes: 20,
            heldOrResumeArtifactBytes: .notApplicable,
            liveOSTemporaryBytes: .notApplicable,
            expectedReservationBytes: .notApplicable)
        #expect(snapshot.displayBytes == 120)
        #expect(!snapshot.hasUnknownPhysicalBytes)
    }
}
