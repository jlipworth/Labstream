#if !os(tvOS)
import Foundation
import PMSKit

/// Value state for the download picker. The UI chooses a semantic option; this model resolves it
/// once into the exact manager intent and source identity consumed by sizing and enqueue.
struct DownloadOptionsModel {
    struct OriginalOption: Equatable {
        let sizeBytes: Int?
        let resolution: String?
    }

    struct CompatibleRemuxOption: Equatable {
        let codecSummary: String?
    }

    enum ProbeState: Equatable {
        case checking
        case ready(original: OriginalOption?, compatibleRemux: CompatibleRemuxOption?,
                   presets: [String], probeFailed: Bool,
                   originalStreamableButOfflineUnsupported: Bool,
                   existingVersions: [DownloadExistingVersionOption])
    }

    enum Selection: Equatable {
        case original
        case plexOriginalQuality(String)
        case optimizeCompatible
        case optimize(String)
        case existingVersion(Int)
        case embyExistingVersion(mediaSourceId: String, sizeBytes: Int?)
    }

    struct ResolvedSelection: Equatable {
        enum Sizing: Equatable {
            case estimateFromMedia
            case reported(Int?)
        }
        let intent: DownloadIntentRequest
        let mediaIndex: Int
        let partIndex: Int
        let mediaSourceIDOverride: String?
        let sizing: Sizing
    }

    /// Both sheet wrappers read the same live row published for the library. A disappearing or
    /// overtaken snapshot falls back only to the captured record, never to another attempt.
    static func existingRow(_ record: DownloadRecord,
                            library: OfflineLibrarySnapshot = .empty) -> OfflineDownloadRowSnapshot {
        if let live = library.rows.first(where: {
            $0.actionIdentity == OfflineDownloadRowActionIdentity(ratingKey: record.ratingKey,
                                                                  attemptID: record.attemptID)
        }) { return live }
        return OfflineLibrarySnapshotBuilder.make(records: [record], isQueuePaused: false,
            downloadSpeed: [:], errorMessage: { _ in nil },
            displayProgress: { $0.progress > 0 ? $0.progress : nil },
            statusCaption: { row, _ in
                DownloadRowStatusCaptionPolicy.admissionWaitingCaption(
                    lifecycle: row.lifecycle, intent: row.admissionIntent,
                    isQueuePaused: false, isExempt: false)
                ?? DownloadRowStatusCaptionPolicy.caption(.init(record: row, displayFraction: nil,
                    isActive: row.lifecycle == .serverPrep || row.lifecycle == .finalizing,
                    isBackendConfigured: true, isTranscodeLimited: false,
                    serverPrepState: nil, serverPrepProgress: nil, serverPrepETA: nil,
                    downloadETA: nil, downloadSpeedBytesPerSecond: nil, isRetrying: false,
                    failureCaption: nil))
            }, isRetrying: { _ in false }).rows[0]
    }

    struct RemovalConfirmation {
        let identity: OfflineDownloadRowActionIdentity
        let title: String
        let actionTitle: String
        let message: String
        init(record: DownloadRecord) {
            identity = .init(ratingKey: record.ratingKey, attemptID: record.attemptID)
            title = record.isComplete ? "Remove downloaded file?" : "Cancel this download?"
            actionTitle = record.isComplete ? "Remove Download" : "Cancel Download"
            message = DownloadRemovalMessage.message(cancelsServerPrep:
                DownloadDeletePolicy.deletionCancelsServerPrep(record))
        }
    }

    var probeState: ProbeState = .checking
    var selection: Selection?

    func resolvedSelection(baseMediaIndex: Int, basePartIndex: Int,
                           audioStreamIndex: Int?) -> ResolvedSelection? {
        guard let selection else { return nil }
        let choice: DownloadIntentChoice
        let resolvedAudio: Int?
        var mediaIndex = baseMediaIndex
        var partIndex = basePartIndex
        var mediaSourceID: String?
        var sizing: ResolvedSelection.Sizing = .estimateFromMedia
        switch selection {
        case .original:
            choice = .original; resolvedAudio = nil
        case .plexOriginalQuality(let target):
            choice = .optimize(targetName: target); resolvedAudio = nil
        case .optimizeCompatible:
            choice = .optimizeCompatible; resolvedAudio = audioStreamIndex
        case .optimize(let target):
            choice = .optimize(targetName: target); resolvedAudio = audioStreamIndex
        case .existingVersion(let index):
            choice = .existingVersion; resolvedAudio = nil; mediaIndex = index; partIndex = 0
        case .embyExistingVersion(let id, let sizeBytes):
            choice = .existingVersion; resolvedAudio = nil
            mediaSourceID = id; sizing = .reported(sizeBytes)
        }
        return ResolvedSelection(
            intent: DownloadIntentRequest(choice: choice, audioStreamIndex: resolvedAudio),
            mediaIndex: mediaIndex, partIndex: partIndex,
            mediaSourceIDOverride: mediaSourceID, sizing: sizing)
    }
}
#endif
