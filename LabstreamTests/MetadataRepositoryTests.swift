import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Metadata repository")
@MainActor
struct MetadataRepositoryTests {
    @Test func staleDisplayReturnsImmediatelyStartsOneRefreshAndPublishesFreshResult() async throws {
        let clock = ManualTestClock(nowNanoseconds: 0)
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository(freshDisplayTTLNanoseconds: 10,
                                            staleDisplayTTLNanoseconds: 100,
                                            now: { clock.nowNanoseconds })
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let initial = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("item", title: "initial"))
        #expect(try await initial.value.provenance.delivery == .nativeRead)

        clock.advance(toNanoseconds: 10)
        let stale = try await repository.metadata(for: request, policy: .display)
        #expect(stale.item.title == "initial")
        #expect(stale.provenance.delivery == .staleWhileRevalidate)
        await fetch.waitUntilStarted(count: 2)

        let anotherStale = try await repository.metadata(for: request, policy: .display)
        #expect(anotherStale.provenance.delivery == .staleWhileRevalidate)
        #expect(await fetch.startedCount == 2)

        // An authoritative caller joins that exact native refresh instead of accepting stale.
        let authoritative = Task {
            try await repository.metadata(for: request, policy: .authoritative)
        }
        await fetch.succeed(attempt: 1, item: item("item", title: "refreshed"))
        #expect(try await authoritative.value.item.title == "refreshed")
        #expect(try await authoritative.value.provenance.delivery == .nativeRead)

        let fresh = try await repository.metadata(for: request, policy: .display)
        #expect(fresh.item.title == "refreshed")
        #expect(fresh.provenance.delivery == .freshDisplayReuse)
        #expect(await fetch.startedCount == 2)
    }

    @Test func failedBackgroundRefreshKeepsBoundedStaleValueAndRetries() async throws {
        let clock = ManualTestClock(nowNanoseconds: 0)
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository(freshDisplayTTLNanoseconds: 5,
                                            staleDisplayTTLNanoseconds: 20,
                                            now: { clock.nowNanoseconds })
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let initial = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("item", title: "stale-safe"))
        _ = try await initial.value

        clock.advance(toNanoseconds: 5)
        #expect(try await repository.metadata(for: request, policy: .display).item.title == "stale-safe")
        await fetch.waitUntilStarted(count: 2)
        let failedJoin = Task {
            try await repository.metadata(for: request, policy: .authoritative)
        }
        await Task.yield()
        await fetch.fail(attempt: 1, error: BackendFailure.http(503))
        do {
            _ = try await failedJoin.value
            Issue.record("The joined failed refresh must preserve its backend error")
        } catch let error as BackendFailure {
            #expect(error == .http(503))
        }

        let retryStale = try await repository.metadata(for: request, policy: .display)
        #expect(retryStale.item.title == "stale-safe")
        #expect(retryStale.provenance.delivery == .staleWhileRevalidate)
        await fetch.waitUntilStarted(count: 3)

        // Once the bounded stale deadline passes, display can no longer paint the old value and
        // instead joins the exact refresh already in flight.
        clock.advance(toNanoseconds: 20)
        let expired = Task { try await repository.metadata(for: request, policy: .display) }
        await Task.yield()
        await fetch.succeed(attempt: 2, item: item("item", title: "recovered"))
        #expect(try await expired.value.item.title == "recovered")
        #expect(try await expired.value.provenance.delivery == .nativeRead)
    }

    @Test func watchedPatchSurvivesOlderFlightButNewerAuthoritativeReadSupersedesIt() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let olderFlight = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        repository.patchWatchedState(backend: context.backend,
                                     authority: context.authority,
                                     itemID: "item",
                                     played: true)
        await fetch.succeed(attempt: 0,
                            item: MediaItem(ratingKey: "item", title: "old", type: "movie",
                                            viewCount: 0, summary: "preserved"))
        let patched = try await olderFlight.value
        #expect(patched.item.viewCount == 1)
        #expect(patched.item.summary == "preserved")
        #expect(patched.provenance.watchedStatePatched)
        #expect(!patched.provenance.mayAuthorizeActions)

        let cached = try await repository.metadata(for: request, policy: .display)
        #expect(cached.item.viewCount == 1)
        #expect(cached.provenance.delivery == .freshDisplayReuse)
        #expect(cached.provenance.watchedStatePatched)

        let newer = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await fetch.waitUntilStarted(count: 2)
        await fetch.succeed(attempt: 1,
                            item: MediaItem(ratingKey: "item", title: "new", type: "movie",
                                            viewCount: 0, summary: "server truth"))
        let authoritative = try await newer.value
        #expect(authoritative.item.viewCount == 0)
        #expect(authoritative.item.summary == "server truth")
        #expect(!authoritative.provenance.watchedStatePatched)
        #expect(authoritative.provenance.mayAuthorizeActions)
    }

    @Test func watchedPatchUpdatesCachedFullItemWithoutStartingOrAuthorizingARead() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: context, itemID: "item", fetch: fetch)
        let original = MediaItem(ratingKey: "item", title: "full", type: "movie",
                                 viewCount: 0, summary: "keep me",
                                 providerIds: ["imdb": "tt123"])

        let initial = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: original)
        _ = try await initial.value

        repository.patchWatchedState(backend: context.backend,
                                     authority: context.authority,
                                     itemID: "item",
                                     played: true)
        let patched = try await repository.metadata(for: request, policy: .display)
        #expect(patched.item.viewCount == 1)
        #expect(patched.item.summary == "keep me")
        #expect(patched.item.providerIds?["imdb"] == "tt123")
        #expect(patched.provenance.delivery == .freshDisplayReuse)
        #expect(patched.provenance.watchedStatePatched)
        #expect(!patched.provenance.mayAuthorizeActions)
        #expect(await fetch.startedCount == 1)
    }

    @Test func watchedPatchAfterPublicationBeforeWaiterDeliveryCannotLookAuthoritative() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let fetch = ControlledMetadataFetch()
        let delivery = ControlledMetadataDeliveryGate()
        let repository = MetadataRepository(beforeNativeDelivery: { await delivery.hold() })
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let waiter = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0,
                            item: MediaItem(ratingKey: "item", title: "native", type: "movie",
                                            viewCount: 0))
        await delivery.waitUntilHeld()
        // The native task has already published, but its waiter has not resumed yet.
        repository.patchWatchedState(backend: context.backend,
                                     authority: context.authority,
                                     itemID: "item",
                                     played: true)
        delivery.open()

        let delivered = try await waiter.value
        #expect(delivered.item.viewCount == 1)
        #expect(delivered.provenance.watchedStatePatched)
        #expect(!repository.mayAuthorizeAction(delivered,
                                              appModel: fixture.model,
                                              backend: context.backend,
                                              itemID: "item"))
    }

    @Test func watchedCompletionAfterVersionSwitchPatchesOnlyMutatedVersion() async throws {
        let fixture = try makeModelContext()
        let repository = MetadataRepository()
        let versionARequest = repository.request(
            context: fixture.context,
            itemID: "version-a",
            load: { MediaItem(ratingKey: "version-a", title: "A", type: "movie", viewCount: 0) })
        let versionBRequest = repository.request(
            context: fixture.context,
            itemID: "version-b",
            load: { MediaItem(ratingKey: "version-b", title: "B", type: "movie", viewCount: 0) })
        _ = try await repository.metadata(for: versionARequest, policy: .display)
        _ = try await repository.metadata(for: versionBRequest, policy: .display)

        let target = DetailWatchedMutationTarget(
            backend: fixture.context.backend,
            authority: fixture.context.authority,
            itemID: "version-a",
            detailVersionID: "version-a")
        let completionGate = ControlledMetadataDeliveryGate()
        var selectedVersionID = "version-a"
        var detailedItemID = "version-a"
        let mutationCompletion = Task { @MainActor in
            await completionGate.hold()
            repository.patchWatchedState(backend: target.backend,
                                         authority: target.authority,
                                         itemID: target.itemID,
                                         played: true)
            return target.isStillMounted(
                backend: fixture.context.backend,
                authority: fixture.model
                    .authenticatedBrowseSession(for: fixture.context.backend)?.authority,
                activeVersionID: selectedVersionID,
                detailedItemID: detailedItemID)
        }
        await completionGate.waitUntilHeld()

        // Simulate selecting collapsed version B while version A's watched request is in flight.
        selectedVersionID = "version-b"
        detailedItemID = "version-b"
        completionGate.open()

        #expect(await mutationCompletion.value == false)
        let versionA = try await repository.metadata(for: versionARequest, policy: .display)
        let versionB = try await repository.metadata(for: versionBRequest, policy: .display)
        #expect(versionA.item.viewCount == 1)
        #expect(versionA.provenance.watchedStatePatched)
        #expect(versionB.item.viewCount == 0)
        #expect(!versionB.provenance.watchedStatePatched)
    }

    @Test func stalePresentationCannotChooseWatchedOrSharePlayActionButJoinedNativeCan() async throws {
        let clock = ManualTestClock(nowNanoseconds: 0)
        let fixture = try makeModelContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository(freshDisplayTTLNanoseconds: 5,
                                            staleDisplayTTLNanoseconds: 20,
                                            now: { clock.nowNanoseconds })
        let request = request(repository, context: fixture.context, itemID: "item", fetch: fetch)

        let initial = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0,
                            item: MediaItem(ratingKey: "item", title: "old", type: "movie",
                                            viewCount: 1))
        _ = try await initial.value

        clock.advance(toNanoseconds: 5)
        let stale = try await repository.metadata(for: request, policy: .display)
        #expect(stale.item.viewCount == 1)
        #expect(!repository.mayAuthorizeAction(stale,
                                              appModel: fixture.model,
                                              backend: fixture.context.backend,
                                              itemID: "item"))

        let action = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await fetch.waitUntilStarted(count: 2)
        await fetch.succeed(attempt: 1,
                            item: MediaItem(ratingKey: "item", title: "new", type: "movie",
                                            viewCount: 0))
        let native = try await action.value
        #expect((native.item.viewCount ?? 0) == 0) // authoritative intent is "mark watched"
        #expect(repository.mayAuthorizeAction(native,
                                             appModel: fixture.model,
                                             backend: fixture.context.backend,
                                             itemID: "item"))
    }

    @Test func newerSourceRevisionAndTTLInvalidateEarlierNativeActionAdmission() async throws {
        let clock = ManualTestClock(nowNanoseconds: 0)
        let fixture = try makeModelContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository(freshDisplayTTLNanoseconds: 10,
                                            staleDisplayTTLNanoseconds: 20,
                                            now: { clock.nowNanoseconds })
        let request = request(repository, context: fixture.context, itemID: "item", fetch: fetch)

        let firstTask = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("item", title: "first"))
        let first = try await firstTask.value
        #expect(repository.mayAuthorizeAction(first,
                                             appModel: fixture.model,
                                             backend: fixture.context.backend,
                                             itemID: "item"))

        let secondTask = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await fetch.waitUntilStarted(count: 2)
        #expect(!repository.mayAuthorizeAction(first,
                                              appModel: fixture.model,
                                              backend: fixture.context.backend,
                                              itemID: "item"))
        await fetch.succeed(attempt: 1, item: item("item", title: "second"))
        let second = try await secondTask.value
        #expect(second.sourceRevision != first.sourceRevision)
        #expect(!repository.mayAuthorizeAction(first,
                                              appModel: fixture.model,
                                              backend: fixture.context.backend,
                                              itemID: "item"))
        #expect(repository.mayAuthorizeAction(second,
                                             appModel: fixture.model,
                                             backend: fixture.context.backend,
                                             itemID: "item"))

        clock.advance(toNanoseconds: 10)
        #expect(!repository.mayAuthorizeAction(second,
                                              appModel: fixture.model,
                                              backend: fixture.context.backend,
                                              itemID: "item"))
    }

    @Test func onlyExactCurrentUnpatchedNativeSnapshotCanAuthorizeImmediatePlay() async throws {
        let model = AppModel(identity: ClientIdentity(clientIdentifier: "play-contract",
                                                       product: "Labstream",
                                                       version: "1",
                                                       deviceName: "Test"),
                             activeBackend: .jellyfin)
        model.applyMediaBrowserSession(backend: .jellyfin,
                                       server: URL(string: "https://jellyfin.example.test")!,
                                       token: "token",
                                       userID: "user",
                                       serverID: "server")
        let context = try #require(model.activeAuthenticatedBrowseSession)
        let repository = MetadataRepository()
        let fetch = ControlledMetadataFetch()
        let trustedItem = item("item", title: "trusted-native")
        let request = repository.request(context: context,
                                         itemID: "item",
                                         load: { try await fetch.fetch() })
        let detailLoad = Task {
            try await repository.metadata(for: request, policy: .display)
        }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: trustedItem)
        let native = try await detailLoad.value
        #expect(native.provenance.delivery == .nativeRead)
        #expect(repository.mayAuthorizeAction(native,
                                             appModel: model,
                                             backend: .jellyfin,
                                             itemID: "item"))
        let playbackContext = try DetailPlaybackLauncher.context(backend: .jellyfin,
                                                                 appModel: model)

        // Acceptance takes the one-read path; a rejection would attempt the real test URL.
        let reused = await DetailPlaybackLauncher.metadataItem(
            ratingKey: "item",
            fallback: item("item", title: "fallback"),
            trustedDetailSnapshot: native,
            metadataRepository: repository,
            context: playbackContext,
            appModel: model,
            resumeRewindSeconds: 0)
        #expect(reused.title == "trusted-native")
        #expect(await fetch.startedCount == 1)

        for provenance in [
            MetadataProvenance(delivery: .freshDisplayReuse, watchedStatePatched: false),
            MetadataProvenance(delivery: .staleWhileRevalidate, watchedStatePatched: false),
            MetadataProvenance(delivery: .nativeRead, watchedStatePatched: true),
        ] {
            let displayOnly = MetadataSnapshot(backend: .jellyfin,
                                               authority: context.authority,
                                               sourceRevision: native.sourceRevision,
                                               item: trustedItem,
                                               provenance: provenance)
            #expect(!displayOnly.mayAuthorizeAction(in: model,
                                                    backend: .jellyfin,
                                                    itemID: "item"))
        }
        #expect(!native.mayAuthorizeAction(in: model, backend: .jellyfin, itemID: "other"))
        #expect(!native.mayAuthorizeAction(in: model, backend: .emby, itemID: "item"))
        model.jellyfinAccessToken = "replacement"
        #expect(!native.mayAuthorizeAction(in: model, backend: .jellyfin, itemID: "item"))
    }

    @Test func exactConcurrentReadersJoinOneNativeRead() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let first = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        let second = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await Task.yield()
        #expect(await fetch.startedCount == 1)

        await fetch.succeed(attempt: 0, item: item("item", title: "joined"))
        #expect(try await first.value.item.title == "joined")
        #expect(try await second.value.item.title == "joined")
        #expect(await fetch.startedCount == 1)
    }

    @Test func displayReusesOnlyWithinInjectedTTL() async throws {
        let clock = ManualTestClock(nowNanoseconds: 100)
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository(freshDisplayTTLNanoseconds: 50,
                                            staleDisplayTTLNanoseconds: 50,
                                            now: { clock.nowNanoseconds })
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let initial = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("item", title: "initial"))
        #expect(try await initial.value.item.title == "initial")

        clock.advance(byNanoseconds: 49)
        #expect(try await repository.metadata(for: request, policy: .display).item.title == "initial")
        #expect(await fetch.startedCount == 1)

        clock.advance(byNanoseconds: 1)
        let expired = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 2)
        await fetch.succeed(attempt: 1, item: item("item", title: "after-expiry"))
        #expect(try await expired.value.item.title == "after-expiry")
        #expect(await fetch.startedCount == 2)
    }

    @Test func authoritativeCallerAlwaysRereadsAfterSuccess() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository(freshDisplayTTLNanoseconds: .max,
                                            staleDisplayTTLNanoseconds: .max)
        let request = request(repository, context: context, itemID: "item", fetch: fetch)

        let first = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("item", title: "first"))
        #expect(try await first.value.item.title == "first")

        let second = Task { try await repository.metadata(for: request, policy: .authoritative) }
        await fetch.waitUntilStarted(count: 2)
        await fetch.succeed(attempt: 1, item: item("item", title: "second"))
        #expect(try await second.value.item.title == "second")
        #expect(await fetch.startedCount == 2)
    }

    @Test func systemEntryAuthoritativeReadFeedsImmediatelyOpenedDetailDisplay() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: context, itemID: "route-item", fetch: fetch)

        let systemEntry = Task {
            try await repository.metadata(for: request, policy: .authoritative)
        }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("route-item", title: "fresh route"))
        #expect(try await systemEntry.value.item.title == "fresh route")

        let detail = try await repository.metadata(for: request, policy: .display)
        #expect(detail.item.title == "fresh route")
        #expect(await fetch.startedCount == 1)
    }

    @Test func systemEntryNativeSnapshotHandoffAutoplaysWithOneMetadataRead() async throws {
        let fixture = try makeModelContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: fixture.context,
                              itemID: "route-item", fetch: fetch)
        let routeRead = Task {
            try await repository.metadata(for: request, policy: .authoritative)
        }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, item: item("route-item", title: "route-native"))
        let routeSnapshot = try await routeRead.value

        let router = SystemEntryRouter()
        router.requestAutoPlay(forRatingKey: "route-item", snapshot: routeSnapshot)
        let handoff = try #require(router.consumeAutoPlay(for: "route-item")?.snapshot)
        #expect(router.consumeAutoPlay(for: "route-item") == nil)
        #expect(repository.mayAuthorizeAction(handoff,
                                             appModel: fixture.model,
                                             backend: fixture.context.backend,
                                             itemID: "route-item"))

        let playbackContext = try DetailPlaybackLauncher.context(backend: fixture.context.backend,
                                                                 appModel: fixture.model)
        let playbackItem = await DetailPlaybackLauncher.metadataItem(
            ratingKey: "route-item",
            fallback: item("route-item", title: "fallback"),
            trustedDetailSnapshot: handoff,
            metadataRepository: repository,
            context: playbackContext,
            appModel: fixture.model,
            resumeRewindSeconds: 0)
        #expect(playbackItem.title == "route-native")
        #expect(await fetch.startedCount == 1)
    }

    @Test func exactAuthorityAndItemKeysDoNotCrossContaminate() async throws {
        let firstContext = try makeContext(token: "A")
        let secondContext = try makeContext(token: "B")
        let finalContext = try makeContext(token: "A-again")
        let firstFetch = ControlledMetadataFetch()
        let secondFetch = ControlledMetadataFetch()
        let finalFetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let firstRequest = request(repository, context: firstContext, itemID: "same", fetch: firstFetch)
        let secondRequest = request(repository, context: secondContext, itemID: "same", fetch: secondFetch)
        let finalRequest = request(repository, context: finalContext, itemID: "same", fetch: finalFetch)

        let first = Task { try await repository.metadata(for: firstRequest, policy: .display) }
        await firstFetch.waitUntilStarted(count: 1)
        await firstFetch.succeed(attempt: 0, item: item("same", title: "authority-A"))
        #expect(try await first.value.item.title == "authority-A")

        let second = Task { try await repository.metadata(for: secondRequest, policy: .display) }
        await secondFetch.waitUntilStarted(count: 1)
        await secondFetch.succeed(attempt: 0, item: item("same", title: "authority-B"))
        #expect(try await second.value.item.title == "authority-B")

        // A1 -> B -> A2 is not allowed to resurrect A1's evicted success merely because the
        // user returned to the same backend lane.
        let final = Task { try await repository.metadata(for: finalRequest, policy: .display) }
        await finalFetch.waitUntilStarted(count: 1)
        await finalFetch.succeed(attempt: 0, item: item("same", title: "authority-A2"))
        #expect(try await final.value.item.title == "authority-A2")

        let otherItemFetch = ControlledMetadataFetch()
        let otherItem = request(repository, context: finalContext, itemID: "other", fetch: otherItemFetch)
        let other = Task { try await repository.metadata(for: otherItem, policy: .display) }
        await otherItemFetch.waitUntilStarted(count: 1)
        await otherItemFetch.succeed(attempt: 0, item: item("other", title: "other"))
        #expect(try await other.value.item.ratingKey == "other")
    }

    @Test func delayedExpiredCompletionCannotPublishOverCurrentAuthority() async throws {
        let firstContext = try makeContext(token: "A")
        let interimContext = try makeContext(token: "B")
        let finalContext = try makeContext(token: "A-again")
        let active = TestLockedBox(firstContext.authority)
        let firstFetch = ControlledMetadataFetch()
        let interimFetch = ControlledMetadataFetch()
        let finalFetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let firstRequest = repository.request(
            context: firstContext,
            itemID: "same",
            load: { try await firstFetch.fetch() },
            isCurrent: { active.value == firstContext.authority })
        let interimRequest = repository.request(
            context: interimContext,
            itemID: "same",
            load: { try await interimFetch.fetch() },
            isCurrent: { active.value == interimContext.authority })

        let delayed = Task { try await repository.metadata(for: firstRequest, policy: .display) }
        await firstFetch.waitUntilStarted(count: 1)
        active.withValue { $0 = interimContext.authority }
        let interim = Task { try await repository.metadata(for: interimRequest, policy: .display) }
        await interimFetch.waitUntilStarted(count: 1)
        await interimFetch.succeed(attempt: 0, item: item("same", title: "interim"))
        #expect(try await interim.value.item.title == "interim")

        active.withValue { $0 = finalContext.authority }
        let finalRequest = repository.request(
            context: finalContext,
            itemID: "same",
            load: { try await finalFetch.fetch() },
            isCurrent: { active.value == finalContext.authority })
        let final = Task { try await repository.metadata(for: finalRequest, policy: .display) }
        await finalFetch.waitUntilStarted(count: 1)
        await finalFetch.succeed(attempt: 0, item: item("same", title: "final-A2"))
        #expect(try await final.value.item.title == "final-A2")

        await firstFetch.succeed(attempt: 0, item: item("same", title: "delayed"))
        do {
            _ = try await delayed.value
            Issue.record("Expired completion must fail")
        } catch let error as MetadataRepositoryError {
            #expect(error == .authorityExpired)
        }

        let probe = ControlledMetadataFetch()
        let currentProbe = request(repository, context: finalContext, itemID: "same", fetch: probe,
                                   isCurrent: { active.value == finalContext.authority })
        #expect(try await repository.metadata(for: currentProbe, policy: .display).item.title == "final-A2")
        #expect(await probe.startedCount == 0)
    }

    @Test func backendLanesRetainIndependentExactAuthorityValues() async throws {
        let jellyfin = try makeContext(token: "jf", backend: .jellyfin)
        let emby = try makeContext(token: "emby", backend: .emby)
        let jellyfinFetch = ControlledMetadataFetch()
        let embyFetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let jellyfinRequest = request(repository, context: jellyfin,
                                      itemID: "same-wire-id", fetch: jellyfinFetch)
        let embyRequest = request(repository, context: emby,
                                  itemID: "same-wire-id", fetch: embyFetch)

        let first = Task { try await repository.metadata(for: jellyfinRequest, policy: .display) }
        await jellyfinFetch.waitUntilStarted(count: 1)
        await jellyfinFetch.succeed(attempt: 0,
                                    item: item("same-wire-id", title: "Jellyfin"))
        #expect(try await first.value.item.title == "Jellyfin")

        let second = Task { try await repository.metadata(for: embyRequest, policy: .display) }
        await embyFetch.waitUntilStarted(count: 1)
        await embyFetch.succeed(attempt: 0,
                                item: item("same-wire-id", title: "Emby"))
        #expect(try await second.value.item.title == "Emby")

        #expect(try await repository.metadata(for: jellyfinRequest, policy: .display).item.title == "Jellyfin")
        #expect(try await repository.metadata(for: embyRequest, policy: .display).item.title == "Emby")
        #expect(await jellyfinFetch.startedCount == 1)
        #expect(await embyFetch.startedCount == 1)
    }

    @Test func authorityIsRecheckedWhenNewAndJoinedTaskResultsReachEachWaiter() async throws {
        let context = try makeContext()
        let repository = MetadataRepository()

        // New flight: preflight + task pre-load + task post-load remain current, then the
        // waiter-delivery check observes expiry.
        let newChecks = TestLockedBox(0)
        let newFetch = ControlledMetadataFetch()
        let newRequest = repository.request(
            context: context,
            itemID: "new-flight",
            load: { try await newFetch.fetch() },
            isCurrent: {
                newChecks.withValue { count in
                    count += 1
                    return count <= 3
                }
            })
        let newWaiter = Task { try await repository.metadata(for: newRequest, policy: .display) }
        await newFetch.waitUntilStarted(count: 1)
        await newFetch.succeed(attempt: 0, item: item("new-flight", title: "completed"))
        do {
            _ = try await newWaiter.value
            Issue.record("A new-flight waiter must fence authority again at delivery")
        } catch let error as MetadataRepositoryError {
            #expect(error == .authorityExpired)
        }

        // Joined flight: the owner remains current, while the joiner's authority expires in the
        // hand-off between its preflight and delivery check.
        let joinedFetch = ControlledMetadataFetch()
        let ownerRequest = request(repository, context: context,
                                   itemID: "joined-flight", fetch: joinedFetch)
        let owner = Task { try await repository.metadata(for: ownerRequest, policy: .display) }
        await joinedFetch.waitUntilStarted(count: 1)
        let joinChecks = TestLockedBox(0)
        let joinRequest = repository.request(
            context: context,
            itemID: "joined-flight",
            load: { Issue.record("Joiner must not start another read"); return self.item("bad", title: "bad") },
            isCurrent: {
                joinChecks.withValue { count in
                    count += 1
                    return count == 1
                }
            })
        let joiner = Task { try await repository.metadata(for: joinRequest, policy: .authoritative) }
        await Task.yield()
        await joinedFetch.succeed(attempt: 0, item: item("joined-flight", title: "owner"))
        #expect(try await owner.value.item.title == "owner")
        do {
            _ = try await joiner.value
            Issue.record("A joined waiter must fence its own authority again at delivery")
        } catch let error as MetadataRepositoryError {
            #expect(error == .authorityExpired)
        }
        #expect(await joinedFetch.startedCount == 1)
    }

    @Test func cancelledWaiterDoesNotCancelSurvivorOrPublication() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: context, itemID: "item", fetch: fetch)
        let cancelled = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        let survivor = Task { try await repository.metadata(for: request, policy: .display) }
        await Task.yield()

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled waiter must return CancellationError")
        } catch is CancellationError {}

        await fetch.succeed(attempt: 0, item: item("item", title: "survivor"))
        #expect(try await survivor.value.item.title == "survivor")
        #expect(try await repository.metadata(for: request, policy: .display).item.title == "survivor")
        #expect(await fetch.startedCount == 1)
    }

    @Test func failedReadEvictsAndPreservesBackendErrorForRetry() async throws {
        let context = try makeContext()
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let request = request(repository, context: context, itemID: "item", fetch: fetch)
        let failed = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 1)
        await fetch.fail(attempt: 0, error: BackendFailure.http(503))
        do {
            _ = try await failed.value
            Issue.record("Backend error must propagate")
        } catch let error as BackendFailure {
            #expect(error == .http(503))
        }

        let retry = Task { try await repository.metadata(for: request, policy: .display) }
        await fetch.waitUntilStarted(count: 2)
        await fetch.succeed(attempt: 1, item: item("item", title: "retry"))
        #expect(try await retry.value.item.title == "retry")
    }

    @Test func mismatchedLoaderProvenanceFailsBeforeNativeRead() async throws {
        let context = try makeContext()
        let other = try makeContext(token: "other")
        let fetch = ControlledMetadataFetch()
        let repository = MetadataRepository()
        let backendMismatch = repository.request(context: context,
                                                 itemID: "item",
                                                 loaderBackend: .emby,
                                                 load: { try await fetch.fetch() })
        let authorityMismatch = repository.request(context: context,
                                                   itemID: "item",
                                                   loaderAuthority: other.authority,
                                                   load: { try await fetch.fetch() })

        for (request, expected) in [(backendMismatch, MetadataRepositoryError.backendMismatch),
                                    (authorityMismatch, .authorityMismatch)] {
            do {
                _ = try await repository.metadata(for: request, policy: .display)
                Issue.record("Mismatched loader must fail")
            } catch let error as MetadataRepositoryError {
                #expect(error == expected)
            }
        }
        #expect(await fetch.startedCount == 0)
    }

    @Test func runtimeWiringMigratesOnlyDetailDisplayAndRouteKeySystemEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source: (String) throws -> String = { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        #expect(try source("Labstream/Shared/App/AppRuntime.swift")
            .contains("let metadataRepository = MetadataRepository()"))
        #expect(try source("Labstream/Shared/UI/RootNavigationCoordinator.swift")
            .contains("policy: .authoritative"))
        let detail = try source("Labstream/Shared/UI/DetailView.swift")
        #expect(detail.contains("policy: .display"))
        #expect(detail.contains("policy: .authoritative"))
        #expect(detail.contains("authoritativeItemForAction"))
        #expect(detail.contains("patchWatchedState"))
        #expect(detail.contains("prepareWatchTogether"))
        #expect(detail.contains("trustedDetailSnapshot: action.snapshot"))
        #expect(try source("Labstream/Shared/UI/DetailPlaybackLauncher.swift")
            .contains("trustedDetailSnapshot.mayAuthorizeAction"))

        for path in [
            "Labstream/Capabilities/Downloads/Core/DownloadItemPlanner.swift",
            "Labstream/Shared/Player/PlaybackController.swift",
            "Labstream/Shared/UI/DetailWatchedUpdater.swift",
            "Labstream/Shared/SystemIntegration/SpotlightIndexer.swift",
            "Labstream/Platforms/visionOS/SharePlay/WatchTogetherMediaLookup.swift",
        ] {
            let text = try source(path)
            #expect(!text.contains("metadataRepository"), "Forbidden metadata consumer migrated: \(path)")
        }
    }

    private func makeContext(token: String = "token",
                             backend: MediaBackendKind = .jellyfin) throws
        -> AuthenticatedBrowseSessionContext {
        try makeModelContext(token: token, backend: backend).context
    }

    private func makeModelContext(token: String = "token",
                                  backend: MediaBackendKind = .jellyfin) throws
        -> (model: AppModel, context: AuthenticatedBrowseSessionContext) {
        let model = AppModel(identity: ClientIdentity(clientIdentifier: "metadata-repository-test",
                                                       product: "Labstream",
                                                       version: "1",
                                                       deviceName: "Test"),
                             activeBackend: backend)
        model.applyMediaBrowserSession(backend: backend,
                                       server: URL(string: "https://\(backend.rawValue).example.test")!,
                                       token: token,
                                       userID: "user",
                                       serverID: "server")
        return (model, try #require(model.activeAuthenticatedBrowseSession))
    }

    private func request(_ repository: MetadataRepository,
                         context: AuthenticatedBrowseSessionContext,
                         itemID: String,
                         fetch: ControlledMetadataFetch,
                         isCurrent: @escaping @MainActor @Sendable () -> Bool = { true })
        -> MetadataRequest {
        repository.request(context: context,
                           itemID: itemID,
                           load: { try await fetch.fetch() },
                           isCurrent: isCurrent)
    }

    private func item(_ id: String, title: String) -> MediaItem {
        MediaItem(ratingKey: id, title: title, type: "movie")
    }
}

@MainActor
private final class ControlledMetadataDeliveryGate {
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var isHeld = false

    func hold() async {
        isHeld = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            heldContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func open() {
        heldContinuation?.resume()
        heldContinuation = nil
    }
}

private enum BackendFailure: Error, Equatable {
    case http(Int)
}

private actor ControlledMetadataFetch {
    private var continuations: [Int: CheckedContinuation<MediaItem, Error>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startedCount = 0

    func fetch() async throws -> MediaItem {
        let attempt = startedCount
        startedCount += 1
        resumeStartWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations[attempt] = continuation
        }
    }

    func waitUntilStarted(count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func succeed(attempt: Int, item: MediaItem) {
        continuations.removeValue(forKey: attempt)?.resume(returning: item)
    }

    func fail(attempt: Int, error: Error) {
        continuations.removeValue(forKey: attempt)?.resume(throwing: error)
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startedCount >= $0.count }
        startWaiters.removeAll { startedCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}
