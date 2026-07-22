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
