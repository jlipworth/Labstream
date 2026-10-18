import Foundation
import Testing
@testable import PMSKit

struct P7DownloadPresentationTests {
    private func row(_ lifecycle: DownloadLifecycle, fraction: Double? = nil,
                     admission: DownloadAdmissionIntent? = nil) -> OfflineDownloadRowSnapshot {
        var record = DownloadRecord(ratingKey: "fixture", attemptID: DownloadAttemptID(rawValue: "attempt-a"),
            title: "Fixture", localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
            status: lifecycle.derivedStatus,
            metadata: OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
                requestedProfileLabel: "Fixture quality", backendKind: .plex))
        record.lifecycle = lifecycle
        record.admissionIntent = admission
        return OfflineLibrarySnapshotBuilder.make(records: [record], isQueuePaused: false,
            aggregateSpeedBytesPerSecond: nil, errorMessage: { _ in lifecycle == .failed ? "Fixture failure reason" : nil },
            displayProgress: { _ in fraction }, statusCaption: { _, _ in "Full fixture status" },
            isRetrying: { _ in false }).rows[0]
    }

    @Test(arguments: DownloadLifecycle.allCases)
    func colorsOnlyCarryTheirDocumentedMeaning(lifecycle: DownloadLifecycle) {
        let presentation = row(lifecycle).presentation
        switch lifecycle {
        case .complete: #expect(presentation.tone == .verified)
        case .unverified: #expect(presentation.tone == .caution)
        case .failed: #expect(presentation.tone == .failure)
        default: #expect(presentation.tone == .neutral)
        }
        #expect(presentation.accessibleStatus.contains("Full fixture status"))
        #expect(presentation.actionIdentity.attemptID == DownloadAttemptID(rawValue: "attempt-a"))
        for action in presentation.actions { #expect(presentation.actionLabel(action).contains("Fixture")) }
    }

    @Test func waitingAndPausedHaveNoTransferSpinner() {
        for lifecycle in [DownloadLifecycle.planned, .admitted, .paused] {
            #expect(row(lifecycle).presentation.progress == .none)
        }
        #expect(row(.planned).presentation.symbol == "clock")
        #expect(row(.paused).presentation.actions == [.resume, .delete])
        let retryWaiting = row(.failed, admission: .retryRequested).presentation
        #expect(retryWaiting.lifecycle == .planned)
        #expect(retryWaiting.tone == .neutral)
        #expect(retryWaiting.progress == .none)
        #expect(retryWaiting.actions == [.pause, .delete])
    }

    @Test func zeroPreparationIsIndeterminateAndNonterminalFractionsStopAt99() {
        #expect(row(.serverPrep, fraction: 0).presentation.progress == .indeterminate)
        #expect(row(.serverPrep, fraction: 0.42).presentation.progress == .fraction(0.42, estimated: false))
        #expect(row(.transferring, fraction: 0.995).presentation.progress == .fraction(0.99, estimated: false))
        #expect(row(.serverPrep, fraction: 0.999).presentation.progress == .indeterminate)
        #expect(row(.finalizing, fraction: 1).presentation.progress == .indeterminate)
        #expect(row(.finalizing).presentation.actions == [.delete])
    }

    @Test func deletionCopyIsSharedAndCountsCapturedRows() {
        let single = DownloadRemovalMessage.message(cancelsServerPrep: true)
        #expect(single.contains("paused/in-prep") || single.contains("Paused/in-prep"))
        #expect(single.contains("unfinished server preparation where supported; finished server versions remain"))
        #expect(DownloadRemovalMessage.message(count: 3, cancelsServerPrep: true).contains("3 downloads"))
        #expect(!DownloadRemovalMessage.message(cancelsServerPrep: false).contains("server preparation"))
    }
    @Test func liveCaptionPhaseControlsBackendWaitingAndServerIndexing() {
        let preparing = row(.serverPrep, fraction: 0.75)
        let waiting = DownloadRowPresentation(row: preparing, phase: .waitingForBackend)
        #expect(waiting.lifecycle == .admitted)
        #expect(waiting.progress == .none)
        #expect(waiting.symbol == "clock")
        let indexing = DownloadRowPresentation(row: preparing, phase: .serverPrepFinalizing)
        #expect(indexing.lifecycle == .serverPrep)
        #expect(indexing.progress == .indeterminate)
        #expect(indexing.tone == .neutral)
    }

    @Test func estimatedProgressRemainsDistinctFromStaticFractions() {
        let metadata = OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
            backendKind: .jellyfin, downloadLane: .optimize, resumeMode: .liveForwardOnly)
        var record = DownloadRecord(ratingKey: "jellyfin:fixture", title: "Fixture",
            localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"), bytes: 128,
            status: .downloading, metadata: metadata, sideAssetBytes: 64)
        record.lifecycle = .transferring
        let snapshot = OfflineLibrarySnapshotBuilder.make(records: [record], isQueuePaused: false,
            aggregateSpeedBytesPerSecond: nil, errorMessage: { _ in nil }, displayProgress: { _ in 0.5 },
            statusCaption: { _, _ in "~50% • 128 bytes media • 64 bytes extras" },
            isRetrying: { _ in false }).rows[0]
        #expect(snapshot.progressIsEstimated)
        #expect(snapshot.presentation.progress == .fraction(0.5, estimated: true))
        #expect(snapshot.presentation.accessibleStatus.contains("128 bytes media"))
        #expect(snapshot.presentation.accessibleStatus.contains("64 bytes extras"))
    }

}
