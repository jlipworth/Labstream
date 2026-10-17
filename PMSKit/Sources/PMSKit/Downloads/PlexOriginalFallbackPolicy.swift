import Foundation

/// Pure guards for retrying a validated byte-for-byte Plex original as a compatible
/// server-prepared copy after the local AVFoundation validation probe rejects the downloaded file.
/// Applies to true originals only, never to existing-version / server-prepared downloads.
public enum PlexOriginalFallbackPolicy {
    public static func shouldFallback(record: DownloadRecord?,
                                      ratingKey: String,
                                      isTranscodeSourced: Bool,
                                      hasServerPrepQueueTitle: Bool,
                                      hasPlexSession: Bool) -> Bool {
        guard let record,
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: ratingKey) == .plex,
              !isTranscodeSourced,
              !hasServerPrepQueueTitle,
              metadata.optimizeTargetName?.isEmpty != false,
              // True originals only: an explicitly chosen existing Plex Version (and any other
              // server-prepared static artifact) is exactly what the user asked for and must
              // never be replaced by a fresh optimize (#112).
              !metadata.isServerPreparedVersion,
              hasPlexSession else {
            return false
        }
        return true
    }

    public static func fallbackTarget(storedPreference: String?, defaultPreference: String) -> String {
        let stored = storedPreference?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored,
           !stored.isEmpty,
           DownloadPresetPolicy.isExplicitDownloadPresetName(stored) {
            return stored
        }
        return defaultPreference
    }
}
