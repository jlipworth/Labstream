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
/// The side-asset coordinator, the work registry and the pause and resume entry points are app
/// code with no PMSKit policy in front of them, so these tests pin the shape of that source, as
/// the F3 test does. A fix that takes another shape must update the pin with it. The behavioural
/// pins belong in `LabstreamTests` (`P7SideAssetOrderingTests`) with the fix.
@Suite("Downloads formal-model side assets")
struct DownloadsFormalModelSideAssetsTests {
    private static let coordinatorPath = "Labstream/Shared/Player/SideAssetFetchCoordinator.swift"
    private static let managerPath = "Labstream/Capabilities/Downloads/Core/DownloadManager.swift"
    private static let servicePath = "Labstream/Capabilities/Downloads/Core/DownloadSideAssetService.swift"

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
