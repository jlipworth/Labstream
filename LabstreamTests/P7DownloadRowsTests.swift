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
        withKnownIssue("P7 red pin: 12-copy") {
            #expect(copy.localizedCaseInsensitiveContains("server"))
            #expect(copy.localizedCaseInsensitiveContains("finished"))
        }
        await f.finish()
    }

    @Test func staleSheetConfirmationCannotDeleteReplacement() async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        let confirmationRatingKey = f.record.ratingKey
        let replacement = f.files.record("b", status: .paused, filename: "replacement.mp4")
        _ = await f.store.resolve(f.store.submitAttemptOwnedRecord(replacement,
            attemptID: replacement.attemptID!, replacing: f.key.attemptID), deadline: .after(5))
        DownloadOptionsSheet.deleteExistingDownload(ratingKey: confirmationRatingKey, manager: f.manager)
        await f.manager.drainManagerOperationsForTesting()
        withKnownIssue("P7 red pin: 12-identity") {
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
        withKnownIssue("P7 red pin: 13") { #expect(actual == expected) }
        await f.finish()
    }
    #endif
}
#endif
