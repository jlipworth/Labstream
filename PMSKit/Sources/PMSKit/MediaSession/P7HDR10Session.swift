import Foundation

/// Per-open admission state. URLs are never persisted or logged. Only the selected media
/// playlist may introduce resources; segments can never be reclassified as initialization.
actor P7HDR10Session {
    enum Resource { case playlist, initialization, segment }
    private let playlist: URL
    private var initialization: URL?
    private var segments: Set<URL> = []

    init(playlist: URL) { self.playlist = playlist }

    func resource(_ url: URL) throws -> Resource {
        if url == playlist { return .playlist }
        if url == initialization { return .initialization }
        if segments.contains(url) { return .segment }
        throw P7HDR10Playlist.Rejection.unsupported
    }

    func admit(_ data: Data) throws {
        let parsed = try P7HDR10Playlist.parse(data, at: playlist)
        guard parsed.initialization != playlist,
              initialization == nil || initialization == parsed.initialization,
              !segments.contains(parsed.initialization),
              !parsed.segments.contains(playlist) else { throw P7HDR10Playlist.Rejection.unsupported }
        let combined = segments.union(parsed.segments)
        guard combined.count <= 4096 else { throw P7HDR10Playlist.Rejection.unsupported }
        initialization = parsed.initialization
        segments = combined
    }
}
