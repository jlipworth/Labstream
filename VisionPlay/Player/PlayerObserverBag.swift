import Foundation
import AVFoundation

/// Small ownership bag for AVPlayer-related observation tokens.
///
/// The callbacks remain in the playback controllers; this type only centralizes token storage
/// and idempotent teardown so KVO, NotificationCenter, periodic time observers, and timers are
/// not each removed with bespoke optional fields.
@MainActor
final class PlayerObserverBag {
    private weak var player: AVPlayer?
    private var keyValueObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObservers: [Any] = []
    private var timers: [Timer] = []

    init(player: AVPlayer? = nil) {
        self.player = player
    }

    var isEmpty: Bool {
        keyValueObservations.isEmpty &&
            notificationObservers.isEmpty &&
            timeObservers.isEmpty &&
            timers.isEmpty
    }

    @discardableResult
    func store(_ observation: NSKeyValueObservation) -> NSKeyValueObservation {
        keyValueObservations.append(observation)
        return observation
    }

    @discardableResult
    func storeNotification(_ observer: NSObjectProtocol) -> NSObjectProtocol {
        notificationObservers.append(observer)
        return observer
    }

    @discardableResult
    func storeTimeObserver(_ observer: Any) -> Any {
        timeObservers.append(observer)
        return observer
    }

    @discardableResult
    func storeTimer(_ timer: Timer) -> Timer {
        timers.append(timer)
        return timer
    }

    func reset() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()

        if let player {
            timeObservers.forEach { player.removeTimeObserver($0) }
        }
        timeObservers.removeAll()

        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()

        keyValueObservations.removeAll()
    }

}
