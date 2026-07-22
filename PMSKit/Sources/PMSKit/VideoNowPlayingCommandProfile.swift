import Foundation

/// Pure command intervals consumed by native video system-media publishers.
///
/// The process-wide iOS/macOS publisher historically advertises both common intervals in both
/// directions while using a platform-selected fallback. The scoped visionOS publisher advertises
/// one direction-specific interval. Keeping those existing contracts explicit prevents a shared
/// command implementation from silently normalizing platform behavior.
public struct VideoNowPlayingCommandProfile: Equatable, Sendable {
    public let backwardFallbackSeconds: Double
    public let forwardFallbackSeconds: Double
    public let advertisedBackwardIntervals: [Double]
    public let advertisedForwardIntervals: [Double]

    public init(backwardFallbackSeconds: Double,
                forwardFallbackSeconds: Double,
                advertisedBackwardIntervals: [Double],
                advertisedForwardIntervals: [Double]) {
        self.backwardFallbackSeconds = backwardFallbackSeconds
        self.forwardFallbackSeconds = forwardFallbackSeconds
        self.advertisedBackwardIntervals = advertisedBackwardIntervals
        self.advertisedForwardIntervals = advertisedForwardIntervals
    }

    public static func processWide(fallbackSeconds: Double) -> Self {
        .init(backwardFallbackSeconds: fallbackSeconds,
              forwardFallbackSeconds: fallbackSeconds,
              advertisedBackwardIntervals: [10, 30],
              advertisedForwardIntervals: [10, 30])
    }

    public static let playbackScoped = Self(
        backwardFallbackSeconds: 10,
        forwardFallbackSeconds: 30,
        advertisedBackwardIntervals: [10],
        advertisedForwardIntervals: [30])
}
