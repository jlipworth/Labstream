import Foundation

/// Typed callback boundary shared by player code and deterministic lifecycle tests.
/// Observer removal is not enough once a callback has queued its actor continuation;
/// every continuation asks this sink whether its captured authority is still current.
enum PlaybackLifecycleCallbackKind: Sendable {
    case videoHeartbeat
    case videoMarker
    case videoPlaying
    case musicTick
    case musicStatus
    case musicArtwork
    case musicAudioSession
}

@MainActor
final class PlaybackLifecycleCallbackSink<Generation> {
    private let isCurrent: @MainActor (Generation) -> Bool

    init(isCurrent: @escaping @MainActor (Generation) -> Bool) {
        self.isCurrent = isCurrent
    }

    func accepts(_ kind: PlaybackLifecycleCallbackKind, generation: Generation) -> Bool {
        _ = kind // The type is intentionally carried through production call sites and tests.
        return isCurrent(generation)
    }

    @discardableResult
    func perform(_ kind: PlaybackLifecycleCallbackKind,
                 generation: Generation,
                 mutation: () -> Void) -> Bool {
        guard accepts(kind, generation: generation) else { return false }
        mutation()
        return true
    }
}
