import Foundation
import Observation
import SwiftUI

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

    init(tickInterval: Duration = .milliseconds(50)) {
        self.tickInterval = tickInterval
    }

    /// Returns no lease, and performs no animation work, when Reduce Motion is enabled.
    @discardableResult
    func subscribe(reduceMotion: Bool) -> Subscription? {
        guard !reduceMotion else { return nil }
        let subscription = Subscription(id: UUID())
        subscriptions.insert(subscription)
        startIfNeeded()
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        guard subscriptions.remove(subscription) != nil else { return }
        guard subscriptions.isEmpty else { return }
        animationTask?.cancel()
        animationTask = nil
        phase = -1
    }

    /// Test/diagnostic visibility without exposing ticker ownership to callers.
    var subscriberCount: Int { subscriptions.count }
    var hasAnimationTask: Bool { animationTask != nil }

    private func startIfNeeded() {
        guard animationTask == nil, !subscriptions.isEmpty else { return }
        animationStartCount += 1
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
        // Twenty shared frames per second completes a sweep in roughly 1.4 seconds while
        // avoiding display-rate work for a deliberately subtle loading affordance.
        let next = phase + (1 / 14)
        phase = next > 1 ? -1 : next
    }
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
