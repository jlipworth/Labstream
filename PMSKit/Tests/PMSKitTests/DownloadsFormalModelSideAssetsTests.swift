import Foundation
import Testing
@testable import PMSKit

/// Orderings the TLA+ model of optional side assets found on the current design
/// (`specs/downloads/side-assets/DownloadsSideAssets.tla`, `specs/downloads/side-assets/Finding-*.cfg`,
/// `specs/downloads/side-assets/README.md`).
///
/// Each finding test states the behaviour the design wants and is wrapped in `withKnownIssue`, so
/// the suite stays green while the finding is open. When a fix lands the expectation holds, no
/// issue is recorded, and `withKnownIssue` fails the test: delete the wrapper then, and flip the
/// matching `side-assets/Finding-*.cfg` to `EXPECT: pass`.
///
/// The side-asset coordinator, the work registry, the store and the pause, resume and repair
/// entry points are app code with no PMSKit policy in front of them, so these tests pin the shape
/// of that source, as the F3 test does. S7 is the exception: its decision is a PMSKit policy and
/// is pinned by behaviour. A fix that takes another shape must update the pin with it. The behavioural
/// pins belong in `LabstreamTests` (`P7SideAssetOrderingTests`) with the fix.
@Suite("Downloads formal-model side assets")
struct DownloadsFormalModelSideAssetsTests {
    private static let coordinatorPath = "Labstream/Shared/Player/SideAssetFetchCoordinator.swift"
    private static let managerPath = "Labstream/Capabilities/Downloads/Core/DownloadManager.swift"
    private static let servicePath = "Labstream/Capabilities/Downloads/Core/DownloadSideAssetService.swift"
    private static let sideCachePath = "Labstream/Capabilities/Downloads/Core/DownloadManager+SideCache.swift"
    private static let plexPath = "Labstream/Capabilities/Downloads/Core/DownloadManager+Plex.swift"
    private static let storePath = "Labstream/Capabilities/Downloads/Core/DownloadStore.swift"
    private static let contentViewPath = "Labstream/Shared/App/ContentView.swift"

    /// S1 (#482, fixed). `releaseInFlight` in its default mode cancels both coordinator owners of
    /// an attempt: the attempt's and the poster's. Several callers keep the row and its attempt
    /// afterwards (a Plex prep poller that finds no session, for one). A cancelled owner is
    /// reopened only by a fetch-entry command. The poster fetch used to be the one fetch that sent
    /// none, so every later poster fetch for that attempt threw `CancellationError` before it was
    /// charged, for the rest of the launch. It now registers with an unpark, like every other kind.
    @Test("S1: a poster fetch reopens its cancelled coordinator owner")
    func posterFetchReopensItsCancelledOwner() throws {
        let fetch = try #require(Self.appSource(
            from: "    func fetchOptionalSideAsset(", to: "\n    /// Hooks can delay",
            in: Self.coordinatorPath))
        let cancel = try #require(Self.appSource(
            from: "    func cancelOptionalSideAssetHydration(", to: "\n}",
            in: Self.coordinatorPath))
        let apply = try #require(Self.appSource(
            from: "    func applyDownloadControl(", to: "\n    typealias FetchOperation",
            in: Self.coordinatorPath))

        // What the model relies on: a cancel ends both owners, and only a fetch entry
        // (`registration`) reopens one.
        #expect(cancel.contains("Self.posterSideAssetOwner(for: key)"))
        #expect(apply.contains("if registration { cancelledDownloadOwners.remove(owner) }"))

        let posterBranch = try #require(Self.slice(fetch, from: "if kind == .poster {", to: "} else {"))
        #expect(posterBranch.contains("deliverOptionalSideAssetControl(.park(false)"),
                "the poster fetch never reopens the owner that a kept-attempt cancel closed")
        #expect(posterBranch.contains("fetchEntry: true"),
                "only a fetch-entry (registration) command reopens a cancelled owner")
    }

    /// F3 (#474) on this model (`Faithful-F3-finish-off-Chapters.cfg`). A user pause parks the
    /// attempt's owner and keeps its tasks registered. A forward-only transfer that finishes as
    /// the pause lands still finalizes and completes. A finished row has no Resume, and the
    /// repair pass starts nothing for a registered kind, so nothing unparked the owner until
    /// relaunch. The publishing finalizer's admission now does.
    @Test("F3: a body that finishes behind a user pause unparks its side assets")
    func finishedBodyUnparksSideAssets() throws {
        #expect(DownloadSideAssetParkPolicy.finishedBodyUnparks(
            isQueuePaused: false, isExemptFromQueuePause: false))
        #expect(DownloadSideAssetParkPolicy.finishedBodyUnparks(
            isQueuePaused: true, isExemptFromQueuePause: true))
        // Pause All still holds the row; Resume All unparks it (S2).
        #expect(!DownloadSideAssetParkPolicy.finishedBodyUnparks(
            isQueuePaused: true, isExemptFromQueuePause: false))
        // The reducer lets the paused row finalize.
        let paused = DownloadLifecycleState(
            lifecycle: .paused, history: DownloadAttemptHistory(pauseCause: .user))
        #expect(DownloadLifecycleReducer.reduce(
            paused, .bodyCaptured, facts: DownloadRowFacts(route: .forwardOnly))
            .state?.lifecycle == .finalizing)

        let broker = try #require(Self.appSource(
            from: "        self.session.onFinalizerRequest = {",
            to: "\n        self.session.onRevalidationProbeDeferred", in: Self.managerPath))
        let unpark = try #require(broker.range(
            of: "self.unparkOptionalSideAssetsForFinishedBody(request.attemptKey)"))
        let start = try #require(broker.range(of: "self.downloadWorkRegistry.startIfAbsent("))
        #expect(unpark.lowerBound < start.lowerBound)
        let helper = try #require(Self.appSource(
            from: "    func unparkOptionalSideAssetsForFinishedBody(", to: "\n    }\n",
            in: Self.managerPath))
        #expect(helper.contains("DownloadSideAssetParkPolicy.finishedBodyUnparks("))
        #expect(helper.contains("setOptionalSideAssetHydrationParked(false, for: key)"))
    }

    /// S2 (#483, fixed). Behind Pause All every non-poster fetch entry parks the attempt's
    /// coordinator owner, whatever the row's lifecycle. Pause All sends a completed (or
    /// finalizing) row no command, but its side-asset tasks keep running, and the next fetch entry
    /// of one of them (the next subtitle stream, trickplay tiles) parks the owner and everything
    /// queued under it. Resume All re-admits paused and failed rows only, and the repair pass it
    /// runs starts a kind only when the registry holds no task of that kind, so nothing entered a
    /// new fetch and nothing unparked the owner until relaunch. Resume All now unparks every row
    /// that is not itself paused.
    @Test("S2: Resume All unparks the side assets of a completed row")
    func resumeAllUnparksCompletedRows() throws {
        // The pure half: Resume All does not re-admit a row that is already playable.
        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.complete))
        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.unverified))

        let fetch = try #require(Self.appSource(
            from: "    func fetchOptionalSideAsset(", to: "\n    /// Hooks can delay",
            in: Self.coordinatorPath))
        let resumeQueue = try #require(Self.appSource(
            from: "    public func resumeQueue() {", to: "\n    /// Auth restore",
            in: Self.managerPath))
        #expect(resumeQueue.contains("rehydrateMissingOptionalSideAssetsForCompletedRows"))

        let entryParksAnyLifecycle = fetch.contains(
            "|| (isQueuePaused && !admission.isExempt(key.ratingKey))")
        let resumeAllUnparks = resumeQueue.contains("setOptionalSideAssetHydrationParked(false")
            || resumeQueue.contains("deliverOptionalSideAssetControl(")
        #expect(resumeAllUnparks || !entryParksAnyLifecycle,
                "a completed row parked behind Pause All is never unparked by Resume All")
        // The model's fix unparks every row that is not paused (a completed row included) and
        // leaves a paused row to its own resume.
        #expect(resumeQueue.contains("where record.lifecycle != .paused"))
    }

    /// S5. The completed-row repair is edge driven: launch, foreground, backend ready or switched,
    /// Resume All. An edge that arrives while an inventory pass runs returns at the first guard,
    /// and the running pass observed the rows before that edge. A pass whose worker misses its
    /// 30 s deadline ends without dispatching, and a row whose mutation generation moved while it
    /// was observed is skipped. None of the three leaves a note to run again, so the rows wait
    /// for the next edge the user happens to cause.
    @Test("S5: a dropped repair edge is run again")
    func droppedRepairEdgeRunsAgain() throws {
        let pass = try #require(Self.appSource(
            from: "    func rehydrateMissingOptionalSideAssetsForCompletedRows(",
            to: "\n    /// Reuse the pass inventory when still current", in: Self.sideCachePath))

        // What the model relies on: the three places a pass can end without scanning a row.
        #expect(pass.contains("await work.observe(deadline: .after(30))"))
        #expect(pass.contains("guard inventory.matches(self.store)"))
        #expect(pass.contains("defer { self.completedSideAssetInventoryWorker = nil }"))

        withKnownIssue("TLA+ finding S5 (#493): a busy, timed-out or stale repair pass is not rerun") {
            #expect(!pass.contains(
                        "guard !isQueuePaused, completedSideAssetInventoryWorker == nil else { return }"),
                    "an edge that arrives while a pass runs is dropped without a rerun note")
        }
    }

    /// S6 (#494, fixed). Launch restores the selected backend's session, then used to hydrate
    /// only the other backends that own active work or journaled server cleanup. A completed row
    /// on a backend that is not selected had no session: `rehydrateMissingOptionalSideAssets`
    /// looks the session up, finds none and returns, so its missing assets stayed missing through
    /// every launch. Launch now also hydrates the backends of completed rows missing an asset.
    @Test("S6: launch gives a completed row that misses side assets its backend session")
    func launchHydratesBackendsOfCompletedRowsMissingAssets() throws {
        // The pure half: a completed row is not active work, so it never asks for hydration.
        #expect(!DownloadStatus.complete.isActiveWork)
        #expect(!DownloadStatus.unverified.isActiveWork)

        let rehydrate = try #require(Self.appSource(
            from: "    func rehydrateMissingOptionalSideAssets(record:", to: "\n        let item = ",
            in: Self.sideCachePath))
        // What the model relies on: the repair needs a hydrated session that matches the server
        // and user the row was downloaded from, and does nothing to obtain one.
        #expect(rehydrate.contains("appModel.backendSession(for:"))
        #expect(rehydrate.contains("backendSession.matchesPersistedServer(metadata) else { return false }"))

        let hydration = try #require(Self.appSource(
            from: "    private func runLaunchDownloadRecovery(", to: "\n        for backend in inactiveDownloadBackends",
            in: Self.contentViewPath))
        #expect(hydration.contains(".filter { $0.status.isActiveWork }"))
        #expect(hydration.contains("downloadManager.backendsOwingCompletedSideAssets()"),
                "launch hydration ignores completed rows whose side assets are missing")
        #expect(hydration.contains(".union(sideAssetBackends)"))
        let owing = try #require(Self.appSource(
            from: "    func backendsOwingCompletedSideAssets(", to: "\n    /// Reuse the pass inventory",
            in: Self.sideCachePath))
        // The same durable observation the repair pass uses decides which backends are owed.
        #expect(owing.contains("records.filter(\\.isComplete)"))
        #expect(owing.contains("CompletedSideAssetInventory.observe(record: record, store: store)"))
        #expect(owing.contains("!inventory.missing.isEmpty"))
    }

    /// S7 (#495, fixed). A Plex download transfers the part the user chose (`part[partIndex]`).
    /// The BIF request, in the initial pass and in the completed-row repair alike, used to be built
    /// from the media's first part, so for a multi-part item downloaded from its second part the
    /// trick-play index was never requested when only that part had one, and the first part's
    /// index was cached for the wrong file when the first part had one. Both call sites now pass
    /// the chosen part index and the policy selects `part[partIndex]`
    /// (`side-assets/Current-S7-BifChosenPart`; `Faithful-S7-off-*` keep the old behaviour).
    @Test("S7: the Plex BIF comes from the downloaded part")
    func plexBIFComesFromTheDownloadedPart() throws {
        func part(_ id: Int, _ indexes: String?) -> Part {
            Part(id: id, key: "/library/parts/\(id)", indexes: indexes)
        }
        // The user downloads the second part (part index 1) of the only media.
        let onlyChosenHasBIF = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 1, part: [part(10, nil), part(11, "sd")]),
        ])
        let onlyFirstHasBIF = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 1, part: [part(10, "sd"), part(11, nil)]),
        ])

        // What the model relies on: both call sites pass the chosen media and part index, the
        // same indexes the transfer and the subtitle repair use.
        let initial = try #require(Self.appSource(
            from: "        cachePlexBIF(for: attemptKey, item: item, mediaIndex: mediaIndex,",
            to: "\n        let initialRoute", in: Self.plexPath))
        #expect(initial.contains("partIndex: partIndex, server: server, token: token)"))
        #expect(initial.contains("let staticPart = chosenMedia?.part[safe: partIndex]"))
        let repair = try #require(Self.appSource(
            from: "                    self.cachePlexBIF(for: attemptKey, item: currentItem, mediaIndex: mediaIndex,",
            to: "\n                }", in: Self.sideCachePath))
        #expect(repair.contains("partIndex: partIndex, server: server, token: token)"))
        let cache = try #require(Self.appSource(
            from: "    func cachePlexBIF(for attemptKey:", to: "\n        guard let sourceIdentity",
            in: Self.sideCachePath))
        #expect(cache.contains("from: item, mediaIndex: mediaIndex, partIndex: partIndex)"))

        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: onlyChosenHasBIF, mediaIndex: 0, partIndex: 1)?.id == 11,
                "the downloaded part's BIF is requested")
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: onlyFirstHasBIF, mediaIndex: 0, partIndex: 1) == nil,
                "the first part's BIF is not cached for a download of the second part")
        // Downloading the first part still selects the first part's BIF.
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: onlyFirstHasBIF, mediaIndex: 0, partIndex: 0)?.id == 10)
    }

    /// S8. A side-asset promotion snapshots the row's mutation generation, then checks it again
    /// just before the rename and gives up if any writer touched the row in between: a lifecycle
    /// or progress write of the transfer, or another side asset of the same row being confirmed.
    /// The row is still live and still the same attempt and source. No caller retries: the fetched
    /// payload is dropped, the dispatch stays charged, and the asset waits for the next repair
    /// edge.
    @Test("S8: a promotion survives an unrelated write to its row")
    func promotionSurvivesAnUnrelatedRowWrite() throws {
        let promote = try #require(Self.appSource(
            from: "    private func promoteAttemptStagingFile(", to: "\n    /// Retire an obsolete private side-cache staging",
            in: Self.storePath))
        let tail = try #require(Self.appSource(
            from: "    nonisolated static func promoteSideAsset(", to: "\n}", in: Self.sideCachePath))

        // What the model relies on: every row write advances the generation, and the caller
        // maps anything but `.promoted` to failure.
        let store = try #require(Self.appSource(
            from: "    private func setRowLocked(", to: "\n    private var rows", in: Self.storePath))
        #expect(store.contains("rowMutationGenerations[ratingKey, default: 0] &+= 1"))
        #expect(tail.contains("stagingURL: stagingURL, to: stableURL) == .promoted"))

        withKnownIssue("TLA+ finding S8 (#496): a concurrent write to the row makes a side-asset promotion give up") {
            #expect(!promote.contains(
                        "guard lock.withLock({ rowMutationGenerations[key.ratingKey, default: 0] == snapshot.0 }) else { return .staleOrMissingOwner }"),
                    "the pre-rename check fails on any row write, and nothing retries")
        }
    }

    /// The store facts the model's Delete relies on: the deletion intent lists the paths a rename
    /// has published but metadata has not recorded, a promotion re-checks the row under the lock
    /// after its rename and removes an unreferenced file, and a metadata update is refused while
    /// the deletion is pending (`Mutant-DeleteSkipsPublished`, `Mutant-PromoteConfirmUnfenced`).
    @Test("The store fences the model's Delete assumes")
    func deleteFencesTheModelAssumes() throws {
        let referenced = try #require(Self.appSource(
            from: "    private func artifactPathsReferenced(by row: Row)", to: "\n    private static func hasPendingRowDeletion",
            in: Self.storePath))
        #expect(referenced.contains("for (path, owner) in sideAssetPublicationOwners"))
        #expect(referenced.contains("case .rowDeletion(let paths, _, _):"))

        let stage = try #require(Self.appSource(
            from: "    private func stageRowDeletionLocked(", to: "\n    func resolveRowDeletionSynchronously",
            in: Self.storePath))
        #expect(stage.contains("var paths = artifactPathsReferenced(by: row)"))

        let promote = try #require(Self.appSource(
            from: "    private func promoteAttemptStagingFile(", to: "\n    /// Retire an obsolete private side-cache staging",
            in: Self.storePath))
        #expect(promote.contains("!Self.hasPendingRowDeletion(row), row.sideAssetGeneration == snapshot.1"))
        #expect(promote.contains("try? storeFilesystem.removeItem(at: stableURL, using: fileManager)"))

        let submit = try #require(Self.appSource(
            from: "    func submitMetadata(", to: "\n        let previous = metadata", in: Self.storePath))
        #expect(submit.contains("!Self.hasPendingRowDeletion(row)"))
    }

    /// The shapes the model gives Jellyfin trickplay: the playlist first, then every missing tile
    /// in one task group whose payloads are prepared one at a time (#394), one batch recorded only
    /// with the local playlist, and a completed-row offer gated by the playlist's budget alone.
    @Test("The trickplay shape the model abstracts")
    func trickplayShapeTheModelAbstracts() throws {
        let trickplay = try #require(Self.appSource(
            from: "    func cacheJellyfinTrickPlay(", to: "\n            } catch {",
            in: "Labstream/Capabilities/Downloads/Core/DownloadManager+Jellyfin.swift"))
        #expect(trickplay.contains("kind: .jellyfinTrickPlay, resource: \"playlist\")"))
        #expect(trickplay.contains("await withTaskGroup(of: (Int, String, URL, Data)?.self)"))
        #expect(trickplay.contains("guard !tileRelatives.isEmpty else { return }"))
        #expect(trickplay.contains("jellyfinPlaylist: playlistURL.lastPathComponent)"))

        let resources = try #require(Self.appSource(
            from: "    static func retryResources(for kind:", to: "\n        case .textSubtitles:",
            in: Self.servicePath))
        #expect(resources.contains("case .jellyfinTrickPlay:"))
        #expect(resources.contains("return [\"playlist\"]"))

        // A tile that failed keeps a line in the local playlist, so the inventory still sees it.
        let sanitized = JellyfinTrickPlayOfflineCachePlanner.sanitizedPlaylist(
            "#EXTM3U\n0.jpg?ApiKey=secret\n1.jpg?ApiKey=secret",
            tileFilenamesByURI: ["0.jpg?ApiKey=secret": "local.tile.0.jpg"])
        #expect(sanitized == "#EXTM3U\nlocal.tile.0.jpg\n1.jpg")
    }

    /// The model's bounds stand for these values: `MaxDispatch` for the per-launch retry budget
    /// and `MaxConcurrent` for the per-origin request cap. The configs use smaller numbers.
    @Test("The retry budget and the request cap the model abstracts")
    func modelBoundsNameTheShippingLimits() throws {
        let service = try #require(Self.appSource(
            from: "struct DownloadSideAssetRetryBudget {", to: "\n}", in: Self.servicePath))
        #expect(service.contains("static let defaultMaximumDispatches = 5"))
        let policy = try #require(Self.appSource(
            from: "struct SideAssetRequestPolicy:", to: "\n    init(", in: Self.coordinatorPath))
        #expect(policy.contains("maximumConcurrentRequests: 2"))
    }

    /// The text of an app source file from `start` up to the next `end` after it. Nil when the
    /// file or either marker is missing.
    private static func appSource(from start: String, to end: String, in relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8) else { return nil }
        return slice(source, from: start, to: end)
    }

    private static func slice(_ text: String, from start: String, to end: String) -> String? {
        guard let head = text.range(of: start),
              let tail = text.range(of: end, range: head.upperBound..<text.endIndex) else { return nil }
        return String(text[head.lowerBound..<tail.lowerBound])
    }
}
