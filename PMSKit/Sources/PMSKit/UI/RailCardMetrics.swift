import Foundation

/// Measured card widths for horizontal media rails (iPhone Duo design spec, global rule 7).
///
/// A rail shows `N` whole cards with their titles plus about 30% of the next card as the
/// overflow cue, sized from the rail's own viewport (the content region, which already excludes
/// the vertical bar's inset on whichever edge carries it):
///
///     w = (W − m − N·g) / (N + 0.3)
///
/// where `W` is the viewport width, `m` the leading rail margin and `g` the gutter. `N` ranges
/// over every count whose whole cards still fit at the family's minimum width; among those, the
/// count whose clamped width is closest to the family's nominal width wins (ties go to more
/// cards). On a ~376 pt folded viewport the formula falls just under the compact minimum, so the
/// minimum wins and the cue shrinks rather than dropping to two cards.
public enum RailCardMetrics {
    /// Card families with their clamps and nominal (authored) width.
    public struct Family: Equatable, Sendable {
        public let minimum: Double
        public let maximum: Double
        public let nominal: Double

        public init(minimum: Double, maximum: Double, nominal: Double) {
            self.minimum = minimum
            self.maximum = maximum
            self.nominal = min(max(nominal, minimum), maximum)
        }

        /// 2:3 posters at compact width (104–150 pt, authored 110 pt).
        public static let compactPoster = Family(minimum: 104, maximum: 150, nominal: 110)
        /// 2:3 posters at regular width (150–208 pt, authored 184 pt).
        public static let regularPoster = Family(minimum: 150, maximum: 208, nominal: 184)

        public static func poster(compact: Bool) -> Family {
            compact ? .compactPoster : .regularPoster
        }
    }

    public struct Metrics: Equatable, Sendable {
        /// Whole cards visible at rest.
        public let wholeCards: Int
        public let cardWidth: Double
        /// Width of the cut-off cue card visible at the trailing viewport edge at rest.
        public let cueWidth: Double
    }

    /// Fraction of the next card shown as the overflow cue.
    public static let cueFraction = 0.3

    public static func metrics(viewportWidth: Double,
                               margin: Double,
                               gutter: Double,
                               family: Family) -> Metrics {
        let width = viewportWidth.isFinite ? max(viewportWidth, 0) : 0
        let m = margin.isFinite ? max(margin, 0) : 0
        let g = gutter.isFinite ? max(gutter, 0) : 0

        func clampedWidth(_ count: Int) -> Double {
            let raw = (width - m - Double(count) * g) / (Double(count) + cueFraction)
            return min(max(raw, family.minimum), family.maximum)
        }

        // Every count whose whole cards fit at the minimum width.
        let fitting = Int(((width - m) / (family.minimum + g)).rounded(.down))
        let maxCount = max(fitting, 1)
        var best = (count: 1, width: clampedWidth(1))
        for count in 1...maxCount {
            let candidate = clampedWidth(count)
            let distance = abs(candidate - family.nominal)
            let bestDistance = abs(best.width - family.nominal)
            if distance < bestDistance - 0.0001 || abs(distance - bestDistance) <= 0.0001 {
                best = (count, candidate)
            }
        }
        let used = m + Double(best.count) * (best.width + g)
        let cue = max(0, min(width - used, best.width))
        return Metrics(wholeCards: best.count, cardWidth: best.width, cueWidth: cue)
    }
}
