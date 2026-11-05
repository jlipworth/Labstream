import Foundation

/// One storage rule for every gate (downloads overhaul P5.1): the start, continuation and
/// storage-full park preflights (free space), and the cap projection used by the sheet, the season
/// commit and every manager start.
public enum DownloadStorageAdmissionPolicy {
    public static let headroomBytes: Int64 = DownloadDiskSpacePolicy.startHeadroomBytes

    /// Additional free space a transfer still needs, from its physical timeline (P5.1, B01):
    /// - bytes already on disk (the durable checkpoint and held bodies) are never charged again;
    /// - the network still has to deliver `expected − checkpoint − held`;
    /// - appending copies one body onto the partial before deleting it, so the largest body that
    ///   will be appended is charged once more as the duplication peak;
    /// - side assets still to be cached, and the fixed headroom.
    /// An unknown expected size charges only the peak, side assets and headroom (reactive ENOSPC
    /// handling remains the backstop). A checkpoint larger than the expected size is discarded by
    /// the range start, so it shields nothing.
    public static func requiredAdditionalFreeBytes(
        expectedBytes: Int?,
        durableCheckpointBytes: Int?,
        heldBodyBytes: Int = 0,
        largestPendingAppendBytes: Int = 0,
        futureSideAssetBytes: Int = 0,
        headroomBytes: Int64 = headroomBytes
    ) -> Int64 {
        let peak = Int64(max(0, largestPendingAppendBytes))
        let sideAssets = Int64(max(0, futureSideAssetBytes))
        guard let expectedBytes, expectedBytes > 0 else { return peak + sideAssets + headroomBytes }
        let expected = Int64(expectedBytes)
        var onDisk = Int64(max(0, durableCheckpointBytes ?? 0))
        if onDisk > expected { onDisk = 0 }
        onDisk += Int64(max(0, heldBodyBytes))
        let remainingNetwork = max(0, expected - onDisk)
        return remainingNetwork + peak + sideAssets + headroomBytes
    }

    /// Physical admission shared by transfer preflights and checkpoint handoffs. Reservations
    /// charge other in-progress copies; the caller's requirement already includes headroom.
    /// An unavailable measurement preserves the existing fail-open behavior.
    public static func hasPhysicalSpace(requiredBytes: Int64, availableBytes: Int64?,
                                        reservedBytes: Int64 = 0) -> Bool {
        guard let availableBytes else { return true }
        return availableBytes >= requiredBytes && availableBytes - requiredBytes >= max(0, reservedBytes)
    }

    /// What one row contributes to the storage cap.
    public struct CapRow: Sendable, Equatable {
        public let id: String
        /// Bytes the row holds on disk now: the larger of its durable checkpoint and `bytes`.
        public let retainedBytes: Int
        public let sideAssetBytes: Int
        /// Known total media estimate, or nil when the size is unknown.
        public let estimatedTotalBytes: Int?
        /// Admitted, preparing on the server, or transferring: its remaining bytes are reserved.
        public let reservesRemaining: Bool

        public init(id: String, retainedBytes: Int, sideAssetBytes: Int,
                    estimatedTotalBytes: Int?, reservesRemaining: Bool) {
            self.id = id
            self.retainedBytes = max(0, retainedBytes)
            self.sideAssetBytes = max(0, sideAssetBytes)
            self.estimatedTotalBytes = estimatedTotalBytes
            self.reservesRemaining = reservesRemaining
        }

        /// Counted once (B24): what it holds, plus the known remaining bytes of active work.
        public var contribution: Int {
            var total = retainedBytes + sideAssetBytes
            if reservesRemaining, let estimatedTotalBytes {
                total += max(0, estimatedTotalBytes - retainedBytes)
            }
            return total
        }
    }

    public static func capUsage(_ rows: [CapRow]) -> Int {
        rows.reduce(0) { $0 + $1.contribution }
    }

    /// Usage if a download of `addingBytes` starts. A retry or restart replaces its own row's
    /// contribution instead of adding to it (B24). Unknown sizes project the current usage only.
    public static func capProjection(rows: [CapRow], addingBytes: Int?,
                                     replacingRowID: String?) -> Int {
        let others = rows.filter { $0.id != replacingRowID }
        let replaced = rows.first { $0.id == replacingRowID }
        let base = capUsage(others)
        guard let addingBytes, addingBytes > 0 else { return base + (replaced?.contribution ?? 0) }
        // The new estimate covers the media; keep the replaced row's cached side assets.
        return base + addingBytes + (replaced?.sideAssetBytes ?? 0)
    }

    /// The cap verdict for a start: nil when it fits (or the cap is unlimited, or the size is
    /// unknown), otherwise the user-facing rejection.
    public static func capRejection(rows: [CapRow], addingBytes: Int?, replacingRowID: String?,
                                    limitBytes: Int) -> String? {
        guard limitBytes > 0, let addingBytes, addingBytes > 0 else { return nil }
        let current = capProjection(rows: rows, addingBytes: nil, replacingRowID: replacingRowID)
            - (rows.first { $0.id == replacingRowID }?.contribution ?? 0)
        let projected = capProjection(rows: rows, addingBytes: addingBytes,
                                      replacingRowID: replacingRowID)
        guard projected > limitBytes else { return nil }
        return DownloadStorageLimitPolicy.rejectionMessage(
            adding: projected - current, currentBytes: current, limitBytes: limitBytes)
    }
}
