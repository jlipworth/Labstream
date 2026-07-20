import Foundation

/// Pure eligibility and byte-weighted calculation for the Mac Offline source-list percentage.
/// Only actual byte-transfer rows participate; estimates and partial known-total aggregates fail
/// closed so the sidebar never advertises misleading progress.
public enum OfflineActiveTransferPercentage {
    public struct Sample: Sendable, Equatable {
        public let status: DownloadStatus
        public let transferredBytes: Int
        public let trustworthyExpectedBytes: Int?

        public init(status: DownloadStatus,
                    transferredBytes: Int,
                    trustworthyExpectedBytes: Int?) {
            self.status = status
            self.transferredBytes = transferredBytes
            self.trustworthyExpectedBytes = trustworthyExpectedBytes
        }
    }

    public static func integerPercent(_ samples: some Sequence<Sample>) -> Int? {
        let active = samples.filter { $0.status == .downloading }
        guard !active.isEmpty else { return nil }

        var transferred: Int64 = 0
        var expected: Int64 = 0
        for sample in active {
            guard sample.transferredBytes >= 0,
                  let rowExpected = sample.trustworthyExpectedBytes,
                  rowExpected > 0 else { return nil }
            let (nextTransferred, transferredOverflow) = transferred.addingReportingOverflow(Int64(sample.transferredBytes))
            let (nextExpected, expectedOverflow) = expected.addingReportingOverflow(Int64(rowExpected))
            guard !transferredOverflow, !expectedOverflow else { return nil }
            transferred = nextTransferred
            expected = nextExpected
        }

        guard expected > 0 else { return nil }
        let fraction = min(1, max(0, Double(transferred) / Double(expected)))
        return Int(fraction * 100)
    }
}
