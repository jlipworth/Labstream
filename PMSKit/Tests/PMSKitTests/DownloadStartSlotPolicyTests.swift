import Testing
@testable import PMSKit

@Suite("Download start slot policy")
struct DownloadStartSlotPolicyTests {
    @Test("Active rows reject duplicate starts before consulting stale slots")
    func activeRowsRejectDuplicates() {
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .queued, hasActiveSlot: false)
                == .rejectExistingActiveRow(status: .queued))
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .preparing, hasActiveSlot: true)
                == .rejectExistingActiveRow(status: .preparing))
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .downloading, hasActiveSlot: true)
                == .rejectExistingActiveRow(status: .downloading))
    }

    @Test("An active slot with a visible inactive row is still a duplicate")
    func activeSlotWithVisibleRowRejects() {
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .paused, hasActiveSlot: true)
                == .rejectAlreadyActive)
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .failed, hasActiveSlot: true)
                == .rejectAlreadyActive)
    }

    @Test("A stale active slot without a row is recoverable")
    func staleSlotWithoutRowRecovers() {
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: nil, hasActiveSlot: true)
                == .recoverStaleSlotAndAccept)
    }

    @Test("Inactive rows without active slots can start")
    func inactiveRowsCanStart() {
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: nil, hasActiveSlot: false) == .accept)
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .paused, hasActiveSlot: false) == .accept)
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .failed, hasActiveSlot: false) == .accept)
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .complete, hasActiveSlot: false) == .accept)
        #expect(DownloadStartSlotPolicy.decision(existingRecordStatus: .unverified, hasActiveSlot: false) == .accept)
    }
}
