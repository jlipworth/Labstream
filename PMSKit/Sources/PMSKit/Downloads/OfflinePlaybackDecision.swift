import Foundation

/// Pure routing helper for the "play this item" decision when a completed offline row exists.
///
/// The app's UI owns presentation, but the critical invariant is small and testable: a completed
/// local file for the same backend/item wins over opening a live stream/server session.
public enum OfflinePlaybackDecision {
    public enum Route: Sendable, Equatable {
        case localFile(URL)
        case remoteStream
    }

    /// Store identity for a specific backend. Mirrors `DownloadManager.recordKey(for:backend:)`
    /// so PMSKit probes/tests can verify the routing invariant without importing the app target.
    public static func recordKey(for ratingKey: String, backend: DownloadBackendKind) -> String {
        switch backend {
        case .plex:
            return ratingKey
        case .jellyfin:
            return "jellyfin:\(ratingKey)"
        case .emby:
            return "emby:\(ratingKey)"
        }
    }

    /// Return the completed local download row for this item/backend when the indexed file still
    /// exists. `fileExists` is injectable so tests/probes can prove the "no file → remote" branch
    /// without touching the real filesystem.
    public static func completedLocalRecord(for item: MediaItem,
                                            backend: DownloadBackendKind,
                                            records: [DownloadRecord],
                                            fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> DownloadRecord? {
        let key = recordKey(for: item.ratingKey, backend: backend)
        return records.first {
            $0.ratingKey == key && $0.isComplete && fileExists($0.localURL)
        }
    }

    /// Choose local playback whenever a completed, still-present downloaded copy exists. The
    /// remote branch is just a label: this function deliberately has no server/session parameters,
    /// so selecting `.localFile` cannot accidentally start a server stream.
    public static func route(for item: MediaItem,
                             backend: DownloadBackendKind,
                             records: [DownloadRecord],
                             fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Route {
        if let record = completedLocalRecord(for: item, backend: backend, records: records, fileExists: fileExists) {
            return .localFile(record.localURL)
        }
        return .remoteStream
    }
}
