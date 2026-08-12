import AVFoundation
import PMSKit

/// One internally consistent picker read: the available rows and the row selected when those
/// rows were produced. Callers no longer shuttle a parallel `[Track]`/magic-`Int` tuple through
/// SwiftUI, and an invalid selected identity cannot be constructed.
@MainActor
struct PlaybackTrackSnapshot<Track: Identifiable> where Track.ID: Hashable {
    let tracks: [Track]
    let selectedID: Track.ID

    init?(tracks: [Track], selectedID: Track.ID) {
        guard tracks.contains(where: { $0.id == selectedID }) else { return nil }
        self.tracks = tracks
        self.selectedID = selectedID
    }
}

/// A subtitle row carries exactly one application mechanism. In particular, "Off" is a typed
/// mechanism for the active lane rather than `id == -1` plus three unrelated nil properties.
@MainActor
struct PlaybackSubtitleTrack: @MainActor Identifiable {
    enum ID: Hashable {
        case avFoundationOff
        case avFoundation(Int)
        case plexOff
        case plexStream(Int)
        case mediaBrowserOff
        case mediaBrowserStream(Int)
        case offlineOff
        case offlineSidecar(Int)
    }

    enum Mechanism {
        case avFoundationOff
        case avFoundation(index: Int, option: AVMediaSelectionOption)
        case plexOff
        case plexStream(Int)
        case mediaBrowserOff
        case mediaBrowserStream(Int)
        case offlineOff
        case offlineSidecar(OfflineTextSubtitleTrack)
    }

    let displayName: String
    let mechanism: Mechanism
    let burnRisk: SubtitleBurnRiskPolicy.Verdict
    let styleCapability: SubtitleStyleCapabilityPolicy.Capability

    init(displayName: String,
         mechanism: Mechanism,
         burnRisk: SubtitleBurnRiskPolicy.Verdict = .none,
         styleCapability: SubtitleStyleCapabilityPolicy.Capability = .nativeAVFoundationPreview) {
        self.displayName = displayName
        self.mechanism = mechanism
        self.burnRisk = burnRisk
        self.styleCapability = styleCapability
    }

    var id: ID {
        switch mechanism {
        case .avFoundationOff: .avFoundationOff
        case .avFoundation(let index, _): .avFoundation(index)
        case .plexOff: .plexOff
        case .plexStream(let streamID): .plexStream(streamID)
        case .mediaBrowserOff: .mediaBrowserOff
        case .mediaBrowserStream(let streamIndex): .mediaBrowserStream(streamIndex)
        case .offlineOff: .offlineOff
        case .offlineSidecar(let track): .offlineSidecar(track.id)
        }
    }

}

/// An audio row likewise declares whether selection is an in-item AVFoundation switch or a
/// backend stream choice that requires a restart/reopen.
@MainActor
struct PlaybackAudioTrack: @MainActor Identifiable {
    enum ID: Hashable {
        case avFoundation(Int)
        case plexStream(Int)
        case mediaBrowserStream(Int)
    }

    enum Mechanism {
        case avFoundation(index: Int, option: AVMediaSelectionOption)
        case plexStream(Int)
        case mediaBrowserStream(Int)
    }

    let displayName: String
    let mechanism: Mechanism

    var id: ID {
        switch mechanism {
        case .avFoundation(let index, _): .avFoundation(index)
        case .plexStream(let streamID): .plexStream(streamID)
        case .mediaBrowserStream(let streamIndex): .mediaBrowserStream(streamIndex)
        }
    }
}

/// Semantic subtitle override retained by the controller. Backend-specific sentinels are allowed
/// only at these adapter properties, immediately before/after the wire-facing APIs.
enum BackendSubtitleSelection: Equatable, Sendable {
    case off
    case stream(Int)

    static func mediaBrowserWireValue(_ value: Int?) -> BackendSubtitleSelection? {
        guard let value else { return nil }
        if value == MediaBrowserPlaybackPreferencePolicy.subtitleOffStreamIndex { return .off }
        guard value >= 0 else { return nil }
        return .stream(value)
    }

    static func plexWireValue(_ value: Int?) -> BackendSubtitleSelection? {
        guard let value, value >= 0 else { return nil }
        return value == 0 ? .off : .stream(value)
    }

    var mediaBrowserWireValue: Int {
        switch self {
        case .off: MediaBrowserPlaybackPreferencePolicy.subtitleOffStreamIndex
        case .stream(let streamIndex): streamIndex
        }
    }

    var plexWireValue: Int {
        switch self {
        case .off: 0
        case .stream(let streamID): streamID
        }
    }
}

typealias OfflineSubtitleCueLoader = @Sendable (URL) async throws -> [OfflineTextSubtitleCue]

enum OfflineSubtitleCueLoading {
    static let live: OfflineSubtitleCueLoader = { url in
        try await Task.detached(priority: .userInitiated) {
            let text = try String(contentsOf: url, encoding: .utf8)
            return OfflineTextSubtitleParser.parse(text)
        }.value
    }
}

/// Latest-selection-wins authority for asynchronous offline sidecar parsing. Beginning another
/// track or Off invalidates every older token; caller task cancellation is checked at commit.
struct OfflineSubtitleSelectionAuthority: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let generation: Int
        let trackID: Int?
    }

    private(set) var generation = 0
    private(set) var intendedTrackID: Int?

    mutating func begin(trackID: Int?) -> Token {
        generation += 1
        intendedTrackID = trackID
        return Token(generation: generation, trackID: trackID)
    }

    func accepts(_ token: Token, isCancelled: Bool) -> Bool {
        !isCancelled
            && token.generation == generation
            && token.trackID == intendedTrackID
    }
}

struct MetadataAudioSelectionAuthority: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let generation: Int
        let streamID: Int
    }

    private(set) var generation = 0
    private(set) var intendedStreamID: Int?

    mutating func begin(streamID: Int) -> Token {
        generation += 1
        intendedStreamID = streamID
        return Token(generation: generation, streamID: streamID)
    }

    func accepts(_ token: Token, isCancelled: Bool) -> Bool {
        !isCancelled
            && token.generation == generation
            && token.streamID == intendedStreamID
    }
}

enum PlaybackTrackSelectionPolicy {
    static func resolvedMetadataAudioStreamID(candidate: Int?, streams: [PlexStream]) -> Int? {
        guard !streams.isEmpty else { return nil }
        if let candidate, streams.contains(where: { $0.id == candidate }) { return candidate }
        return streams.first(where: { $0.selected == true })?.id
            ?? streams.first(where: { $0.isDefault == true })?.id
            ?? streams.first?.id
    }
}

typealias PlexAudioStreamSelector = @Sendable (_ partID: Int, _ streamID: Int) async throws -> Void
