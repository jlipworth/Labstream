import Foundation

/// Per-open admission state. URLs are never persisted or logged. Only the selected media
/// playlist may introduce resources; segments can never be reclassified as initialization.
actor P7HDR10Session {
    enum Resource { case playlist, initialization, segment }
    private let playlist: URL
    private var initialization: URL?
    private var segments: Set<URL> = []
    private var initializationBytes: Data?

    init(playlist: URL) { self.playlist = playlist }

    func resource(_ url: URL) throws -> Resource {
        if url == playlist { return .playlist }
        if url == initialization { return .initialization }
        if segments.contains(url) { return .segment }
        throw P7HDR10Playlist.Rejection.unsupported
    }

    /// Pin the complete validated upstream representation before serving any range.
    /// A stable MAP URI alone cannot prevent different range requests from receiving
    /// different parameter sets or audio descriptions. This actor method has no await:
    /// concurrent fetch completions cannot replace the first admitted representation.
    func normalizeInitialization(_ data: Data, at url: URL) throws -> Data {
        guard initialization == url else { throw P7HDR10Playlist.Rejection.unsupported }
        if let initializationBytes, initializationBytes != data {
            throw P7HDR10Playlist.Rejection.unsupported
        }
        let normalized = try P7HDR10Initialization.normalize(data)
        initializationBytes = data
        return normalized
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
