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

    /// S1. `releaseInFlight` in its default mode cancels both coordinator owners of an attempt:
    /// the attempt's and the poster's. Several callers keep the row and its attempt afterwards
    /// (a Plex prep poller that finds no session, for one). A cancelled owner is reopened only by
    /// a fetch-entry command, and the poster fetch is the one fetch that sends none. Every later
    /// poster fetch for that attempt throws `CancellationError` before it is charged to the retry
    /// budget, so the repair pass offers it again on every foreground edge and it fails every
    /// time. The row has no poster until the app is relaunched.
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
        withKnownIssue("TLA+ finding S1 (#482): a cancelled poster owner stays cancelled for the launch") {
            #expect(posterBranch.contains("deliverOptionalSideAssetControl"),
                    "the poster fetch never reopens the owner that a kept-attempt cancel closed")
        }
    }

    /// S2. Behind Pause All every non-poster fetch entry parks the attempt's coordinator owner,
    /// whatever the row's lifecycle. Pause All sends a completed (or finalizing) row no command,
    /// but its side-asset tasks keep running, and the next fetch entry of one of them (the next
    /// subtitle stream, say) parks the owner and everything queued under it. Resume All re-admits
    /// paused and failed rows only; for a completed row it runs the repair pass, which starts a
    /// kind only when the registry holds no task of that kind. The parked tasks are still
    /// registered, so nothing enters a new fetch, nothing unparks the owner, and the remaining
    /// assets are not fetched until the app is relaunched.
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

        withKnownIssue("TLA+ finding S2 (#483): Pause All strands a completed row's parked side assets") {
            let entryParksAnyLifecycle = fetch.contains(
                "|| (isQueuePaused && !admission.isExempt(key.ratingKey))")
            let resumeAllUnparks = resumeQueue.contains("setOptionalSideAssetHydrationParked(false")
                || resumeQueue.contains("deliverOptionalSideAssetControl(")
            #expect(resumeAllUnparks || !entryParksAnyLifecycle,
                    "a completed row parked behind Pause All is never unparked by Resume All")
        }
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

    /// S6. Launch restores the selected backend's session, then hydrates only the other backends
    /// that own active work or journaled server cleanup. A completed row on a backend that is not
    /// selected therefore has no session: `rehydrateMissingOptionalSideAssets` looks the session
    /// up, finds none and returns. Its missing poster, subtitles and trick-play index stay missing
    /// through every launch until the user switches to that backend.
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
        withKnownIssue("TLA+ finding S6 (#494): a completed row on an inactive backend is never repaired at launch") {
            #expect(hydration.contains("isComplete") || hydration.contains("ideAsset"),
                    "launch hydration ignores completed rows whose side assets are missing")
        }
    }

    /// S7. A Plex download transfers the part the user chose (`part[partIndex]`). The BIF request,
    /// in the initial pass and in the completed-row repair alike, is built from the media's first
    /// part: `selectedPlexBIFPart` takes no part index. For a multi-part item downloaded from its
    /// second part, the trick-play index is never requested when only that part has one, and the
    /// first part's index is cached for the wrong file when the first part has one.
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

        // What the model relies on: both call sites pass the media index and no part index.
        let initial = try #require(Self.appSource(
            from: "        cachePlexBIF(for: attemptKey, item: item, mediaIndex: mediaIndex,",
            to: "\n        let initialRoute", in: Self.plexPath))
        #expect(initial.contains("let staticPart = chosenMedia?.part[safe: partIndex]"))
        #expect(!initial.contains("partIndex: partIndex"))

        withKnownIssue("TLA+ finding S7 (#495): the Plex BIF is selected from the first part, not the downloaded one") {
            #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: onlyChosenHasBIF, mediaIndex: 0)?.id == 11,
                    "the downloaded part's BIF is never requested")
            #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: onlyFirstHasBIF, mediaIndex: 0) == nil,
                    "the first part's BIF is cached for a download of the second part")
        }
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
