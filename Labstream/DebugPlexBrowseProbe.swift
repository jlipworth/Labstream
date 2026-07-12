#if DEBUG
import Foundation
import os
import PMSKit

/// Read-only acceptance probe for the app-owned Plex browse boundary.
///
/// This is deliberately inert unless `--vp-probe-plex-browse` is present. It uses the
/// signed-in app's immutable `BackendSession` through `PlexBrowseService`; it never constructs
/// or sends a browse request itself. Logs contain only fixed stage names, counts, and booleans —
/// never titles, rating keys, URLs, or credentials.
@MainActor
enum DebugPlexBrowseProbe {
    private static let log = Logger(subsystem: "com.jlipworth.Labstream",
                                    category: "PlexBrowseProbe")

    enum Stage: String {
        case readiness
        case libraries
        case page
        case alphabet
        case hubs
        case search
        case onDeck = "on_deck"
        case metadata
        case children
        case session
        case assertions
    }

    struct Evidence: Equatable {
        var libraryCount = 0
        var pageCount = 0
        var pageTotal: Int?
        var repeatedPageOrderMatches = false
        var pageIDsPresent = false
        var alphabetApplicable = false
        var alphabetCount = 0
        var hubCount = 0
        var hubItemCount = 0
        var searchHubCount = 0
        var searchItemCount = 0
        var searchLibraryCount = 0
        var searchLibrariesPresent = false
        var searchContainsSeedID = false
        var onDeckCount = 0
        var onDeckIDsPresent = true
        var metadataIDMatches = false
        var childrenApplicable = false
        var childCount = 0
        var childIDsPresent = true
        var sessionUnchanged = false

        var countCoherent: Bool {
            guard let pageTotal else { return true }
            return pageTotal >= pageCount
        }

        var passes: Bool {
            libraryCount > 0
                && pageCount > 0
                && repeatedPageOrderMatches
                && pageIDsPresent
                && countCoherent
                && (!alphabetApplicable || alphabetCount > 0)
                && hubCount > 0
                && hubItemCount > 0
                && searchHubCount > 0
                && searchItemCount > 0
                && searchContainsSeedID
                && onDeckIDsPresent
                && metadataIDMatches
                && childIDsPresent
                && sessionUnchanged
        }
    }

    static func runIfRequested(appModel: AppModel,
                               arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard arguments.contains("--vp-probe-plex-browse") else { return }
        log.notice("probe.start backend=plex read_only=true")

        guard appModel.activeBackend == .plex, appModel.isBrowseReady else {
            log.error("probe.fail stage=\(Stage.readiness.rawValue, privacy: .public) status=not_ready")
            return
        }

        var stage = Stage.readiness
        var evidence = Evidence()
        do {
            let authorityKey = appModel.activeBrowseSessionKey
            let service = try PlexBrowseService(appModel: appModel)

            stage = .libraries
            let libraries = try await service.libraries()
            evidence.libraryCount = libraries.count
            // Prefer TV when present so the same read-only pass can cover native hierarchy
            // children. Fall back to any non-music (then any) library for unusual servers.
            guard let library = libraries.first(where: { $0.type == "show" })
                    ?? libraries.first(where: { !$0.isMusic })
                    ?? libraries.first else {
                throw ProbeFailure.assertion
            }

            stage = .page
            let page = try await service.sectionPage(sectionKey: library.key,
                                                     startIndex: 0,
                                                     limit: 10,
                                                     sort: "titleSort")
            let repeatedPage = try await service.sectionPage(sectionKey: library.key,
                                                             startIndex: 0,
                                                             limit: 10,
                                                             sort: "titleSort")
            evidence.pageCount = page.items.count
            evidence.pageTotal = page.total
            let pageIDs = page.items.map(\.ratingKey)
            evidence.pageIDsPresent = !pageIDs.isEmpty && pageIDs.allSatisfy { !$0.isEmpty }
            evidence.repeatedPageOrderMatches = pageIDs == repeatedPage.items.map(\.ratingKey)
            guard let seed = page.items.first else { throw ProbeFailure.assertion }

            evidence.alphabetApplicable = library.type == "movie" || library.type == "show"
            if evidence.alphabetApplicable {
                stage = .alphabet
                evidence.alphabetCount = try await service.alphabetCounts(sectionKey: library.key).count
            }

            stage = .hubs
            let hubs = try await service.hubs()
            evidence.hubCount = hubs.count
            let hubItems = hubs.flatMap(\.metadata)
            evidence.hubItemCount = hubItems.count

            // The query is derived from a known server result, is sent only back to that same
            // server, and is never logged or recorded. Capping it bounds the request without
            // changing the privacy contract.
            stage = .search
            let query = String(seed.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !query.isEmpty else { throw ProbeFailure.assertion }
            let search = try await service.searchWithLibraries(query: query)
            let searchItems = search.hubs.flatMap(\.metadata)
            evidence.searchHubCount = search.hubs.count
            evidence.searchItemCount = searchItems.count
            evidence.searchLibraryCount = search.libraries.count
            evidence.searchLibrariesPresent = !search.libraries.isEmpty
            evidence.searchContainsSeedID = searchItems.contains { $0.ratingKey == seed.ratingKey }

            stage = .onDeck
            let onDeck = try await service.onDeck()
            evidence.onDeckCount = onDeck.count
            evidence.onDeckIDsPresent = onDeck.allSatisfy { !$0.ratingKey.isEmpty }

            stage = .metadata
            let metadata = try await service.metadata(ratingKey: seed.ratingKey)
            evidence.metadataIDMatches = metadata.ratingKey == seed.ratingKey

            if let container = ([seed] + hubItems + onDeck).first(where: \.isContainer) {
                evidence.childrenApplicable = true
                stage = .children
                let children = try await service.children(ratingKey: container.ratingKey)
                evidence.childCount = children.count
                evidence.childIDsPresent = !children.isEmpty
                    && children.allSatisfy { !$0.ratingKey.isEmpty }
            }

            stage = .session
            evidence.sessionUnchanged = authorityKey == appModel.activeBrowseSessionKey

            stage = .assertions
            guard evidence.passes else {
                logEvidence(evidence, result: "fail")
                throw ProbeFailure.assertionAlreadyLogged
            }
            logEvidence(evidence, result: "pass")
        } catch ProbeFailure.assertionAlreadyLogged {
            // The evidence line above is the one authoritative, privacy-safe failure report.
        } catch ProbeFailure.assertion {
            logEvidence(evidence, result: "fail")
        } catch {
            log.error("probe.fail stage=\(stage.rawValue, privacy: .public) status=request_or_decode_failed")
        }
    }

    private static func logEvidence(_ evidence: Evidence, result: String) {
        let alphabetStatus = evidence.alphabetApplicable ? "attempted" : "not_applicable"
        let childrenStatus = evidence.childrenApplicable ? "attempted" : "not_applicable"
        if result == "pass" {
            log.notice("probe.pass libraries=\(evidence.libraryCount, privacy: .public) page=\(evidence.pageCount, privacy: .public) total_present=\(evidence.pageTotal != nil, privacy: .public) count_ok=\(evidence.countCoherent, privacy: .public) order_ok=\(evidence.repeatedPageOrderMatches, privacy: .public) page_ids=\(evidence.pageIDsPresent, privacy: .public) alphabet_status=\(alphabetStatus, privacy: .public) alphabet=\(evidence.alphabetCount, privacy: .public) hubs=\(evidence.hubCount, privacy: .public) hub_items=\(evidence.hubItemCount, privacy: .public) search_hubs=\(evidence.searchHubCount, privacy: .public) search_items=\(evidence.searchItemCount, privacy: .public) search_libraries=\(evidence.searchLibraryCount, privacy: .public) search_libraries_present=\(evidence.searchLibrariesPresent, privacy: .public) search_seed=\(evidence.searchContainsSeedID, privacy: .public) on_deck=\(evidence.onDeckCount, privacy: .public) metadata_id=\(evidence.metadataIDMatches, privacy: .public) children_status=\(childrenStatus, privacy: .public) children=\(evidence.childCount, privacy: .public) session_ok=\(evidence.sessionUnchanged, privacy: .public)")
        } else {
            log.error("probe.fail stage=assertions status=false libraries=\(evidence.libraryCount, privacy: .public) page=\(evidence.pageCount, privacy: .public) count_ok=\(evidence.countCoherent, privacy: .public) order_ok=\(evidence.repeatedPageOrderMatches, privacy: .public) page_ids=\(evidence.pageIDsPresent, privacy: .public) alphabet_status=\(alphabetStatus, privacy: .public) alphabet=\(evidence.alphabetCount, privacy: .public) hubs=\(evidence.hubCount, privacy: .public) hub_items=\(evidence.hubItemCount, privacy: .public) search_hubs=\(evidence.searchHubCount, privacy: .public) search_items=\(evidence.searchItemCount, privacy: .public) search_libraries=\(evidence.searchLibraryCount, privacy: .public) search_libraries_present=\(evidence.searchLibrariesPresent, privacy: .public) search_seed=\(evidence.searchContainsSeedID, privacy: .public) on_deck=\(evidence.onDeckCount, privacy: .public) metadata_id=\(evidence.metadataIDMatches, privacy: .public) children_status=\(childrenStatus, privacy: .public) children=\(evidence.childCount, privacy: .public) session_ok=\(evidence.sessionUnchanged, privacy: .public)")
        }
    }

    private enum ProbeFailure: Error {
        case assertion
        case assertionAlreadyLogged
    }
}
#endif
