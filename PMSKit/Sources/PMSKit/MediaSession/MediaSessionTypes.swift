import Foundation

/// What `MediaSessionProxy.standUpLoopback` hands back to the renderer. No AVFoundation
/// types cross this boundary — the player just consumes `localURL`.
public struct MediaSessionHandle: Sendable, Equatable {
    /// The loopback URL to hand to `AVURLAsset`. e.g. `http://127.0.0.1:51234/video/:/...`.
    public let localURL: URL
    /// Identifies this logical stream. Bumps on each loopback open; `stop(generation:)` is a no-op
    /// for a stale generation so a late teardown can't kill a newer session.
    public let generation: Int

    public init(localURL: URL, generation: Int) {
        self.localURL = localURL
        self.generation = generation
    }
}

/// Observable session state for UI/diagnostics/tests. No AVFoundation leakage.
public struct MediaSessionStatus: Sendable, Equatable {
    public let generation: Int
    public let isOpen: Bool
    /// How many times the upstream socket has been rotated this session (#33 recovery count).
    public let rotateCount: Int

    public init(generation: Int, isOpen: Bool, rotateCount: Int) {
        self.generation = generation
        self.isOpen = isOpen
        self.rotateCount = rotateCount
    }
}
