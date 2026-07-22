import Foundation
import Observation
import PMSKit

@MainActor @Observable
final class RailPagingModel {
    private(set) var items: [MediaItem] = []
    private(set) var isInitialLoading = false
    private(set) var initialError: String?
    private(set) var isLoadingNext = false
    private(set) var nextError: String?

    private var state: IncrementalPagingState?

    var canLoadMore: Bool {
        guard let state else { return false }
        return !state.isTerminal && state.inFlightOffset == nil
    }

    func loadInitial(source: RailPagingSource) async {
        guard items.isEmpty, !isInitialLoading else { return }
        if state?.identity != source.identity {
            state = IncrementalPagingState(identity: source.identity, pageSize: source.pageSize)
        }
        isInitialLoading = true
        initialError = nil
        await load(offset: 0, source: source, initial: true)
    }

    func loadNext(source: RailPagingSource) async {
        guard let state, !items.isEmpty, !state.isTerminal else { return }
        await load(offset: state.nextOffset, source: source, initial: false)
    }

    func retryNext(source: RailPagingSource) async {
        guard let offset = state?.failedOffset else { return }
        await load(offset: offset, source: source, initial: false)
    }

    func refresh(source: RailPagingSource) async {
        if state == nil { state = IncrementalPagingState(identity: source.identity, pageSize: source.pageSize) }
        state?.refresh(identity: source.identity)
        items = []
        initialError = nil
        nextError = nil
        isInitialLoading = true
        await load(offset: 0, source: source, initial: true)
    }

    private func load(offset: Int, source: RailPagingSource, initial: Bool) async {
        guard var snapshot = state, let token = snapshot.beginRequest(offset: offset) else { return }
        state = snapshot
        if initial { isInitialLoading = true } else { isLoadingNext = true; nextError = nil }
        defer {
            isInitialLoading = false
            isLoadingNext = false
        }
        do {
            let page = try await source.fetchPage(offset, source.pageSize)
            guard !Task.isCancelled, var current = state,
                  current.acceptPage(page.items.map(\.ratingKey), reportedTotal: page.reportedTotal, token: token) else { return }
            state = current
            var existing = Set(items.map(\.ratingKey))
            items.append(contentsOf: page.items.filter { existing.insert($0.ratingKey).inserted })
            initialError = nil
            nextError = nil
        } catch is CancellationError {
            if var current = state, current.acceptFailure(token: token) { state = current }
            return
        } catch {
            guard var current = state, current.acceptFailure(token: token) else { return }
            state = current
            if initial { initialError = friendlyMessage(error) } else { nextError = friendlyMessage(error) }
        }
    }
}
