import Foundation
import Observation
import PMSKit

/// Authenticated page source for one playlist. The captured session identity is checked both
/// before and after transport so an old server/user/backend response can never publish after an
/// authority switch, even when the underlying transport ignores cancellation.
@MainActor
struct PlaylistPagingSource {
    enum Identity: Hashable {
        case authenticated(backend: MediaBackendKind,
                           authority: BrowseSessionAuthority,
                           playlistID: String)
        case unavailable(backend: MediaBackendKind,
                         sessionKey: String,
                         playlistID: String)
        case test(String)
    }

    static let defaultPageSize = 100

    let identity: Identity
    let pageSize: Int
    let fetchPage: @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> PlaylistPage
    let isCurrent: @MainActor @Sendable () -> Bool

    init(playlist: MediaItem,
         appModel: AppModel,
         pageSize: Int = Self.defaultPageSize) {
        let backend = appModel.activeBackend
        let sessionIdentity = appModel.activeBrowseSessionKey
        let authority = appModel.activeAuthenticatedBrowseSession?.authority
        self.identity = authority.map {
            .authenticated(backend: backend, authority: $0, playlistID: playlist.ratingKey)
        } ?? .unavailable(backend: backend,
                         sessionKey: sessionIdentity,
                         playlistID: playlist.ratingKey)
        self.pageSize = max(pageSize, 1)
        let isCurrent: @MainActor @Sendable () -> Bool = {
            guard appModel.activeBackend == backend else { return false }
            if let authority {
                return appModel.activeAuthenticatedBrowseSession?.authority == authority
            }
            return appModel.activeAuthenticatedBrowseSession == nil
                && appModel.activeBrowseSessionKey == sessionIdentity
        }
        self.isCurrent = isCurrent
        self.fetchPage = { start, limit in
            guard isCurrent() else { throw CancellationError() }
            let page = try await appModel.musicProvider.playlistTracksPage(
                playlist: playlist, start: start, size: limit)
            guard isCurrent(), !Task.isCancelled else {
                throw CancellationError()
            }
            return page
        }
    }

    /// Deterministic hosted-test seam; production callers use the authenticated initializer.
    init(identity: String,
         pageSize: Int = Self.defaultPageSize,
         isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
         fetchPage: @escaping @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> PlaylistPage) {
        self.identity = .test(identity)
        self.pageSize = max(pageSize, 1)
        self.isCurrent = isCurrent
        self.fetchPage = fetchPage
    }
}

/// Sequential playlist pager. Unlike `RailPagingModel`, it deliberately has no identity set and
/// performs no filtering: a playlist is an ordered list of positions, so repeated backend ids are
/// appended verbatim within and across pages.
@MainActor
@Observable
final class PlaylistPagingModel {
    private(set) var items: [MediaItem] = []
    private(set) var loadState: BrowseLoadState = .idle
    private(set) var isLoadingNext = false
    private(set) var nextError: String?
    private(set) var reportedTotal: Int?

    @ObservationIgnored private var state: State?
    @ObservationIgnored private var nextGeneration = 0

    var isComplete: Bool { state?.isTerminal == true }
    var canLoadMore: Bool {
        guard let state else { return false }
        return !state.isTerminal && state.inFlight == nil
    }

    func loadInitial(source: PlaylistPagingSource, force: Bool = false) async {
        if !force,
           state?.identity == source.identity,
           !items.isEmpty,
           case .loaded = loadState {
            return
        }
        reset(source: source)
        loadState = .loading
        await request(offset: 0, source: source, initial: true)
    }

    func loadNext(source: PlaylistPagingSource) async {
        guard let state,
              state.identity == source.identity,
              !items.isEmpty,
              !state.isTerminal else { return }
        await request(offset: state.failedOffset ?? state.nextOffset,
                      source: source,
                      initial: false)
    }

    func retryNext(source: PlaylistPagingSource) async {
        guard state?.identity == source.identity, state?.failedOffset != nil else { return }
        await loadNext(source: source)
    }

    /// Continue page-by-page until the complete playlist has arrived or a page fails. The detail
    /// view uses this after publishing page zero so Play/Shuffle retain their old full-queue
    /// semantics while long playlists become visible progressively.
    func loadRemaining(source: PlaylistPagingSource) async {
        while canLoadMore, !Task.isCancelled, source.isCurrent() {
            let oldCount = items.count
            await loadNext(source: source)
            guard items.count > oldCount, nextError == nil else { return }
        }
    }

    func refresh(source: PlaylistPagingSource) async {
        await loadInitial(source: source, force: true)
        guard case .loaded = loadState else { return }
        await loadRemaining(source: source)
    }

    private func reset(source: PlaylistPagingSource) {
        nextGeneration &+= 1
        state = State(identity: source.identity,
                      generation: nextGeneration,
                      pageSize: source.pageSize)
        items = []
        reportedTotal = nil
        nextError = nil
        isLoadingNext = false
    }

    private func request(offset: Int,
                         source: PlaylistPagingSource,
                         initial: Bool) async {
        guard var snapshot = state,
              snapshot.identity == source.identity,
              let token = snapshot.begin(offset: offset) else { return }
        state = snapshot
        if initial {
            loadState = .loading
        } else {
            isLoadingNext = true
            nextError = nil
        }

        do {
            let page = try await source.fetchPage(offset, source.pageSize)
            guard var current = state else { return }
            guard !Task.isCancelled, source.isCurrent() else {
                if current.acceptFailure(token: token) {
                    state = current
                    if initial, items.isEmpty { loadState = .idle }
                    if !initial { isLoadingNext = false }
                }
                return
            }
            guard current.accept(count: page.items.count,
                                 reportedTotal: page.reportedTotal,
                                 token: token) else { return }
            state = current
            // Positional append: intentionally no Set, Dictionary, ratingKey filtering, or sort.
            items.append(contentsOf: page.items)
            reportedTotal = page.reportedTotal ?? reportedTotal
            loadState = .loaded
            nextError = nil
            if !initial { isLoadingNext = false }
        } catch is CancellationError {
            guard var current = state, current.acceptFailure(token: token) else { return }
            state = current
            if initial, items.isEmpty { loadState = .idle }
            if !initial { isLoadingNext = false }
        } catch {
            guard source.isCurrent(), var current = state,
                  current.acceptFailure(token: token) else { return }
            state = current
            if initial {
                loadState = .failed(friendlyMessage(error))
            } else {
                isLoadingNext = false
                nextError = friendlyMessage(error)
            }
        }
    }

    private struct State {
        struct Token: Equatable {
            let identity: PlaylistPagingSource.Identity
            let generation: Int
            let offset: Int
            let limit: Int
        }

        let identity: PlaylistPagingSource.Identity
        let generation: Int
        let pageSize: Int
        var nextOffset = 0
        var inFlight: Token?
        var failedOffset: Int?
        var isTerminal = false

        mutating func begin(offset: Int) -> Token? {
            guard !isTerminal,
                  inFlight == nil,
                  offset == (failedOffset ?? nextOffset) else { return nil }
            let token = Token(identity: identity,
                              generation: generation,
                              offset: offset,
                              limit: pageSize)
            inFlight = token
            if failedOffset == offset { failedOffset = nil }
            return token
        }

        mutating func accept(count: Int,
                             reportedTotal: Int?,
                             token: Token) -> Bool {
            guard inFlight == token else { return false }
            inFlight = nil
            failedOffset = nil
            nextOffset = token.offset + count
            if let reportedTotal {
                // Some servers clamp the requested page size. A short page is not terminal when
                // the authoritative total says more positions remain.
                isTerminal = count == 0 || nextOffset >= max(reportedTotal, 0)
            } else {
                isTerminal = count < token.limit
            }
            return true
        }

        mutating func acceptFailure(token: Token) -> Bool {
            guard inFlight == token else { return false }
            inFlight = nil
            failedOffset = token.offset
            return true
        }
    }
}
