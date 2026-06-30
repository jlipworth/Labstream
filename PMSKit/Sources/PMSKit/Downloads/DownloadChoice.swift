import Foundation

/// What the user chose in the download sheet, resolved from any backend-specific direct-play probe.
public enum DownloadIntentChoice: Sendable, Equatable {
    /// Direct-download the original file when the backend can provide an offline-playable local file.
    case original
    /// Server-side optimize/transcode to a named preset.
    case optimize(targetName: String)
    /// Original-quality compatible remux (MediaBrowser backends): copy video into an offline-playable
    /// MP4, transcoding only audio/container as needed. Forward-only unless the backend later reports
    /// a concrete size.
    case optimizeCompatible
    /// Download an existing server-generated version exactly as-is. This is a static byte-for-byte
    /// transfer of the chosen Media/Part, but is display-labelled as server-prepared.
    case existingVersion
}

/// Pure persistence/diagnostic mapping for a user download choice.
public enum DownloadChoicePolicy {
    public static func diagnosticChoiceLabel(_ choice: DownloadIntentChoice) -> String {
        switch choice {
        case .original:
            return "original"
        case .existingVersion:
            return "existing_version"
        case .optimize(let targetName):
            return "optimize:\(targetName)"
        case .optimizeCompatible:
            return "optimize_compatible"
        }
    }

    /// Persisted lane discriminator for a choice. Existing server versions are byte-for-byte static
    /// transfers and deliberately share `.original` transfer semantics; the server-prepared display
    /// flag distinguishes them from true originals.
    public static func downloadLane(for choice: DownloadIntentChoice) -> DownloadLane {
        switch choice {
        case .original, .existingVersion:
            return .original
        case .optimize:
            return .optimize
        case .optimizeCompatible:
            return .compatibleRemux
        }
    }

    /// Display-only discriminator persisted alongside the lane: true when the chosen download is a
    /// server-prepared/transcoded version rather than the user's true source.
    public static func isServerPreparedVersion(for choice: DownloadIntentChoice) -> Bool {
        if case .existingVersion = choice { return true }
        return false
    }
}
