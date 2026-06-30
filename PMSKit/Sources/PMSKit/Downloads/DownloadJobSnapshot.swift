import Foundation

/// Explicit phase labels for the app-observed download job state.
///
/// `DownloadStatus` is the durable row lifecycle stored in the offline index. `DownloadJobPhase`
/// is the pure app/runtime-facing classification that composes durable status with live facts such
/// as active URLSession work, backend availability, checkpoint pauses, retry presentation, and
/// server-prep progress. Keeping this enum top-level lets UI captions, diagnostics, and future
/// coordinator services share the same phase vocabulary instead of each inventing status buckets.
public enum DownloadJobPhase: Sendable, Equatable {
    case failed(isRetrying: Bool)
    case paused
    case complete(isUnverified: Bool)
    case transferFinalizing
    case activeStaticZeroByteTransfer
    case serverPrepFinalizing
    case serverPrepProgressing
    case serverPrepQueued
    case waitingForBackend
    case activeServerPrep
    case queued
    case activeTransfer
    case inactiveTransfer

    public var isActiveWork: Bool {
        switch self {
        case .transferFinalizing,
             .activeStaticZeroByteTransfer,
             .serverPrepFinalizing,
             .serverPrepProgressing,
             .serverPrepQueued,
             .activeServerPrep,
             .queued,
             .activeTransfer:
            return true
        case .failed,
             .paused,
             .complete,
             .waitingForBackend,
             .inactiveTransfer:
            return false
        }
    }
}

/// Pure snapshot of the persisted row facts that identify a download job independently of app-side
/// effects. Runtime overlays can add live fields around this value without reparsing metadata.
public struct DownloadJobSnapshot: Sendable, Equatable {
    public let ratingKey: String
    public let status: DownloadStatus
    public let backend: DownloadBackendKind
    public let lane: DownloadLane
    public let resumeMode: DownloadResumeMode?
    public let isServerPreparedVersion: Bool
    public let bytes: Int
    public let progress: Double

    public init(ratingKey: String,
                status: DownloadStatus,
                backend: DownloadBackendKind,
                lane: DownloadLane,
                resumeMode: DownloadResumeMode?,
                isServerPreparedVersion: Bool,
                bytes: Int,
                progress: Double) {
        self.ratingKey = ratingKey
        self.status = status
        self.backend = backend
        self.lane = lane
        self.resumeMode = resumeMode
        self.isServerPreparedVersion = isServerPreparedVersion
        self.bytes = bytes
        self.progress = progress
    }

    public init(record: DownloadRecord) {
        let metadata = record.metadata
        self.init(ratingKey: record.ratingKey,
                  status: record.status,
                  backend: metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
                    ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey),
                  lane: metadata?.resolvedDownloadLane() ?? .original,
                  resumeMode: metadata?.resolvedResumeMode(ratingKey: record.ratingKey),
                  isServerPreparedVersion: metadata?.isServerPreparedVersion == true,
                  bytes: record.bytes,
                  progress: record.progress)
    }

    public var persistedPhase: DownloadJobPhase {
        switch status {
        case .queued:
            return .queued
        case .preparing:
            return .activeServerPrep
        case .downloading:
            return bytes > 0 ? .activeTransfer : .queued
        case .complete:
            return .complete(isUnverified: false)
        case .unverified:
            return .complete(isUnverified: true)
        case .failed:
            return .failed(isRetrying: false)
        case .paused:
            return .paused
        }
    }
}
