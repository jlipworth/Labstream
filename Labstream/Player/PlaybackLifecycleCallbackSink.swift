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

/// Authority for the reconnect deadline. Unlike item callback authority, this token is
/// deliberately independent of `PlaybackController.playbackGeneration`: one reconnect
/// operation spans negotiation and one or more player-item replacements.
@MainActor
final class PlaybackReconnectWatchdogAuthority {
    struct Token: Equatable, Sendable {
        fileprivate let value: UInt
    }

    private var value: UInt = 0
    private var armed = false

    func arm() -> Token {
        value &+= 1
        armed = true
        return Token(value: value)
    }

    func end() {
        value &+= 1
        armed = false
    }

    func accepts(_ token: Token) -> Bool {
        armed && token.value == value
    }
}

/// Per-request artwork authority, intentionally separate from player-item lifecycle.
/// Suspending music for video replaces observer authority but does not change the track art.
@MainActor
final class PlaybackArtworkRequestAuthority {
    struct Token: Equatable, Sendable {
        fileprivate let value: UInt
    }

    private var value: UInt = 0

    func begin() -> Token {
        value &+= 1
        return Token(value: value)
    }

    func invalidate() {
        value &+= 1
    }

    func accepts(_ token: Token) -> Bool {
        token.value == value
    }
}
