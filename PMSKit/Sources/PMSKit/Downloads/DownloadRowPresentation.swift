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
    public let symbol: String
    public let actions: [Action]

    public init(row: OfflineDownloadRowSnapshot, phase: DownloadJobPhase? = nil) {
        self.row = row
        let phase = phase ?? row.phase
        self.phase = phase
        if row.isWaitingForAdmission { lifecycle = .planned }
        else if phase == .queued || phase == .waitingForBackend || phase == .serverPrepQueued {
            lifecycle = .admitted
        } else if phase == .transferFinalizing { lifecycle = .finalizing }
        else { lifecycle = row.lifecycle }
        switch lifecycle {
        case .complete: tone = .verified; symbol = "checkmark.circle.fill"
        case .unverified: tone = .caution; symbol = "exclamationmark.circle"
        case .failed where !row.isRetrying: tone = .failure; symbol = "exclamationmark.circle"
        case .paused: tone = .neutral; symbol = "pause.circle"
        case .planned, .admitted: tone = .neutral; symbol = "clock"
        case .serverPrep: tone = .neutral; symbol = "gearshape.arrow.triangle.2.circlepath"
        case .finalizing: tone = .neutral; symbol = "checkmark.magnifyingglass"
        case .failed, .transferring: tone = .neutral; symbol = "arrow.down.circle"
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
        guard lifecycle == .complete else { return row.statusCaption }
        return row.statusCaption.isEmpty ? "Downloaded" : "Downloaded • " + row.statusCaption
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
        return [phase, row.statusCaption, row.errorMessage].compactMap { $0 }
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
