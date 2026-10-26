import Foundation

/// iPhone/iPad Downloads composition (iPhone Duo design spec, Downloads; Resolved decision 5).
///
/// - Compact width: one column of rows ending one page margin before the content edge.
/// - Regular width, upright: the same rows capped at 560 pt and centred.
/// - Regular width, wide landscape (unfolded sideways): a Mail-style list + detail. The list
///   column takes about 45% of the content region (320–420 pt); in book the divider moves onto
///   the hinge so the split is 50/50 (system split behaviour).
///
/// Measured geometry only: never the pose name, the idiom or the screen.
public enum DownloadsLayoutPolicy {
    public enum Layout: Equatable, Sendable {
        /// Horizontal inset on each side of the row column (content-region space).
        case list(horizontalInset: Double)
        /// `listWidth` is the list column's width; `detailStart` is where the detail column
        /// begins (both from the content region's leading edge).
        case split(listWidth: Double, detailStart: Double)
    }

    public static let regularRowCap = 560.0
    public static let minimumSplitWidth = 700.0

    public static func layout(width: Double, height: Double, regularWidth: Bool,
                              pagePadding: Double,
                              hinge: (minX: Double, maxX: Double)? = nil) -> Layout {
        let w = width.isFinite ? max(width, 0) : 0
        let h = height.isFinite ? max(height, 0) : 0
        guard regularWidth else { return .list(horizontalInset: pagePadding) }
        if w >= minimumSplitWidth, w > h {
            if let hinge {
                let lo = min(hinge.minX, hinge.maxX)
                let hi = max(hinge.minX, hinge.maxX)
                if lo >= w * 0.3, hi <= w * 0.7 {
                    return .split(listWidth: lo, detailStart: hi)
                }
            }
            let list = min(max(w * 0.45, 320), 420)
            return .split(listWidth: list, detailStart: list)
        }
        return .list(horizontalInset: max(pagePadding, (w - regularRowCap) / 2))
    }
}
