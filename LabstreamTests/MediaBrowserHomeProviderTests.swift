import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("MediaBrowser Home provider routing")
@MainActor
struct MediaBrowserHomeProviderTests {
    @Test func plexCannotCreateMediaBrowserProvider() {
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "home-provider-plex"),
            activeBackend: .plex
        )

        if let _ = MediaBrowserHomeProvider(appModel: model,
                                            catalogRepository: LibraryCatalogRepository()) {
            Issue.record("Plex must use its native Home provider")
        }
    }

    @Test func providerKeepsOriginalMediaBrowserLaneAfterActiveBackendChanges() throws {
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "home-provider-snapshot"),
            activeBackend: .emby
        )
        let provider = try #require(MediaBrowserHomeProvider(
            appModel: model,
            catalogRepository: LibraryCatalogRepository()))

        model.activeBackend = .plex

        #expect(provider.backend == .emby)
    }

    @Test func railPlanHasStableCanonicalOrderAndCurrentRequestShape() {
        let libraries = (1...10).map {
            MediaBrowserHomeLibraryLink(id: "library-\($0)",
                                        title: "Library \($0)",
                                        collectionType: $0 == 2 ? "tvshows" : "movies")
        }
        let plan = MediaBrowserHomeRailPlan(libraries: libraries,
                                            backend: .jellyfin,
                                            sessionIdentity: "session")

        #expect(plan.entries.map(\.key) == [
            .continueWatching,
            .nextUp,
            .latest(libraryID: "library-1"),
            .latest(libraryID: "library-2"),
            .latest(libraryID: "library-3"),
            .latest(libraryID: "library-4"),
            .latest(libraryID: "library-5"),
            .latest(libraryID: "library-6"),
            .latest(libraryID: "library-7"),
            .latest(libraryID: "library-8"),
        ])
        #expect(plan.entries.map { $0.key.stableID } == [
            "continue-watching", "next-up", "latest-library-1", "latest-library-2",
            "latest-library-3", "latest-library-4", "latest-library-5", "latest-library-6",
            "latest-library-7", "latest-library-8",
        ])
        #expect(plan.entries.map(\.request) == [
            .resume(limit: 20),
            .nextUp(limit: 20),
            .latest(parentID: "library-1", itemTypes: "Movie", limit: 20),
            .latest(parentID: "library-2", itemTypes: "Episode", limit: 20),
            .latest(parentID: "library-3", itemTypes: "Movie", limit: 20),
            .latest(parentID: "library-4", itemTypes: "Movie", limit: 20),
            .latest(parentID: "library-5", itemTypes: "Movie", limit: 20),
            .latest(parentID: "library-6", itemTypes: "Movie", limit: 20),
            .latest(parentID: "library-7", itemTypes: "Movie", limit: 20),
            .latest(parentID: "library-8", itemTypes: "Movie", limit: 20),
        ])
        #expect(plan.entries[3].title == "Recently Added TV Shows")
        #expect(plan.entries[3].destination.title == "Recently Added TV Shows")
        #expect(plan.entries[3].destination.query.usesHomeEpisodeArtworkPolicy)
        #expect(!plan.entries[2].destination.query.usesHomeEpisodeArtworkPolicy)
        #expect(!RailViewAllQuery.mediaBrowserSearch(
            text: "episode",
            parentID: "library-2",
            itemTypes: "Episode"
        ).usesHomeEpisodeArtworkPolicy)
    }

    @Test func duplicateLibraryIDsDoNotConsumeLatestRailCap() {
        let libraries = [
            library("one"), library("one", title: "Duplicate One"),
            library("two"), library("three"), library("four"), library("five"),
            library("six"), library("seven"), library("eight"), library("nine"),
        ]
        let plan = MediaBrowserHomeRailPlan(libraries: libraries,
                                            backend: .jellyfin,
                                            sessionIdentity: "session")

        #expect(plan.latestEntries.map(\.key) == [
            .latest(libraryID: "one"), .latest(libraryID: "two"),
            .latest(libraryID: "three"), .latest(libraryID: "four"),
            .latest(libraryID: "five"), .latest(libraryID: "six"),
            .latest(libraryID: "seven"), .latest(libraryID: "eight"),
        ])
        #expect(plan.latestEntries.first?.title == "Recently Added one")
        #expect(!plan.latestEntries.contains { $0.key == .latest(libraryID: "nine") })
    }

    @Test func reverseCompletionStillReducesToCanonicalRailOrder() {
        let plan = makePlan()
        let attempt = makeAttempt()
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)

        for entry in plan.entries.reversed() {
            reducer.record(.success([item(entry.key.stableID)]),
                           for: entry.key,
                           attempt: attempt)
        }

        #expect(reducer.load.rails.map(\.id) == plan.entries.map { $0.key.stableID })
        #expect(reducer.load.rails.flatMap(\.items).map(\.ratingKey)
                == plan.entries.map { $0.key.stableID })
        #expect(reducer.load.isComplete)
        #expect(!reducer.load.isDegraded)
        #expect(reducer.load.isAuthoritative)
    }

    @Test func emptySuccessAndFailureRemainDistinct() {
        let plan = makePlan()
        let attempt = makeAttempt()
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)
        reducer.record(.success([]), for: .continueWatching, attempt: attempt)
        reducer.record(.failure(TestFailure.expected), for: .nextUp, attempt: attempt)

        if case .success(let items) = reducer.resolution(for: .continueWatching) {
            #expect(items.isEmpty)
        } else {
            Issue.record("Empty response must remain a successful resolution")
        }
        if case .failure = reducer.resolution(for: .nextUp) {
            // Expected.
        } else {
            Issue.record("Thrown request must remain a failed resolution")
        }
        if case .pending = reducer.resolution(for: .latest(libraryID: "movies")) {
            // Expected.
        } else {
            Issue.record("Unresolved request must remain pending")
        }
        #expect(reducer.load.rails.isEmpty)
        #expect(reducer.load.pendingKeys == [
            .latest(libraryID: "movies"),
            .latest(libraryID: "shows"),
        ])
        #expect(reducer.load.failedKeys == [.nextUp])
        #expect(!reducer.load.isComplete)
        #expect(reducer.load.isDegraded)
        #expect(!reducer.load.isAuthoritative)
    }

    @Test func staleAttemptOrAuthorityCannotOverwriteCurrentReduction() {
        let plan = makePlan()
        let current = makeAttempt()
        let olderSameAuthority = MediaBrowserHomeRailAttempt(authority: current.authority)
        let retiredAuthority = makeAttempt()
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: current)

        let acceptedOldGeneration = reducer.record(.success([item("old-generation")]),
                                                    for: .continueWatching,
                                                    attempt: olderSameAuthority)
        let acceptedRetiredAuthority = reducer.record(.success([item("retired-authority")]),
                                                       for: .continueWatching,
                                                       attempt: retiredAuthority)
        let acceptedCurrent = reducer.record(.success([item("current")]),
                                             for: .continueWatching,
                                             attempt: current)
        #expect(!acceptedOldGeneration)
        #expect(!acceptedRetiredAuthority)
        #expect(acceptedCurrent)
        #expect(reducer.load.rails.first?.items.first?.ratingKey == "current")
        #expect(reducer.load.pendingKeys.contains(.nextUp))

        reducer.record(.failure(TestFailure.expected), for: .nextUp, attempt: current)
        reducer.record(.success([]),
                       for: .latest(libraryID: "movies"),
                       attempt: current)
        reducer.record(.success([]),
                       for: .latest(libraryID: "shows"),
                       attempt: current)
        let retry = MediaBrowserHomeRailAttempt(authority: current.authority)
        #expect(reducer.beginFailedKeyRetry(attempt: retry) == [.nextUp])
        let acceptedLateInitial = reducer.record(.success([item("late-initial")]),
                                                 for: .nextUp,
                                                 attempt: current)
        let acceptedRetry = reducer.record(.success([item("retry")]),
                                           for: .nextUp,
                                           attempt: retry)
        #expect(!acceptedLateInitial)
        #expect(acceptedRetry)
        #expect(reducer.load.rails.map(\.id) == ["continue-watching", "next-up"])
    }

    @Test func failedKeyRetryCanBeginOnlyAfterInitialCompletionAndOnlyOnce() {
        let plan = makePlan()
        let initial = makeAttempt()
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: initial)
        reducer.record(.failure(TestFailure.expected), for: .nextUp, attempt: initial)
        let earlyRetry = MediaBrowserHomeRailAttempt(authority: initial.authority)
        let earlyLoad = reducer.load

        #expect(reducer.beginFailedKeyRetry(attempt: earlyRetry).isEmpty)
        #expect(reducer.attempt == initial)
        #expect(reducer.load.failedKeys == earlyLoad.failedKeys)
        #expect(reducer.load.pendingKeys == earlyLoad.pendingKeys)

        reducer.record(.success([]), for: .continueWatching, attempt: initial)
        reducer.record(.success([]),
                       for: .latest(libraryID: "movies"),
                       attempt: initial)
        reducer.record(.success([]),
                       for: .latest(libraryID: "shows"),
                       attempt: initial)
        let retry = MediaBrowserHomeRailAttempt(authority: initial.authority)
        #expect(reducer.beginFailedKeyRetry(attempt: retry) == [.nextUp])
        reducer.record(.failure(TestFailure.expected), for: .nextUp, attempt: retry)

        let forbiddenThirdPass = MediaBrowserHomeRailAttempt(authority: initial.authority)
        #expect(reducer.beginFailedKeyRetry(attempt: forbiddenThirdPass).isEmpty)
        #expect(reducer.attempt == retry)
        #expect(reducer.load.failedKeys == [.nextUp])
        #expect(reducer.load.isTerminal)
    }

    @Test func allAtOnceReductionMatchesExistingHomeOutputContract() throws {
        let plan = makePlan()
        let attempt = makeAttempt()
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)
        let resume = item("resume")
        let latestShows = item("latest-shows")

        reducer.record(.success([resume]), for: .continueWatching, attempt: attempt)
        reducer.record(.success([]), for: .nextUp, attempt: attempt)
        reducer.record(.failure(TestFailure.expected),
                       for: .latest(libraryID: "movies"),
                       attempt: attempt)
        reducer.record(.success([latestShows]),
                       for: .latest(libraryID: "shows"),
                       attempt: attempt)

        let load = reducer.load
        #expect(load.isComplete)
        #expect(load.isDegraded)
        #expect(!load.isAuthoritative)
        #expect(load.pendingKeys.isEmpty)
        #expect(load.failedKeys == [.latest(libraryID: "movies")])
        #expect(load.rails.map(\.id) == ["continue-watching", "latest-shows"])
        #expect(load.rails.map(\.title) == ["Continue Watching", "Recently Added TV Shows"])
        #expect(load.rails.map { $0.items.map(\.ratingKey) } == [["resume"], ["latest-shows"]])

        let resumeDestination = try #require(load.rails[0].destination)
        #expect(resumeDestination.title == "Continue Watching")
        #expect(resumeDestination.backend == .emby)
        #expect(resumeDestination.sessionIdentity == "session")
        #expect(resumeDestination.query == .mediaBrowserResume(parentID: nil))

        let latestDestination = try #require(load.rails[1].destination)
        #expect(latestDestination.title == "Recently Added TV Shows")
        #expect(latestDestination.backend == .emby)
        #expect(latestDestination.sessionIdentity == "session")
        #expect(latestDestination.query == .mediaBrowserRecentlyAdded(parentID: "shows",
                                                                      itemTypes: "Episode"))
    }

    @Test func providerPublishesEveryResolutionProgressivelyInCanonicalOrderAtOneTotalBound() async throws {
        let harness = try makeProviderHarness()
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task {
            try await harness.provider.loadHome { recorder.record($0) }
        }

        await waitUntil("catalog request") { await harness.catalog.startedCount == 1 }
        #expect(await harness.browser.started.isEmpty)
        await harness.catalog.succeed(with: providerCatalogDescriptors())

        await waitUntil("initial total rail window") { await harness.browser.started.count == 4 }
        #expect(Set(await harness.browser.started) == Set([
            .resume, .nextUp, .latest("one"), .latest("two"),
        ]))
        #expect(await harness.browser.maximumTotalInFlight
                == MediaBrowserHomeProvider.maximumConcurrentRailRequests)

        // Keep the first/global work slow while later Latest work finishes quickly. Every
        // completion opens one slot and emits one ordered snapshot.
        for (snapshotIndex, id) in ["two", "three", "four", "five", "six", "seven"].enumerated() {
            let previousStarted = await harness.browser.started.count
            await harness.browser.succeed(.latest(id), with: [item("latest-\(id)")])
            await waitUntil("progressive snapshot \(snapshotIndex + 1)") {
                recorder.snapshots.count == snapshotIndex + 1
            }
            await waitUntil("replacement rail request") {
                await harness.browser.started.count == previousStarted + 1
            }
        }

        let expectedLatest = Set(["one", "two", "three", "four",
                                  "five", "six", "seven", "eight"])
        #expect(Set(await harness.browser.latestStarted) == expectedLatest)
        #expect(await harness.browser.maximumTotalInFlight == 4)
        #expect(!Set(await harness.browser.latestStarted).contains("hidden"))
        #expect(!Set(await harness.browser.latestStarted).contains("nine"))

        for request in [
            HomeControlledBrowser.Request.latest("eight"),
            .latest("one"),
            .nextUp,
            .resume,
        ] {
            switch request {
            case .resume:
                await harness.browser.succeed(request, with: [item("resume")])
            case .nextUp:
                await harness.browser.succeed(request, with: [])
            case .latest(let id):
                await harness.browser.succeed(request, with: [item("latest-\(id)")])
            }
        }

        let content = try await load.value
        #expect(recorder.snapshots.count == 10)
        #expect(recorder.snapshots.map { $0.pendingRailKeys.count } == Array(stride(from: 9,
                                                                                    through: 0,
                                                                                    by: -1)))
        #expect(Set(recorder.snapshots.map { Set($0.pendingRailKeys) }).count == 10)
        let canonicalIDs = [
            "continue-watching", "next-up", "latest-one", "latest-two", "latest-three",
            "latest-four", "latest-five", "latest-six", "latest-seven", "latest-eight",
        ]
        let canonicalIndex = Dictionary(uniqueKeysWithValues: canonicalIDs.enumerated().map {
            ($0.element, $0.offset)
        })
        for snapshot in recorder.snapshots {
            let indexes = snapshot.rails.compactMap { canonicalIndex[$0.id] }
            #expect(indexes == indexes.sorted())
        }
        #expect(recorder.snapshots.first?.rails.map(\.id) == ["latest-two"])
        #expect(recorder.snapshots[6].rails.map(\.id) == [
            "latest-two", "latest-three", "latest-four", "latest-five", "latest-six",
            "latest-seven", "latest-eight",
        ])
        #expect(recorder.snapshots[7].rails.map(\.id) == [
            "latest-one", "latest-two", "latest-three", "latest-four", "latest-five",
            "latest-six", "latest-seven", "latest-eight",
        ])
        #expect(await harness.catalog.startedCount == 1)
        #expect(await harness.browser.count(of: .resume) == 1)
        #expect(await harness.browser.count(of: .nextUp) == 1)
        #expect(content.isComplete)
        #expect(!content.isDegraded)
        #expect(content.isAuthoritative)
        #expect(content.pendingRailKeys.isEmpty)
        #expect(content.failedRailKeys.isEmpty)
        #expect(content.rails.map(\.id) == [
            "continue-watching", "latest-one", "latest-two", "latest-three", "latest-four",
            "latest-five", "latest-six", "latest-seven", "latest-eight",
        ])
        #expect(content.rails.flatMap(\.items).map(\.ratingKey) == [
            "resume", "latest-one", "latest-two", "latest-three", "latest-four",
            "latest-five", "latest-six", "latest-seven", "latest-eight",
        ])
    }

    @Test func failedKeyRetryRequestsOnlyFailuresAndRetainsSuccessfulRails() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [descriptor("one")])
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("three planned requests") { await harness.browser.started.count == 3 }

        await harness.browser.fail(.latest("one"))
        await waitUntil("failed snapshot") { recorder.snapshots.count == 1 }
        await harness.browser.succeed(.resume, with: [item("resume")])
        await waitUntil("successful snapshot") { recorder.snapshots.count == 2 }
        await harness.browser.succeed(.nextUp, with: [])

        await waitUntil("failed-key retry") {
            await harness.browser.count(of: .latest("one")) == 2
        }
        #expect(recorder.snapshots.count == 4)
        #expect(await harness.browser.count(of: .resume) == 1)
        #expect(await harness.browser.count(of: .nextUp) == 1)
        #expect(recorder.snapshots[2].rails.map(\.id) == ["continue-watching"])
        #expect(recorder.snapshots[2].failedRailKeys == [.latest(libraryID: "one")])
        #expect(recorder.snapshots[2].hasFailedKeyRetryRemaining)
        #expect(recorder.snapshots[3].rails.map(\.id) == ["continue-watching"])
        #expect(recorder.snapshots[3].pendingRailKeys == [.latest(libraryID: "one")])
        #expect(!recorder.snapshots[3].hasFailedKeyRetryRemaining)
        await harness.browser.succeed(.latest("one"), with: [item("retry-one")])

        let content = try await load.value
        #expect(recorder.snapshots.count == 5)
        #expect(recorder.snapshots[0].failedRailKeys == [.latest(libraryID: "one")])
        #expect(recorder.snapshots[0].pendingRailKeys == [.continueWatching, .nextUp])
        #expect(recorder.snapshots[1].rails.map(\.id) == ["continue-watching"])
        #expect(recorder.snapshots[1].failedRailKeys == [.latest(libraryID: "one")])
        #expect(recorder.snapshots[3].attempt != recorder.snapshots[2].attempt)
        #expect(recorder.snapshots[4].attempt == recorder.snapshots[3].attempt)
        #expect(content.rails.map(\.id) == ["continue-watching", "latest-one"])
        #expect(content.isComplete)
        #expect(!content.isDegraded)
        #expect(content.isAuthoritative)
    }

    @Test func failedKeyRetryRetainsSiblingSuccessWhenRetryStillFails() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [descriptor("one"),
                                                                   descriptor("two")])
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("four initial requests") { await harness.browser.started.count == 4 }

        await harness.browser.succeed(.resume, with: [item("resume")])
        await harness.browser.succeed(.nextUp, with: [])
        await harness.browser.fail(.latest("one"))
        await harness.browser.succeed(.latest("two"), with: [item("two")])
        await waitUntil("only failed key retried") {
            await harness.browser.count(of: .latest("one")) == 2
        }
        #expect(await harness.browser.count(of: .latest("two")) == 1)
        await harness.browser.fail(.latest("one"))

        let content = try await load.value
        #expect(content.rails.map(\.id) == ["continue-watching", "latest-two"])
        #expect(content.failedRailKeys == [.latest(libraryID: "one")])
        #expect(content.isComplete)
        #expect(content.isDegraded)
        #expect(!content.isAuthoritative)
        #expect(recorder.snapshots.last?.rails.map(\.id)
                == ["continue-watching", "latest-two"])
    }

    @Test func failedKeyRetryRejectsRetiredAuthorityWithoutPublishing() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [descriptor("one")])
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("initial requests") { await harness.browser.started.count == 3 }
        await harness.browser.succeed(.resume, with: [item("resume")])
        await harness.browser.succeed(.nextUp, with: [])
        await harness.browser.fail(.latest("one"))
        await waitUntil("failed-key retry") {
            await harness.browser.count(of: .latest("one")) == 2
        }
        #expect(recorder.snapshots.count == 4)

        harness.model.identity = PlatformClientIdentity.make(
            clientIdentifier: "retry-retired-identity"
        )
        await harness.browser.succeed(.latest("one"), with: [item("stale-retry")])

        do {
            _ = try await load.value
            Issue.record("Retired authority must reject failed-key retry publication")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(recorder.snapshots.count == 4)
        #expect(recorder.snapshots.last?.pendingRailKeys == [.latest(libraryID: "one")])
        #expect(recorder.snapshots.last?.failedRailKeys.isEmpty == true)
    }

    @Test func allInitialFailuresKeepSkeletonWhileRetryIsHeldThenPublishTerminalFailure() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [])
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("two initial global rails") { await harness.browser.started.count == 2 }

        await harness.browser.fail(.resume)
        await harness.browser.fail(.nextUp)
        await waitUntil("held retry phase") {
            let resumeCount = await harness.browser.count(of: .resume)
            let nextUpCount = await harness.browser.count(of: .nextUp)
            return resumeCount == 2 && nextUpCount == 2
        }

        let retryPending = try #require(recorder.snapshots.last)
        #expect(retryPending.rails.isEmpty)
        #expect(retryPending.pendingRailKeys == [.continueWatching, .nextUp])
        #expect(retryPending.failedRailKeys.isEmpty)
        #expect(!retryPending.hasFailedKeyRetryRemaining)
        #expect(!retryPending.isTerminal)
        #expect(!MediaBrowserHomePublicationPolicy.shouldShowLoadedState(retryPending))

        await harness.browser.fail(.resume)
        await harness.browser.fail(.nextUp)
        let terminal = try await load.value
        #expect(terminal.rails.isEmpty)
        #expect(terminal.failedRailKeys == [.continueWatching, .nextUp])
        #expect(terminal.isTerminal)
        #expect(MediaBrowserHomePublicationPolicy.shouldShowLoadedState(terminal))
    }

    @Test func forceRefreshReloadsCatalogAndEveryPlannedRail() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [descriptor("one")])
        defer { harness.removeDefaults() }

        let first = Task { try await harness.provider.loadHome() }
        await waitUntil("first full rail plan") { await harness.browser.started.count == 3 }
        await harness.browser.succeed(.resume, with: [item("resume-first")])
        await harness.browser.succeed(.nextUp, with: [])
        await harness.browser.succeed(.latest("one"), with: [item("latest-first")])
        _ = try await first.value
        #expect(await harness.catalog.startedCount == 1)

        let forced = Task { try await harness.provider.loadHome(forceRefresh: true) }
        await waitUntil("forced catalog read") { await harness.catalog.startedCount == 2 }
        #expect(await harness.browser.started.count == 3)
        await harness.catalog.succeed(with: [descriptor("one")])
        await waitUntil("forced full rail plan") { await harness.browser.started.count == 6 }
        #expect(await harness.browser.count(of: .resume) == 2)
        #expect(await harness.browser.count(of: .nextUp) == 2)
        #expect(await harness.browser.count(of: .latest("one")) == 2)

        await harness.browser.succeed(.resume, with: [item("resume-forced")])
        await harness.browser.succeed(.nextUp, with: [])
        await harness.browser.succeed(.latest("one"), with: [item("latest-forced")])
        let content = try await forced.value
        #expect(content.rails.flatMap(\.items).map(\.ratingKey)
                == ["resume-forced", "latest-forced"])
        #expect(content.isAuthoritative)
    }

    @Test func failedKeyRetryUsesSameFourRequestWindowForMoreThanFourFailures() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: providerCatalogDescriptors())
        defer { harness.removeDefaults() }
        let load = Task { try await harness.provider.loadHome() }
        let plannedCount = 10
        await waitUntil("initial rail window") { await harness.browser.started.count == 4 }

        // Advance the initial pass one failure at a time until all ten planned keys have started.
        for expectedStartedCount in 5...plannedCount {
            let activeRequests = await harness.browser.activeRequests
            let request = try #require(activeRequests.first)
            await harness.browser.fail(request)
            await waitUntil("initial request \(expectedStartedCount)") {
                await harness.browser.started.count == expectedStartedCount
            }
        }
        let finalInitialWindow = await harness.browser.activeRequests
        for request in finalInitialWindow.dropLast() {
            await harness.browser.fail(request)
        }
        await harness.browser.fail(try #require(finalInitialWindow.last))

        await waitUntil("retry four-request window") {
            let startedCount = await harness.browser.started.count
            let activeCount = await harness.browser.activeRequests.count
            return startedCount == plannedCount + 4 && activeCount == 4
        }
        #expect(await harness.browser.maximumTotalInFlight
                == MediaBrowserHomeProvider.maximumConcurrentRailRequests)

        // Completing one retry opens exactly one slot until the full failed-key set has run.
        for expectedStartedCount in (plannedCount + 5)...(plannedCount * 2) {
            let activeRequests = await harness.browser.activeRequests
            let request = try #require(activeRequests.first)
            await harness.browser.succeed(request, with: [item("retried")])
            await waitUntil("retry request \(expectedStartedCount)") {
                await harness.browser.started.count == expectedStartedCount
            }
        }
        for request in await harness.browser.activeRequests {
            await harness.browser.succeed(request, with: [item("retried")])
        }
        let content = try await load.value
        #expect(await harness.browser.started.count == plannedCount * 2)
        #expect(await harness.browser.maximumTotalInFlight == 4)
        #expect(content.isAuthoritative)
    }

    @Test func cancellationDuringFailedKeyRetryPublishesNoRetryCompletion() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [descriptor("one")])
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("initial plan") { await harness.browser.started.count == 3 }
        await harness.browser.fail(.resume)
        await harness.browser.fail(.nextUp)
        await harness.browser.fail(.latest("one"))
        await waitUntil("retry plan") { await harness.browser.started.count == 6 }
        let snapshotCountBeforeCancellation = recorder.snapshots.count

        load.cancel()
        for request in await harness.browser.activeRequests {
            await harness.browser.succeed(request, with: [item("cancelled-retry")])
        }
        do {
            _ = try await load.value
            Issue.record("Cancellation during retry must not return Home content")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(recorder.snapshots.count == snapshotCountBeforeCancellation)
    }

    @Test func providerDiscardsCompletionAfterClientIdentityRetiresOpaqueAuthority() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: [descriptor("one")])
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("planned requests") { await harness.browser.started.count == 3 }

        let oldSessionKey = harness.model.activeBrowseSessionKey
        let oldLoadIdentity = AuthenticatedBrowseLoadIdentity(appModel: harness.model)
        harness.model.identity = PlatformClientIdentity.make(
            clientIdentifier: "home-provider-replacement-identity"
        )
        let replacementLoadIdentity = AuthenticatedBrowseLoadIdentity(appModel: harness.model)
        #expect(harness.model.activeBrowseSessionKey == oldSessionKey)
        #expect(replacementLoadIdentity != oldLoadIdentity)
        for request in await harness.browser.activeRequests {
            await harness.browser.succeed(request, with: [item("stale")])
        }

        do {
            _ = try await load.value
            Issue.record("Retired authority must not publish Home content")
        } catch is CancellationError {
            // Expected final authority fence.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(recorder.snapshots.isEmpty)
    }

    @Test func providerCancellationCannotReturnPartialContent() async throws {
        let harness = try makeProviderHarness(catalogDescriptors: providerCatalogDescriptors())
        defer { harness.removeDefaults() }
        let recorder = HomeSnapshotRecorder()
        let load = Task { try await harness.provider.loadHome { recorder.record($0) } }
        await waitUntil("bounded requests") { await harness.browser.started.count == 4 }
        load.cancel()
        for request in await harness.browser.activeRequests {
            await harness.browser.succeed(request, with: [item("cancelled")])
        }

        do {
            _ = try await load.value
            Issue.record("Cancelled Home load must not return partial content")
        } catch is CancellationError {
            // Expected; cancelled queued work is never submitted or published.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(recorder.snapshots.isEmpty)
        #expect(await harness.browser.started.count == 4)
    }

    @Test func homePublicationPolicyPreservesSkeletonUntilVisibleOrCompleteAndPinsOnlyAuthoritative() throws {
        let plan = MediaBrowserHomeRailPlan(libraries: [], backend: .emby,
                                            sessionIdentity: "session")
        let attempt = makeAttempt()
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)

        let pending = content(from: reducer.load)
        #expect(!MediaBrowserHomePublicationPolicy.shouldShowLoadedState(pending))
        #expect(!MediaBrowserHomePublicationPolicy.shouldPin(pending))

        var emptyPendingReducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)
        emptyPendingReducer.record(.success([]), for: .continueWatching, attempt: attempt)
        let emptyPending = content(from: emptyPendingReducer.load)
        #expect(!MediaBrowserHomePublicationPolicy.shouldShowLoadedState(emptyPending))
        #expect(!MediaBrowserHomePublicationPolicy.shouldPin(emptyPending))

        var failedPendingReducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)
        failedPendingReducer.record(.failure(TestFailure.expected),
                                    for: .continueWatching,
                                    attempt: attempt)
        let failedPending = content(from: failedPendingReducer.load)
        #expect(!MediaBrowserHomePublicationPolicy.shouldShowLoadedState(failedPending))
        #expect(!MediaBrowserHomePublicationPolicy.shouldPin(failedPending))

        reducer.record(.success([item("visible")]),
                       for: .continueWatching,
                       attempt: attempt)
        let partialVisible = content(from: reducer.load)
        #expect(MediaBrowserHomePublicationPolicy.shouldShowLoadedState(partialVisible))
        #expect(!MediaBrowserHomePublicationPolicy.shouldPin(partialVisible))

        var failedReducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)
        failedReducer.record(.success([]), for: .continueWatching, attempt: attempt)
        failedReducer.record(.failure(TestFailure.expected), for: .nextUp, attempt: attempt)
        let recoverableFailure = content(from: failedReducer.load)
        #expect(!MediaBrowserHomePublicationPolicy.shouldShowLoadedState(recoverableFailure))
        #expect(!MediaBrowserHomePublicationPolicy.shouldPin(recoverableFailure))
        let retry = MediaBrowserHomeRailAttempt(authority: attempt.authority)
        #expect(failedReducer.beginFailedKeyRetry(attempt: retry) == [.nextUp])
        let retryPending = content(from: failedReducer.load)
        #expect(!MediaBrowserHomePublicationPolicy.shouldShowLoadedState(retryPending))
        failedReducer.record(.failure(TestFailure.expected), for: .nextUp, attempt: retry)
        let persistentFailure = content(from: failedReducer.load)
        #expect(MediaBrowserHomePublicationPolicy.shouldShowLoadedState(persistentFailure))
        #expect(!MediaBrowserHomePublicationPolicy.shouldPin(persistentFailure))

        var cleanReducer = MediaBrowserHomeRailReducer(plan: plan, attempt: attempt)
        cleanReducer.record(.success([]), for: .continueWatching, attempt: attempt)
        cleanReducer.record(.success([]), for: .nextUp, attempt: attempt)
        let clean = content(from: cleanReducer.load)
        #expect(MediaBrowserHomePublicationPolicy.shouldShowLoadedState(clean))
        #expect(MediaBrowserHomePublicationPolicy.shouldPin(clean))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/HomeView.swift"), encoding: .utf8)
        #expect(source.contains("loadHome(forceRefresh: force) { snapshot in"))
        #expect(source.contains("MediaBrowserHomePublicationPolicy.shouldShowLoadedState"))
        #expect(source.contains("? .loaded : .loading"))
        #expect(source.contains("MediaBrowserHomePublicationPolicy.shouldPin"))
        #expect(source.contains(".task(id: loadIdentity)"))
    }

    private func makePlan() -> MediaBrowserHomeRailPlan {
        MediaBrowserHomeRailPlan(
            libraries: [
                MediaBrowserHomeLibraryLink(id: "movies", title: "Movies",
                                            collectionType: "movies"),
                MediaBrowserHomeLibraryLink(id: "shows", title: "Shows",
                                            collectionType: "tvshows"),
            ],
            backend: .emby,
            sessionIdentity: "session"
        )
    }

    private func item(_ id: String) -> MediaItem {
        MediaItem(ratingKey: id, title: id, type: "movie")
    }

    private func library(_ id: String, title: String? = nil) -> MediaBrowserHomeLibraryLink {
        MediaBrowserHomeLibraryLink(id: id, title: title ?? id, collectionType: "movies")
    }

    private func makeAttempt() -> MediaBrowserHomeRailAttempt {
        MediaBrowserHomeRailAttempt(authority: BrowseSessionAuthority())
    }

    private func content(from load: MediaBrowserHomeRailLoad) -> MediaBrowserHomeContent {
        MediaBrowserHomeContent(libraries: [],
                                rails: load.rails,
                                attempt: load.attempt,
                                pendingRailKeys: load.pendingKeys,
                                failedRailKeys: load.failedKeys,
                                hasFailedKeyRetryRemaining: load.hasFailedKeyRetryRemaining)
    }

    private func makeProviderHarness(
        catalogDescriptors: [LibraryCatalogDescriptor]? = nil
    ) throws -> HomeProviderHarness {
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "home-provider-execution"),
            activeBackend: .jellyfin
        )
        model.applyMediaBrowserSession(
            backend: .jellyfin,
            server: URL(string: "https://jellyfin.example.test")!,
            token: "token",
            userID: "user",
            serverID: "server"
        )
        let context = try #require(model.activeAuthenticatedBrowseSession)
        let catalog = HomeControlledCatalog()
        let repository = LibraryCatalogRepository()
        let loader = LibraryCatalogLoader(backend: context.backend,
                                          authority: context.authority) {
            try await catalog.fetch()
        }
        let request = repository.request(appModel: model, context: context, loader: loader)
        let browser = HomeControlledBrowser()

        let defaultsSuiteName = "MediaBrowserHomeProviderTests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let visibilityStore = LibraryVisibilityStore(defaults: defaults)
        visibilityStore.setHiddenIDs(["hidden"],
                                     forBackendKey: model.libraryVisibilityBackendKey)
        let provider = MediaBrowserHomeProvider(appModel: model,
                                                browser: browser,
                                                catalogRepository: repository,
                                                catalogRequest: request,
                                                visibilityStore: visibilityStore)
        let harness = HomeProviderHarness(model: model,
                                          provider: provider,
                                          catalog: catalog,
                                          browser: browser,
                                          defaultsSuiteName: defaultsSuiteName)
        if let catalogDescriptors {
            Task { await catalog.succeedWhenStarted(with: catalogDescriptors) }
        }
        return harness
    }

    private func providerCatalogDescriptors() -> [LibraryCatalogDescriptor] {
        [
            descriptor("hidden"), descriptor("one"),
            descriptor("one", title: "Duplicate One"),
            descriptor("two"), descriptor("three"), descriptor("four"),
            descriptor("five"), descriptor("six"), descriptor("seven"),
            descriptor("eight"), descriptor("nine"),
        ]
    }

    private func descriptor(_ id: String, title: String? = nil) -> LibraryCatalogDescriptor {
        LibraryCatalogDescriptor(
            mediaBrowser: MediaBrowserLibraryLink(id: id,
                                                  title: title ?? id,
                                                  collectionType: "movies"),
            backend: .jellyfin
        )
    }

    private func waitUntil(_ description: String,
                           _ predicate: @escaping () async -> Bool) async {
        for _ in 0..<2_000 {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(description)")
    }

    private enum TestFailure: Error {
        case expected
    }
}

@MainActor
private struct HomeProviderHarness {
    let model: AppModel
    let provider: MediaBrowserHomeProvider
    let catalog: HomeControlledCatalog
    let browser: HomeControlledBrowser
    let defaultsSuiteName: String

    func removeDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}

@MainActor
private final class HomeSnapshotRecorder {
    private(set) var snapshots: [MediaBrowserHomeContent] = []

    func record(_ content: MediaBrowserHomeContent) {
        snapshots.append(content)
    }
}

private actor HomeControlledCatalog {
    private(set) var startedCount = 0
    private var continuation: CheckedContinuation<[LibraryCatalogDescriptor], Error>?

    func fetch() async throws -> [LibraryCatalogDescriptor] {
        startedCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(with descriptors: [LibraryCatalogDescriptor]) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: descriptors)
    }

    func succeedWhenStarted(with descriptors: [LibraryCatalogDescriptor]) async {
        while startedCount == 0 { await Task.yield() }
        succeed(with: descriptors)
    }
}

@MainActor
private final class HomeControlledBrowser: MediaBrowserHomeBrowsing {
    enum Request: Hashable, Sendable {
        case resume
        case nextUp
        case latest(String)
    }

    private let state = HomeControlledBrowserState()

    var started: [Request] { get async { await state.started } }
    var latestStarted: [String] { get async { await state.latestStarted } }
    var activeLatest: [String] { get async { await state.activeLatest } }
    var maximumLatestInFlight: Int { get async { await state.maximumLatestInFlight } }
    var activeRequests: [Request] { get async { await state.activeRequests } }
    var maximumTotalInFlight: Int { get async { await state.maximumTotalInFlight } }

    func count(of request: Request) async -> Int {
        await state.count(of: request)
    }

    func succeed(_ request: Request, with items: [MediaItem]) async {
        await state.succeed(request, with: items)
    }

    func fail(_ request: Request) async {
        await state.fail(request)
    }

    func homeResumeItems(limit: Int) async throws -> [MediaItem] {
        #expect(limit == 20)
        return try await state.perform(.resume)
    }

    func homeNextUp(limit: Int) async throws -> [MediaItem] {
        #expect(limit == 20)
        return try await state.perform(.nextUp)
    }

    func homeLatestItems(parentId: String,
                         includeItemTypes: String,
                         limit: Int) async throws -> [MediaItem] {
        #expect(includeItemTypes == "Movie")
        #expect(limit == 20)
        return try await state.perform(.latest(parentId))
    }
}

private actor HomeControlledBrowserState {
    typealias Request = HomeControlledBrowser.Request

    private(set) var started: [Request] = []
    private(set) var latestStarted: [String] = []
    private(set) var activeLatest: [String] = []
    private(set) var maximumLatestInFlight = 0
    private(set) var activeRequests: [Request] = []
    private(set) var maximumTotalInFlight = 0
    private var continuations: [Request: CheckedContinuation<[MediaItem], Error>] = [:]

    func perform(_ request: Request) async throws -> [MediaItem] {
        started.append(request)
        activeRequests.append(request)
        maximumTotalInFlight = max(maximumTotalInFlight, activeRequests.count)
        if case .latest(let id) = request {
            latestStarted.append(id)
            activeLatest.append(id)
            maximumLatestInFlight = max(maximumLatestInFlight, activeLatest.count)
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func count(of request: Request) -> Int {
        started.count { $0 == request }
    }

    func succeed(_ request: Request, with items: [MediaItem]) {
        guard let continuation = continuations.removeValue(forKey: request) else { return }
        removeActive(request)
        continuation.resume(returning: items)
    }

    func fail(_ request: Request) {
        guard let continuation = continuations.removeValue(forKey: request) else { return }
        removeActive(request)
        continuation.resume(throwing: Failure.expected)
    }

    private func removeActive(_ request: Request) {
        activeRequests.removeAll { $0 == request }
        if case .latest(let id) = request {
            activeLatest.removeAll { $0 == id }
        }
    }

    private enum Failure: Error {
        case expected
    }
}
