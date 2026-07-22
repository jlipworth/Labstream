import Foundation
import PMSKit

/// Which music listing a `MusicPagedGrid` shows. Album cells render square; artist cells
/// render circular (`SquareArtCell` keys off `item.kind`), so the grid needs no shape flag —
/// only the page/alphabet plumbing differs, which this enum drives (#111).
enum MusicGridKind {
    case artists
    case albums
}

/// `LibraryPagingSource` factories for the music Artists/Albums grids, mirroring the video
/// `LibraryGridPagingSources` so the music grids reuse the SAME random-access paging model,
/// A–Z rail, and sort machinery for all three backends (#111).
///
/// Page fetches route through `appModel.musicProvider` (already backend-dispatched: Plex's
/// `MusicRequest`, MediaBrowser's `/Items` + `/Artists/AlbumArtists`). The A–Z rail counts
/// are backend-specific probes — Jellyfin/Emby fan a `NameStartsWith` count per letter, Plex
/// reads its single `/firstCharacter` response — and only emit for an alphabetical sort (the
/// other orderings hide the rail, since their offsets wouldn't line up A–Z).
@MainActor
extension LibraryPagingSource {
    static func music(kind: MusicGridKind,
                      libraryID: String,
                      libraryTitle: String,
                      sort: MusicBrowseSort,
                      appModel: AppModel) -> LibraryPagingSource {
        LibraryPagingSource(
            title: libraryTitle,
            identity: musicPagingIdentity(kind: kind,
                                          libraryID: libraryID,
                                          sort: sort,
                                          appModel: appModel),
            backendLabel: appModel.activeBackend.performanceLabel,
            cacheEmptyFirstPage: false,
            awaitAlphabetBeforeInitialLoad: false,
            fetchPage: { start, limit in
                let provider = appModel.musicProvider
                let page: MusicPage
                switch kind {
                case .artists:
                    page = try await provider.artists(libraryID: libraryID, sort: sort,
                                                      start: start, size: limit)
                case .albums:
                    page = try await provider.albums(libraryID: libraryID, sort: sort,
                                                     start: start, size: limit)
                }
                return LibraryPagingPage(items: page.items, reportedTotal: page.total)
            },
            fetchAlphabetCounts: {
                // Only an alphabetical sort makes A–Z offsets meaningful; otherwise the rail
                // hides (its buckets would point into a non-alphabetical list).
                guard sort.isAlphabetical else { return [] }
                switch appModel.activeBackend {
                case .jellyfin:
                    return await jellyfinMusicAlphabetCounts(kind: kind, libraryID: libraryID, appModel: appModel)
                case .emby:
                    return await embyMusicAlphabetCounts(kind: kind, libraryID: libraryID, appModel: appModel)
                case .plex:
                    return await plexMusicAlphabetCounts(kind: kind, sectionKey: libraryID, appModel: appModel)
                }
            }
        )
    }
}

/// UI cache/stale-result guard — backend, listing kind, library, sort, and origin are enough
/// to invalidate when any of them changes (mirrors `libraryPagingIdentity`). No tokens.
@MainActor
private func musicPagingIdentity(kind: MusicGridKind,
                                 libraryID: String,
                                 sort: MusicBrowseSort,
                                 appModel: AppModel) -> String {
    let kindToken = kind == .artists ? "artists" : "albums"
    return ["music", appModel.activeBrowseSessionKey, kindToken, libraryID, sort.rawValue]
        .joined(separator: ":")
}

// MARK: - A–Z rail count probes

private let musicAlphabetLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

/// Probe each A–Z letter's count in parallel and return raw `(display, count)` pairs;
/// `LibraryPagingModel` turns them into `AlphabetBucket`s once the first page reports the
/// listing total. Mirrors `jellyfinAlphabetCounts` for the video grids (#96, #111).
private func jellyfinMusicAlphabetCounts(kind: MusicGridKind,
                                         libraryID: String,
                                         appModel: AppModel) async -> [(display: String, count: Int)] {
    let service = JellyfinBrowseService(appModel: appModel)
    let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
        for (index, letter) in musicAlphabetLetters.enumerated() {
            group.addTask {
                let total: Int?
                switch kind {
                case .artists:
                    total = try? await service.albumArtistsPage(parentId: libraryID,
                                                                limit: 1,
                                                                nameStartsWith: letter).total
                case .albums:
                    total = try? await service.itemsPage(parentId: libraryID,
                                                         recursive: true,
                                                         limit: 1,
                                                         nameStartsWith: letter,
                                                         includeItemTypes: "MusicAlbum").total
                }
                return (index, letter, total ?? 0)
            }
        }
        var byIndex: [Int: (String, Int)] = [:]
        for await (index, letter, count) in group where count > 0 { byIndex[index] = (letter, count) }
        return byIndex
    }
    return counts.keys.sorted().map { (display: counts[$0]!.0, count: counts[$0]!.1) }
}

private func embyMusicAlphabetCounts(kind: MusicGridKind,
                                     libraryID: String,
                                     appModel: AppModel) async -> [(display: String, count: Int)] {
    let service = EmbyBrowseService(appModel: appModel)
    let counts = await withTaskGroup(of: (Int, String, Int).self) { group -> [Int: (String, Int)] in
        for (index, letter) in musicAlphabetLetters.enumerated() {
            group.addTask {
                let total: Int?
                switch kind {
                case .artists:
                    total = try? await service.albumArtistsPage(parentId: libraryID,
                                                                limit: 1,
                                                                nameStartsWith: letter).total
                case .albums:
                    total = try? await service.itemsPage(parentId: libraryID,
                                                         recursive: true,
                                                         limit: 1,
                                                         nameStartsWith: letter,
                                                         includeItemTypes: "MusicAlbum").total
                }
                return (index, letter, total ?? 0)
            }
        }
        var byIndex: [Int: (String, Int)] = [:]
        for await (index, letter, count) in group where count > 0 { byIndex[index] = (letter, count) }
        return byIndex
    }
    return counts.keys.sorted().map { (display: counts[$0]!.0, count: counts[$0]!.1) }
}

/// Plex reads its single `/firstCharacter` response, scoped to the artist (8) / album (9)
/// item type so each pivot's rail gets its own letter runs. Returns [] (rail hides) on any
/// failure — including a server that ignores `type`, which would otherwise mis-scope albums.
@MainActor
private func plexMusicAlphabetCounts(kind: MusicGridKind,
                                     sectionKey: String,
                                     appModel: AppModel) async -> [(display: String, count: Int)] {
    guard let service = try? PlexBrowseService(appModel: appModel) else { return [] }
    let type = kind == .artists ? 8 : 9
    return (try? await service.alphabetCounts(sectionKey: sectionKey, type: type)) ?? []
}
