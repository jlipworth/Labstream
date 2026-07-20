import Testing
@testable import PMSKit

@Suite("Offline active transfer percentage")
struct OfflineActiveTransferPercentageTests {
    @Test func weightsMultipleTransfersByBytes() {
        let percent = OfflineActiveTransferPercentage.integerPercent([
            .init(status: .downloading, transferredBytes: 50, trustworthyExpectedBytes: 100),
            .init(status: .downloading, transferredBytes: 900, trustworthyExpectedBytes: 900),
        ])
        #expect(percent == 95)
    }

    @Test func ignoresEveryNonTransferLifecyclePhase() {
        let percent = OfflineActiveTransferPercentage.integerPercent([
            .init(status: .queued, transferredBytes: 90, trustworthyExpectedBytes: 100),
            .init(status: .preparing, transferredBytes: 90, trustworthyExpectedBytes: 100),
            .init(status: .paused, transferredBytes: 90, trustworthyExpectedBytes: 100),
            .init(status: .failed, transferredBytes: 90, trustworthyExpectedBytes: 100),
            .init(status: .complete, transferredBytes: 100, trustworthyExpectedBytes: 100),
            .init(status: .unverified, transferredBytes: 100, trustworthyExpectedBytes: 100),
            .init(status: .downloading, transferredBytes: 25, trustworthyExpectedBytes: 100),
        ])
        #expect(percent == 25)
    }

    @Test func requiresAtLeastOneActiveByteTransfer() {
        #expect(OfflineActiveTransferPercentage.integerPercent([
            .init(status: .queued, transferredBytes: 0, trustworthyExpectedBytes: nil),
            .init(status: .complete, transferredBytes: 10, trustworthyExpectedBytes: 10),
        ]) == nil)
    }

    @Test func rejectsPartialAggregateWhenAnyActiveTotalIsUnknown() {
        #expect(OfflineActiveTransferPercentage.integerPercent([
            .init(status: .downloading, transferredBytes: 50, trustworthyExpectedBytes: 100),
            .init(status: .downloading, transferredBytes: 25, trustworthyExpectedBytes: nil),
        ]) == nil)
    }

    @Test func rejectsInvalidTotalsAndTransferredCounts() {
        #expect(OfflineActiveTransferPercentage.integerPercent([
            .init(status: .downloading, transferredBytes: 1, trustworthyExpectedBytes: 0),
        ]) == nil)
        #expect(OfflineActiveTransferPercentage.integerPercent([
            .init(status: .downloading, transferredBytes: -1, trustworthyExpectedBytes: 100),
        ]) == nil)
    }

    @Test func clampsOverrunAtOneHundredPercent() {
        #expect(OfflineActiveTransferPercentage.integerPercent([
            .init(status: .downloading, transferredBytes: 110, trustworthyExpectedBytes: 100),
        ]) == 100)
    }
}
