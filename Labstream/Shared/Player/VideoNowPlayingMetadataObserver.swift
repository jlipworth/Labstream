import Foundation

struct VideoNowPlayingMetadataUpdate: Equatable, Sendable {
    let elapsedMillisecondsOverride: Int?
    let playbackRateOverride: Double?
}

/// Single-observer handoff from playback events to the process-wide native publisher.
/// A token makes replacement atomic: teardown from an older player cannot remove its successor.
@MainActor
final class VideoNowPlayingMetadataObserverRegistry {
    struct Token: Hashable {
        fileprivate let id = UUID()
    }

    typealias Observer = @MainActor (VideoNowPlayingMetadataUpdate) -> Void

    private var registration: (token: Token, observer: Observer)?

    @discardableResult
    func observe(_ observer: @escaping Observer) -> Token {
        let token = Token()
        registration = (token, observer)
        return token
    }

    func remove(_ token: Token) {
        guard registration?.token == token else { return }
        registration = nil
    }

    func publish(_ update: VideoNowPlayingMetadataUpdate) {
        registration?.observer(update)
    }
}
