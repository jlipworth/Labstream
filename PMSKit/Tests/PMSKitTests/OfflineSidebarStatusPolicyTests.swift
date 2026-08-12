import Testing
@testable import PMSKit

@Suite("Offline sidebar status")
struct OfflineSidebarStatusPolicyTests {
    @Test("single transfer may use its percent")
    func single() throws {
        let value = try #require(OfflineSidebarStatusPolicy.presentation([
            OfflineActiveTransferPercentage.Sample(status: .downloading,
                                                    transferredBytes: 25,
                                                    trustworthyExpectedBytes: 100),
        ]))
        #expect(value.visibleText == "25%")
        #expect(value.activeCount == 1)
    }

    @Test("multiple transfers label byte-weighted aggregate explicitly")
    func multiple() throws {
        let value = try #require(OfflineSidebarStatusPolicy.presentation([
            OfflineActiveTransferPercentage.Sample(status: .downloading,
                                                    transferredBytes: 50,
                                                    trustworthyExpectedBytes: 100),
            OfflineActiveTransferPercentage.Sample(status: .downloading,
                                                    transferredBytes: 900,
                                                    trustworthyExpectedBytes: 900),
        ]))
        #expect(value.visibleText == "2 active · 95%")
        #expect(value.accessibilityValue.contains("aggregate progress"))
    }

    @Test("unknown total keeps count and suppresses partial percent")
    func unknownTotal() throws {
        let value = try #require(OfflineSidebarStatusPolicy.presentation([
            OfflineActiveTransferPercentage.Sample(status: .downloading,
                                                    transferredBytes: 50,
                                                    trustworthyExpectedBytes: 100),
            OfflineActiveTransferPercentage.Sample(status: .downloading,
                                                    transferredBytes: 10,
                                                    trustworthyExpectedBytes: nil),
        ]))
        #expect(value.visibleText == "2 active")
        #expect(value.aggregatePercent == nil)
        #expect(value.accessibilityValue.contains("total size unknown"))
    }
}
