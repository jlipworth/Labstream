import Foundation
import PMSKit

/// Persisted, credential-free identity for one downloaded artwork file. This deliberately cannot
/// be constructed from the active AppModel: offline artwork belongs to the download attempt/source
/// that wrote it, and its generation advances on every content replacement.
struct OfflineArtworkSource: Hashable,
                             Sendable,
                             CustomStringConvertible,
                             CustomDebugStringConvertible,
                             CustomReflectable {
    let fileURL: URL
    let backend: MediaBackendKind
    private let ownerData: Data
    let generation: UInt64

    var description: String {
        "OfflineArtworkSource(backend: \(backend.rawValue), generation: \(generation), file: <redacted>, owner: <opaque>)"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self,
               children: [
                   "backend": backend,
                   "generation": generation,
                   "file": "<redacted>",
                   "owner": "<opaque>",
               ],
               displayStyle: .struct)
    }

    init?(fileURL: URL?, metadata: OfflineMetadata?, ratingKey: String) {
        guard let fileURL,
              fileURL.isFileURL,
              let metadata,
              let owner = metadata.sideAssetBundleOwner,
              let ownerData = try? Self.encode(owner),
              !ownerData.isEmpty else { return nil }
        self.fileURL = fileURL
        self.backend = switch metadata.resolvedBackendKind(ratingKey: ratingKey) {
        case .plex: .plex
        case .jellyfin: .jellyfin
        case .emby: .emby
        }
        self.ownerData = ownerData
        generation = metadata.posterGeneration
    }

    init?(_ presentation: OfflineArtworkPresentation) {
        guard presentation.fileURL.isFileURL,
              let encodedOwner = try? Self.encode(presentation.owner), !encodedOwner.isEmpty else {
            return nil
        }
        fileURL = presentation.fileURL
        backend = switch presentation.backend {
        case .plex: .plex
        case .jellyfin: .jellyfin
        case .emby: .emby
        }
        ownerData = encodedOwner
        generation = presentation.generation
    }

    func descriptor(purpose: ArtworkPurpose = .poster,
                    pixelWidth: Int,
                    pixelHeight: Int) -> ArtworkRequestDescriptor? {
        ArtworkRequestDescriptor.localFile(fileURL,
                                           backend: backend,
                                           ownerData: ownerData,
                                           generation: generation,
                                           purpose: purpose,
                                           pixelWidth: pixelWidth,
                                           pixelHeight: pixelHeight)
    }

    private static func encode(_ owner: OfflineSideAssetBundleOwner) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(owner)
    }
}
