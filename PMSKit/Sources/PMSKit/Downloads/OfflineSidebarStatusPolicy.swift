import Foundation

/// Compact, trustworthy source-list presentation for active Offline transfers (#251).
public enum OfflineSidebarStatusPolicy {
    public struct Presentation: Sendable, Equatable {
        public let activeCount: Int
        public let aggregatePercent: Int?

        public init(activeCount: Int, aggregatePercent: Int?) {
            self.activeCount = activeCount
            self.aggregatePercent = aggregatePercent
        }

        public var visibleText: String {
            if activeCount == 1, let aggregatePercent { return "\(aggregatePercent)%" }
            if let aggregatePercent { return "\(activeCount) active · \(aggregatePercent)%" }
            return "\(activeCount) active"
        }

        public var accessibilityValue: String {
            let noun = activeCount == 1 ? "transfer" : "transfers"
            if let aggregatePercent {
                return "\(activeCount) active \(noun), \(aggregatePercent) percent aggregate progress"
            }
            return "\(activeCount) active \(noun), total size unknown"
        }
    }

    public static func presentation(_ samples: some Sequence<OfflineActiveTransferPercentage.Sample>)
        -> Presentation? {
        let values = Array(samples)
        let activeCount = values.count { $0.status == .downloading }
        guard activeCount > 0 else { return nil }
        return Presentation(activeCount: activeCount,
                            aggregatePercent: OfflineActiveTransferPercentage.integerPercent(values))
    }
}
