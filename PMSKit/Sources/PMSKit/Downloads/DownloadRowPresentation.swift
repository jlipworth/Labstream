import Foundation

/// One value presentation consumed by the library and both current-download sheet wrappers.
/// Lifecycle and caption remain the existing download policies' authority.
public struct DownloadRowPresentation: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case neutral, verified, caution, failure }
    public enum Progress: Sendable, Equatable { case none, indeterminate, fraction(Double, estimated: Bool) }
    public enum Action: String, Sendable, Equatable { case play, pause, resume, retry, delete }

    public let row: OfflineDownloadRowSnapshot
    public let lifecycle: DownloadLifecycle
    public let phase: DownloadJobPhase?
    public let tone: Tone
    public let progress: Progress
    public let actions: [Action]

    public init(row: OfflineDownloadRowSnapshot, phase: DownloadJobPhase? = nil) {
        self.row = row
        let phase = phase ?? row.phase
        self.phase = phase
        if row.isWaitingForAdmission { lifecycle = .planned }
        else if phase == .queued || phase == .waitingForBackend || phase == .serverPrepQueued
            || phase == .serverPrepReady {
            lifecycle = .admitted
        } else if phase == .transferFinalizing { lifecycle = .finalizing }
        else { lifecycle = row.lifecycle }
        switch lifecycle {
        case .complete: tone = .verified
        case .unverified: tone = .caution
        case .failed where !row.isRetrying: tone = .failure
        case .paused, .planned, .admitted, .serverPrep, .finalizing, .failed, .transferring:
            tone = .neutral
        }
        if row.isRetrying {
            progress = .indeterminate
            actions = [.delete]
        } else {
            switch lifecycle {
            case .complete, .unverified:
                progress = .none; actions = [.play, .delete]
            case .paused:
                progress = .none; actions = [.resume, .delete]
            case .failed:
                progress = .none; actions = [.retry, .delete]
            case .planned, .admitted:
                progress = .none; actions = [.pause, .delete]
            case .finalizing:
                progress = .indeterminate; actions = [.delete]
            case .serverPrep, .transferring:
                if phase != .serverPrepFinalizing, let fraction = row.displayProgress,
                   fraction.isFinite, fraction > 0, fraction < 0.999 {
                    progress = .fraction(min(0.99, max(0, fraction)), estimated: row.progressIsEstimated)
                } else { progress = .indeterminate }
                actions = [.pause, .delete]
            }
        }
    }

    public var statusText: String {
        row.statusCaption
    }

    /// iPhone/iPad row status (iPhone Duo design spec, Downloads: "Status context lines are 1–2
    /// words and never wrap"). The full `statusText` (bytes, rate, ETA, reason) stays in the
    /// accessibility value and the detail pane.
    public var compactStatusText: String {
        if row.isRetrying { return "Retrying" }
        if row.isWaitingForAdmission {
            return row.statusCaption == DownloadRowStatusCaptionPolicy.queuePausedWaitingCaption
                ? "Paused" : "Queued"
        }
        let percent: String? = row.displayProgress.flatMap { value in
            guard value.isFinite, value > 0, value < 0.999 else { return nil }
            return "\(Int(min(0.99, value) * 100))%"
        }
        switch phase {
        case .failed?: return "Failed"
        case .paused?: return "Paused"
        case .complete(let isUnverified)?: return isUnverified ? "Unverified" : "Ready"
        case .transferFinalizing?: return "Verifying"
        case .serverPrepFinalizing?: return "Finalizing"
        case .serverPrepProgressing?: return percent.map { "Preparing \($0)" } ?? "Preparing"
        case .serverPrepQueued?, .activeServerPrep?: return "Preparing"
        case .serverPrepReady?, .queued?, .inactiveTransfer?: return "Queued"
        case .waitingForBackend?: return "Waiting"
        case .activeTransfer?, .activeStaticZeroByteTransfer?:
            return percent.map { "Downloading \($0)" } ?? "Downloading"
        case nil:
            switch lifecycle {
            case .planned, .admitted: return "Queued"
            case .serverPrep: return percent.map { "Preparing \($0)" } ?? "Preparing"
            case .transferring: return percent.map { "Downloading \($0)" } ?? "Downloading"
            case .finalizing: return "Verifying"
            case .complete: return "Ready"
            case .unverified: return "Unverified"
            case .paused: return "Paused"
            case .failed: return "Failed"
            }
        }
    }

    public var actionIdentity: OfflineDownloadRowActionIdentity { row.actionIdentity }
    public var accessibleStatus: String {
        let phase: String = switch lifecycle {
        case .planned, .admitted: "Waiting"
        case .serverPrep: "Preparing on server"
        case .transferring: "Downloading"
        case .finalizing: "Verifying download"
        case .complete: "Downloaded and verified"
        case .unverified: "Downloaded; playback not verified"
        case .paused: "Paused"
        case .failed: row.isRetrying ? "Retrying" : "Failed"
        }
        return [phase, statusText, row.errorMessage].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }
    public func actionLabel(_ action: Action) -> String {
        let verb: String = switch action {
        case .play: "Play offline"
        case .pause: "Pause download"
        case .resume: "Resume download"
        case .retry: "Retry download"
        case .delete: "Delete download"
        }
        return "\(verb): \(row.title)"
    }
}

/// Shared D2 copy, including bulk confirmations whose owners were captured when opened.
public enum DownloadRemovalMessage {
    public static func message(count: Int = 1, cancelsServerPrep: Bool) -> String {
        let base = count == 1
            ? "This removes the offline copy and any unfinished transfer from this device. You can download it again later."
            : "This removes \(count) downloads from offline storage. You can download them again later."
        guard cancelsServerPrep else { return base }
        return base + " Paused/in-prep deletion cancels unfinished server preparation where supported; finished server versions remain."
    }
}
