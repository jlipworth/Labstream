import Foundation

/// Pure deletion decisions for download rows.
///
/// Deleting a row always remains an app-side operation (URLSession cancellation, file removal,
/// in-flight release, diagnostics). This policy captures the one backend-specific delete-time
/// nuance: an Emby `.preparing` convert row may need a best-effort server-side Sync job cancel
/// before the local row disappears.
public enum DownloadDeletePolicy {
    public enum EmbyConvertCancelDecision: Equatable, Sendable {
        case none
        case cancel(jobID: Int)
        case skip(jobID: Int, reason: String)
    }

    public static let embySessionUnavailableOrMismatchReason = "emby_session_mismatch_or_unavailable"

    public static func embyConvertCancelDecision(for record: DownloadRecord?,
                                                 embySessionMatchesPersistedServer: Bool) -> EmbyConvertCancelDecision {
        guard let record,
              record.status == .preparing,
              let jobID = record.metadata?.embyConvertJobID else {
            return .none
        }
        return embySessionMatchesPersistedServer
            ? .cancel(jobID: jobID)
            : .skip(jobID: jobID, reason: embySessionUnavailableOrMismatchReason)
    }
}
