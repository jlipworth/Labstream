#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P7 real sheet adapters", .serialized)
@MainActor
struct P7DownloadRowsTests {
    @Test(arguments: [DownloadBackendKind.plex, .emby])
    func deletionConfirmationDisclosesServerWork(backend: DownloadBackendKind) async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        var row = f.record
        row.metadata?.backendKind = backend
        row.metadata?.embyConvertJobID = backend == .emby ? 42 : nil
        row.metadata?.downloadLane = .optimize
        row.metadata?.resumeMode = .serverPrepThenStatic
        row.metadata?.optimizeQueueTitle = "fixture-prep"
        #expect(DownloadDeletePolicy.deletionCancelsServerPrep(row))
        let copy = DownloadOptionsSheet.removalMessage(for: row)
        do {
            #expect(copy.localizedCaseInsensitiveContains("server"))
            #expect(copy.localizedCaseInsensitiveContains("finished"))
        }
        await f.finish()
    }

    @Test func staleSheetConfirmationCannotDeleteReplacement() async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        let confirmation = DownloadOptionsModel.RemovalConfirmation(record: f.record)
        let replacement = f.files.record("b", status: .paused, filename: "replacement.mp4")
        _ = await f.store.resolve(f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID), deadline: .after(5))
        DownloadOptionsSheet.deleteExistingDownload(identity: confirmation.identity, manager: f.manager)
        await f.manager.drainManagerOperationsForTesting()
        do {
            #expect(f.store.ownsAttempt(.init(
                ratingKey: replacement.ratingKey, attemptID: replacement.attemptID!)))
        }
        await f.finish()
    }

    @Test func finalSourceVersionCoversAllTwelveConfigurations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("Labstream.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"MARKETING_VERSION = ([^;]+);"#)
        let versions = expression.matches(in: project, range: NSRange(project.startIndex..., in: project))
            .compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: project) else { return nil }
                return String(project[range])
            }
        #expect(versions.count == 12)
        withKnownIssue("P7 red pin: 15") { #expect(versions.allSatisfy { $0 == "1.8.0" }) }
    }

    #if os(macOS)
    @Test(arguments: [DownloadLifecycle.planned, .serverPrep, .finalizing, .paused, .unverified, .failed])
    func macSheetUsesListPhase(lifecycle: DownloadLifecycle) async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        var row = f.record
        row.lifecycle = lifecycle
        row.status = lifecycle.derivedStatus
        row.admissionIntent = lifecycle == .planned ? .seasonPlanned : nil
        let expected = DownloadRowStatusCaptionPolicy.admissionWaitingCaption(
            lifecycle: row.lifecycle, intent: row.admissionIntent,
            isQueuePaused: false, isExempt: false)
            ?? DownloadRowStatusCaptionPolicy.caption(.init(record: row,
                displayFraction: nil, isActive: lifecycle == .serverPrep || lifecycle == .finalizing,
                isBackendConfigured: true, isTranscodeLimited: false,
                serverPrepState: nil, serverPrepProgress: nil, serverPrepETA: nil,
                downloadETA: nil, downloadSpeedBytesPerSecond: nil, isRetrying: false,
                failureCaption: nil))
        let actual = DownloadOptionsSheet.macExistingStatusText(row)
        do { #expect(actual == expected) }
        await f.finish()
    }
    #endif
    @Test(arguments: [5_000, 30_000, 599_000])
    func libraryUsesFactoryRewindOnceAndPassesCapturedEvents(position: Int) async throws {
        let f = try await P7PlaybackFixture(status: .complete, position: position)
        let factory = P7LibraryStubFactory(f)
        let surface = OfflineLibraryPlaybackPresentation(factory: factory)
        let result = await surface.launch(for: .init(ratingKey: f.key.ratingKey, attemptID: f.key.attemptID),
            resumeRewindSeconds: 10, orientation: {})
        guard case .success(let launch) = result else { Issue.record("Library launch rejected"); return }
        let controller = OfflineLibraryView.makeOfflinePlayer(launch: launch, onClose: {})
            .makeControllerForP7Testing()
        let expected = DetailPlaybackLauncher.itemWithResumeRewind(
            f.record.metadata!.makeMediaItem(), resumeRewindSeconds: 10)
        #expect(controller.item.viewOffset == expected.viewOffset) // pin 06 library half
        #expect(factory.rewinds == [10])
        #expect(factory.identities == [.init(ratingKey: f.key.ratingKey, attemptID: f.key.attemptID)])
        controller.recordLocalPlaybackPosition(41_000)
        #expect(factory.sink.positions.last == 41_000)
        #expect(factory.sink.attemptKey == f.key)
        controller.stop()
        await f.finish()
    }

    @Test func libraryFinalAdmissionRunsAfterOrientation() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let factory = P7LibraryStubFactory(f)
        let surface = OfflineLibraryPlaybackPresentation(factory: factory)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let request = Task { @MainActor in
            await surface.launch(for: .init(ratingKey: f.key.ratingKey, attemptID: f.key.attemptID),
                resumeRewindSeconds: 10, orientation: { entered.signal(true); _ = await release.wait() })
        }
        _ = await entered.wait()
        #expect(factory.identities.isEmpty)
        let replacement = f.files.record("b", status: .complete, filename: "replacement.mp4")
        _ = await f.store.resolve(f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID), deadline: .after(5))
        release.signal(true)
        guard case .failure(.staleAttempt) = await request.value else {
            Issue.record("Superseded attempt admitted after orientation"); return
        }
        await f.finish()
    }

    @Test(arguments: [false, true])
    func supersededLibraryPresentationCannotReturnAfterSuspension(inFactory: Bool) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let factory = P7LibraryStubFactory(f)
        let surface = OfflineLibraryPlaybackPresentation(factory: factory)
        let entered = P6Acknowledgement<Bool>()
        let release = P6Acknowledgement<Bool>()
        let suspend = { entered.signal(true); _ = await release.wait() }
        if inFactory { factory.onMake = suspend }
        let identity = OfflineDownloadRowActionIdentity(ratingKey: f.key.ratingKey, attemptID: f.key.attemptID)
        let first = Task { @MainActor in
            await surface.launch(for: identity, resumeRewindSeconds: 0,
                orientation: { if !inFactory { await suspend() } })
        }
        _ = await entered.wait()
        factory.onMake = nil
        guard case .success = await surface.launch(for: identity, resumeRewindSeconds: 0, orientation: {}) else {
            Issue.record("Newer library presentation rejected"); return
        }
        release.signal(true)
        guard case .failure(.supersededPresentation) = await first.value else {
            Issue.record("Old library presentation escaped its generation"); return
        }
        await f.finish()
    }

    @Test(arguments: DownloadLifecycle.allCases)
    func sheetsConsumeTheExactLibraryPresentation(lifecycle: DownloadLifecycle) async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        var row = f.record
        row.lifecycle = lifecycle
        row.status = lifecycle.derivedStatus
        let libraryRow = DownloadOptionsModel.existingRow(row)
        let library = OfflineLibrarySnapshot(rows: [libraryRow], queueToolbarAction: nil,
            isQueuePaused: false, aggregateStats: .empty)
        let list = OfflineLibraryView.rowPresentation(libraryRow)
        let sheet = DownloadOptionsSheet.existingPresentation(row, library: library)
        #expect(sheet == list)
        #expect(libraryRow.statusCaption.isEmpty || sheet.accessibleStatus.contains(libraryRow.statusCaption))
        for action in sheet.actions { #expect(sheet.actionLabel(action).contains(libraryRow.title)) }
        await f.finish()
    }

}

@MainActor
private final class P7LibraryStubFactory: OfflinePlaybackLaunchFactory {
    let fixture: P7PlaybackFixture
    let sink: P7LibraryStubSink
    var identities: [OfflineDownloadRowActionIdentity] = []
    var rewinds: [Int] = []
    var onMake: (() async -> Void)?
    private var generation: UInt64 = 0
    init(_ fixture: P7PlaybackFixture) {
        self.fixture = fixture
        sink = P7LibraryStubSink(key: fixture.key)
    }
    func beginPresentationRequest() -> OfflinePlaybackPresentationRequest {
        generation += 1
        return .init(generation: generation)
    }
    func makeLaunch(for identity: OfflineDownloadRowActionIdentity,
                    request: OfflinePlaybackPresentationRequest, resumeRewindSeconds: Int) async
        -> Result<OfflinePlaybackLaunch, OfflinePlaybackLaunchRejection> {
        identities.append(identity); rewinds.append(resumeRewindSeconds)
        await onMake?()
        guard let record = fixture.manager.currentRecord(for: identity), record.isComplete else {
            return .failure(.staleAttempt)
        }
        let item = DetailPlaybackLauncher.itemWithResumeRewind(
            record.metadata!.makeMediaItem(), resumeRewindSeconds: resumeRewindSeconds)
        // Intentionally permissive about request generation: the surface must fence its own tasks.
        return .success(.init(attemptKey: fixture.key, presentationRequest: request,
            fileURL: record.localURL, item: item, backend: .emby, posterURL: nil,
            preview: .embyBIF(nil), chapters: [], chapterImageURLs: [:], textSubtitles: [], events: sink))
    }
}

@MainActor
private final class P7LibraryStubSink: OfflinePlaybackEventSink {
    let attemptKey: DownloadAttemptKey
    let sessionGeneration = OfflinePlaybackSessionGeneration(rawValue: UUID())
    var positions: [Int] = []
    init(key: DownloadAttemptKey) { attemptKey = key }
    func progress(positionMs: Int, durationMs: Int?) { positions.append(positionMs) }
    func playbackObserved() {}
    func close(finalSample: OfflinePlaybackProgressSample) { positions.append(finalSample.positionMs) }
}

#endif
