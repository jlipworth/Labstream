import Foundation
import Observation
import SwiftUI
#if DEBUG || PERFORMANCE_AUDIT
import os
#endif

/// One app-lifetime animation source for every visible artwork placeholder.
///
/// Individual skeletons lease the clock only while they are visible and motion is allowed.
/// The first lease starts one ticker; the final release cancels it. This avoids the previous
/// model where every poster created its own forever-repeating SwiftUI animation.
@MainActor
@Observable
final class ArtworkShimmerClock {
    struct Subscription: Hashable {
        fileprivate let id: UUID
    }

    private(set) var phase: CGFloat = -1

    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var subscriptions: Set<Subscription> = []
    @ObservationIgnored private var animationTask: Task<Void, Never>?
    @ObservationIgnored private(set) var animationStartCount = 0
    #if DEBUG || PERFORMANCE_AUDIT
    /// Per-ticker-session counters, logged when the last lease releases the ticker.
    @ObservationIgnored private(set) var sessionTickCount = 0
    @ObservationIgnored private var sessionLeaseCount = 0
    @ObservationIgnored private var sessionPeakSubscribers = 0
    @ObservationIgnored private var sessionStartedAt: ContinuousClock.Instant?
    private static let performanceLogger = Logger(subsystem: "org.labstream.Labstream",
                                                  category: "Performance")
    #endif

    init(tickInterval: Duration = .nanoseconds(16_666_667)) {
        self.tickInterval = tickInterval
    }

    /// Returns no lease, and performs no animation work, when Reduce Motion is enabled.
    @discardableResult
    func subscribe(reduceMotion: Bool) -> Subscription? {
        guard !reduceMotion else { return nil }
        let subscription = Subscription(id: UUID())
        subscriptions.insert(subscription)
        startIfNeeded()
        #if DEBUG || PERFORMANCE_AUDIT
        sessionLeaseCount += 1
        sessionPeakSubscribers = max(sessionPeakSubscribers, subscriptions.count)
        #endif
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        guard subscriptions.remove(subscription) != nil else { return }
        guard subscriptions.isEmpty else { return }
        animationTask?.cancel()
        animationTask = nil
        phase = -1
        #if DEBUG || PERFORMANCE_AUDIT
        logSessionEnd()
        #endif
    }

    /// Test/diagnostic visibility without exposing ticker ownership to callers.
    var subscriberCount: Int { subscriptions.count }
    var hasAnimationTask: Bool { animationTask != nil }

    private func startIfNeeded() {
        guard animationTask == nil, !subscriptions.isEmpty else { return }
        animationStartCount += 1
        #if DEBUG || PERFORMANCE_AUDIT
        sessionTickCount = 0
        sessionLeaseCount = 0
        sessionPeakSubscribers = 0
        sessionStartedAt = .now
        #endif
        let interval = tickInterval
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.advancePhase()
            }
        }
    }

    private func advancePhase() {
        // Keep the shared-clock efficiency win while updating at a display-smooth 60 Hz.
        // The sweep still takes roughly 1.4 seconds, matching the original animation.
        let next = phase + (1 / 42)
        phase = next > 1 ? -1 : next
        #if DEBUG || PERFORMANCE_AUDIT
        sessionTickCount += 1
        #endif
    }

    #if DEBUG || PERFORMANCE_AUDIT
    /// One privacy-safe line per ticker session: how long the 60 Hz clock ran, how many phase
    /// mutations (each invalidating every subscribed skeleton) it published, and how many leases.
    private func logSessionEnd() {
        let durationMs = sessionStartedAt.map { start in
            let elapsed = start.duration(to: .now).components
            return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        } ?? 0
        Self.performanceLogger.info("perf.shimmer_session duration_ms=\(durationMs, privacy: .public) ticks=\(self.sessionTickCount, privacy: .public) leases=\(self.sessionLeaseCount, privacy: .public) peak_subscribers=\(self.sessionPeakSubscribers, privacy: .public)")
        sessionStartedAt = nil
    }
    #endif
}

private struct ArtworkShimmerClockEnvironmentKey: EnvironmentKey {
    static let defaultValue: ArtworkShimmerClock? = nil
}

extension EnvironmentValues {
    /// Optional so isolated previews render a static skeleton instead of starting private work.
    var artworkShimmerClock: ArtworkShimmerClock? {
        get { self[ArtworkShimmerClockEnvironmentKey.self] }
        set { self[ArtworkShimmerClockEnvironmentKey.self] = newValue }
    }
}
