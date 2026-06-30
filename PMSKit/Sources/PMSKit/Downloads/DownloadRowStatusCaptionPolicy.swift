import Foundation

/// Pure status-caption policy for an offline-download row.
///
/// The app coordinator owns the live facts (active task sets, ETA dictionaries, retry overlays,
/// backend availability), while this policy owns how those facts are composed into the single
/// user-visible status line. Keeping this in PMSKit pins subtle lane behavior without requiring the
/// UI snapshot builder to duplicate phase-specific wording.
public enum DownloadRowStatusCaptionPolicy {
    public struct Context: Sendable, Equatable {
        public let status: DownloadStatus
        public let progress: Double
        public let bytes: Int
        public let lane: DownloadLane
        public let backend: DownloadBackendKind
        public let resumeMode: DownloadResumeMode?
        public let isServerPreparedVersion: Bool
        public let resolutionLabel: String?
        public let displayFraction: DownloadProgressDisplay.Fraction?
        public let isActive: Bool
        public let isCheckpointPausing: Bool
        public let isBackendConfigured: Bool
        public let isTranscodeLimited: Bool
        public let serverPrepState: String?
        public let serverPrepProgress: Double?
        public let serverPrepETA: TimeInterval?
        public let downloadETA: TimeInterval?
        public let downloadSpeedBytesPerSecond: Double?
        public let hasServerPrepQueueTitle: Bool
        public let isRetrying: Bool
        public let failureCaption: String?

        public init(status: DownloadStatus,
                    progress: Double,
                    bytes: Int,
                    lane: DownloadLane,
                    backend: DownloadBackendKind,
                    resumeMode: DownloadResumeMode?,
                    isServerPreparedVersion: Bool,
                    resolutionLabel: String?,
                    displayFraction: DownloadProgressDisplay.Fraction?,
                    isActive: Bool,
                    isCheckpointPausing: Bool,
                    isBackendConfigured: Bool,
                    isTranscodeLimited: Bool,
                    serverPrepState: String?,
                    serverPrepProgress: Double?,
                    serverPrepETA: TimeInterval?,
                    downloadETA: TimeInterval?,
                    downloadSpeedBytesPerSecond: Double?,
                    hasServerPrepQueueTitle: Bool,
                    isRetrying: Bool,
                    failureCaption: String?) {
            self.status = status
            self.progress = progress
            self.bytes = bytes
            self.lane = lane
            self.backend = backend
            self.resumeMode = resumeMode
            self.isServerPreparedVersion = isServerPreparedVersion
            self.resolutionLabel = resolutionLabel
            self.displayFraction = displayFraction
            self.isActive = isActive
            self.isCheckpointPausing = isCheckpointPausing
            self.isBackendConfigured = isBackendConfigured
            self.isTranscodeLimited = isTranscodeLimited
            self.serverPrepState = serverPrepState
            self.serverPrepProgress = serverPrepProgress
            self.serverPrepETA = serverPrepETA
            self.downloadETA = downloadETA
            self.downloadSpeedBytesPerSecond = downloadSpeedBytesPerSecond
            self.hasServerPrepQueueTitle = hasServerPrepQueueTitle
            self.isRetrying = isRetrying
            self.failureCaption = failureCaption
        }
    }

    public static let serverPrepQueuedState = "queued"

    /// Explicit row phase for the offline-download UI. This is deliberately UI-facing rather than
    /// persisted: it names the currently observed phase after durable status and live coordinator
    /// facts have been combined.
    public enum Phase: Sendable, Equatable {
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
    }

    public static func phase(_ context: Context) -> Phase {
        switch context.status {
        case .failed:
            return .failed(isRetrying: context.isRetrying)
        case .paused:
            return .paused
        case .complete, .unverified:
            return .complete(isUnverified: context.status == .unverified)
        case .queued, .preparing, .downloading:
            break
        }

        if DownloadProgressDisplay.isTransferFinalizing(status: context.status,
                                                        progress: context.progress) {
            return .transferFinalizing
        }

        let isServerPrep = context.resumeMode == .serverPrepThenStatic
        if context.bytes == 0 {
            if context.isActive, context.resumeMode == .staticByteRange {
                return .activeStaticZeroByteTransfer
            }
            if DownloadProgressDisplay.isServerPrepFinalizing(state: context.serverPrepState,
                                                              progress: context.serverPrepProgress) {
                return .serverPrepFinalizing
            }
            if context.serverPrepProgress != nil { return .serverPrepProgressing }
            if context.serverPrepState == serverPrepQueuedState { return .serverPrepQueued }
            if isServerPrep { return .serverPrepQueued }
            if !context.isActive, !context.isBackendConfigured { return .waitingForBackend }
            if context.isActive { return .activeServerPrep }
            if context.hasServerPrepQueueTitle { return .serverPrepQueued }
            return .queued
        }

        return context.isActive ? .activeTransfer : .inactiveTransfer
    }

    public static func caption(_ context: Context) -> String {
        switch phase(context) {
        case .failed(let isRetrying):
            if isRetrying { return "Retrying…" }
            return context.failureCaption ?? "Download failed. Tap to retry."
        case .paused:
            return DownloadRowDisplayPolicy.pausedCaption(fraction: context.displayFraction,
                                                          bytes: context.bytes)
        case .complete(let isUnverified):
            return DownloadRowDisplayPolicy.completeCaption(isUnverified: isUnverified,
                                                            bytes: context.bytes,
                                                            resolutionLabel: context.resolutionLabel)
        case .transferFinalizing:
            return transferFinalizingCaption(context)
        case .activeStaticZeroByteTransfer:
            return activeStaticZeroByteTransferCaption(context)
        case .serverPrepFinalizing:
            return serverPrepFinalizingCaption(context)
        case .serverPrepProgressing:
            return serverPrepProgressCaption(context)
        case .serverPrepQueued, .activeServerPrep:
            return "Preparing on server…"
        case .waitingForBackend:
            return "Waiting for \(context.backend.displayName)…"
        case .queued:
            return "Queued…"
        case .activeTransfer, .inactiveTransfer:
            return transferCaption(context)
        }
    }

    private static func activeStaticZeroByteTransferCaption(_ context: Context) -> String {
        var pieces: [String] = []
        var head = DownloadRowDisplayPolicy.activeHead(lane: context.lane,
                                                       backend: context.backend,
                                                       isServerPreparedVersion: context.isServerPreparedVersion,
                                                       isCheckpointPausing: false)
        if let fraction = context.displayFraction {
            head += " • \(DownloadRowDisplayPolicy.percentText(fraction))"
        } else {
            head += " • 0%"
        }
        if let eta = context.downloadETA, eta > 0,
           let left = DownloadRowDisplayPolicy.timeLeftString(eta) {
            head += " • ~\(left) left"
        }
        pieces.append(head)
        if let speed = context.downloadSpeedBytesPerSecond, speed > 0 {
            pieces.append("\(DownloadRowDisplayPolicy.byteString(Int(speed)))/s")
        }
        if let resolutionLabel = context.resolutionLabel { pieces.append(resolutionLabel) }
        return pieces.joined(separator: " • ")
    }

    private static func serverPrepProgressCaption(_ context: Context) -> String {
        let isServerPrep = context.resumeMode == .serverPrepThenStatic
        let prepHead = (isServerPrep || context.status == .preparing) ? "Preparing on server…" : "Transcoding"
        guard let progress = context.serverPrepProgress else { return prepHead }
        var caption = "\(prepHead) \(Int(progress * 100))%"
        if let eta = context.serverPrepETA, eta > 0,
           let left = DownloadRowDisplayPolicy.timeLeftString(eta) {
            caption += " • ~\(left) left"
        }
        return caption
    }

    private static func transferCaption(_ context: Context) -> String {
        var pieces: [String] = []
        let percentPiece = context.displayFraction.map(DownloadRowDisplayPolicy.percentText)
        if context.isActive {
            var head = DownloadRowDisplayPolicy.activeHead(lane: context.lane,
                                                           backend: context.backend,
                                                           isServerPreparedVersion: context.isServerPreparedVersion,
                                                           isCheckpointPausing: context.isCheckpointPausing)
            if let percentPiece { head += " • \(percentPiece)" }
            if let eta = context.downloadETA, eta > 0,
               let left = DownloadRowDisplayPolicy.timeLeftString(eta) {
                head += " • ~\(left) left"
            }
            pieces.append(head)
        } else if let percentPiece {
            pieces.append(percentPiece)
        }

        pieces.append(DownloadRowDisplayPolicy.byteString(context.bytes))
        if context.isActive, let speed = context.downloadSpeedBytesPerSecond, speed > 0 {
            let rate = "\(DownloadRowDisplayPolicy.byteString(Int(speed)))/s"
            pieces.append(context.isTranscodeLimited ? "\(rate) server-paced" : rate)
        }
        if let resolutionLabel = context.resolutionLabel { pieces.append(resolutionLabel) }
        return pieces.joined(separator: " • ")
    }

    private static func transferFinalizingCaption(_ context: Context) -> String {
        var pieces = ["Verifying download…"]
        if context.bytes > 0 { pieces.append(DownloadRowDisplayPolicy.byteString(context.bytes)) }
        if let resolutionLabel = context.resolutionLabel { pieces.append(resolutionLabel) }
        return pieces.joined(separator: " • ")
    }

    private static func serverPrepFinalizingCaption(_ context: Context) -> String {
        var pieces = ["Finalizing server transcode…"]
        if let resolutionLabel = context.resolutionLabel { pieces.append(resolutionLabel) }
        return pieces.joined(separator: " • ")
    }
}
