import Foundation
import Testing
@testable import PMSKit

@Suite("Downloads Phase 4 policy compositions")
struct DownloadsPhase4CompositionTests {
    @Test("Resume mode resolves the complete backend by lane and prep-input matrix")
    func resumeModeResolutionMatrix() {
        struct Case {
            let backend: DownloadBackendKind
            let lane: DownloadLane
            let target: String?
            let convertJobID: Int?
            let expected: DownloadResumeMode
        }

        let cases: [Case] = [
            Case(backend: .plex, lane: .original, target: nil, convertJobID: nil, expected: .staticByteRange),
            Case(backend: .plex, lane: .optimize, target: nil, convertJobID: nil, expected: .staticByteRange),
            Case(backend: .plex, lane: .optimize, target: "", convertJobID: nil, expected: .staticByteRange),
            Case(backend: .plex, lane: .optimize, target: "1080p 10 Mbps", convertJobID: nil,
                 expected: .serverPrepThenStatic),
            Case(backend: .plex, lane: .compatibleRemux, target: "ignored", convertJobID: 9,
                 expected: .staticByteRange),
            Case(backend: .jellyfin, lane: .original, target: "ignored", convertJobID: 9,
                 expected: .staticByteRange),
            Case(backend: .jellyfin, lane: .optimize, target: nil, convertJobID: nil,
                 expected: .liveForwardOnly),
            Case(backend: .jellyfin, lane: .compatibleRemux, target: "ignored", convertJobID: 9,
                 expected: .liveForwardOnly),
            Case(backend: .emby, lane: .original, target: nil, convertJobID: nil,
                 expected: .staticByteRange),
            Case(backend: .emby, lane: .optimize, target: nil, convertJobID: nil,
                 expected: .liveForwardOnly),
            Case(backend: .emby, lane: .compatibleRemux, target: nil, convertJobID: nil,
                 expected: .liveForwardOnly),
            Case(backend: .emby, lane: .original, target: nil, convertJobID: 0,
                 expected: .serverPrepThenStatic),
            Case(backend: .emby, lane: .optimize, target: nil, convertJobID: 42,
                 expected: .serverPrepThenStatic),
            Case(backend: .emby, lane: .compatibleRemux, target: nil, convertJobID: 42,
                 expected: .serverPrepThenStatic),
        ]

        for testCase in cases {
            #expect(DownloadResumeMode.resolved(backend: testCase.backend,
                                                lane: testCase.lane,
                                                optimizeTargetName: testCase.target,
                                                embyConvertJobID: testCase.convertJobID)
                    == testCase.expected)
        }
    }

    @Test("Train retry composes v2 identity, reattach, and segment-local blob adoption")
    func trainBlobRetryComposition() {
        let ratingKey = "jellyfin:phase4"
        let attemptID = "attempt-current"
        let segmentOffset = 1_024
        let description = StaticRangeSegmentMarker.taskDescription(
            ratingKey: ratingKey, offset: segmentOffset, attemptID: attemptID)

        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: -1, hasResumeData: true, currentBlobResumeCount: 2) == .resume(nextAttempt: 3))

        let plan = StaticRangeReattachPolicy.plan(
            taskIdentifier: 7,
            downloadID: ratingKey,
            durableBytes: 0,
            requestedOffset: segmentOffset,
            rangeRequestShape: .closed,
            bodyBytesWritten: 256,
            existingTasks: [],
            taskMarker: description,
            rowAttemptID: attemptID)
        #expect(plan.candidateBaseOffset == segmentOffset)
        #expect(plan.disposition == .adopt)
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: segmentOffset,
            durableBytes: 0,
            segmentBaseOffset: plan.candidateBaseOffset) == .adopt(baseOffset: segmentOffset))

        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: -1, hasResumeData: true, currentBlobResumeCount: 3)
                == .reject(.budgetExhausted(nextAttempt: 4, maxResumes: 3)))

        let priorAttempt = StaticRangeReattachPolicy.plan(
            taskIdentifier: 8,
            downloadID: ratingKey,
            durableBytes: 0,
            requestedOffset: segmentOffset,
            rangeRequestShape: .closed,
            bodyBytesWritten: 256,
            existingTasks: [],
            taskMarker: StaticRangeSegmentMarker.taskDescription(
                ratingKey: ratingKey, offset: segmentOffset, attemptID: "attempt-old"),
            rowAttemptID: attemptID)
        #expect(priorAttempt.disposition == .rejectAttemptMismatch(
            taskAttemptID: DownloadAttemptID(rawValue: "attempt-old")!,
            rowAttemptID: DownloadAttemptID(rawValue: attemptID)!))
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: segmentOffset + 1,
            durableBytes: 0,
            segmentBaseOffset: segmentOffset)
                == .rejectStale(blobOffset: segmentOffset + 1, durableBytes: 0))
    }

    @Test("Response classes stay safe at head, middle, and tail train positions")
    func responseClassByTrainPosition() {
        let policy = StaticRangeRemainderRequestPolicy()
        let positions = [0, 512, 1_024]

        for offset in positions {
            let header = policy.rangeHeaderValue(offset: offset, length: 512)
            #expect(RangeTransferHTTPPolicy.rangeRequestStart(header) == offset)
            #expect(RangeTransferHTTPPolicy.rangeRequestShape(header) == .closed)
            #expect(policy.writeDecision(httpStatus: 206) == .append)
            #expect(policy.writeDecision(httpStatus: 200) == .replaceWhole)
            #expect(policy.writeDecision(httpStatus: 416) == .alreadyComplete)
            #expect(policy.writeDecision(httpStatus: 401) == .failServer(status: 401))
            #expect(StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
                storedValidator: "etag-a", responseValidator: "etag-b") == .restartChangedResource)
        }

        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 512,
            expectedBytes: 1_536,
            storedValidator: "etag-a",
            responseValidator: "etag-a",
            responseContentLength: 1_536))
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 1_536,
            expectedBytes: 1_536,
            storedValidator: "etag-a",
            responseValidator: "etag-a",
            responseContentLength: 1_536))
    }

    @Test("Transcode source size never becomes an exact-byte completion requirement")
    func resumeModeExpectedBytesComposition() {
        func record(backend: DownloadBackendKind = .jellyfin,
                    mode: DownloadResumeMode,
                    sourcePartSize: Int? = 1_000) -> DownloadRecord {
            let ratingKey = "\(backend.rawValue):completion-\(mode.rawValue)"
            return DownloadRecord(
                ratingKey: ratingKey,
                title: "Fixture",
                localURL: URL(fileURLWithPath: "/tmp/phase4.mp4"),
                bytes: 500,
                progress: 1,
                status: .downloading,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Fixture",
                    type: "movie",
                    sourcePartSize: sourcePartSize,
                    backendKind: backend,
                    downloadLane: mode == .staticByteRange ? .original : .optimize,
                    resumeMode: mode))
        }

        for backend in [DownloadBackendKind.jellyfin, .emby] {
            let live = record(backend: backend, mode: .liveForwardOnly)
            let liveExactBytes = DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: live)
            #expect(liveExactBytes == nil)
            #expect(DownloadCompletionValidation.outcome(
                played: true,
                probeReason: "ok",
                expectedDurationMs: 10_000,
                actualDurationMs: 10_000,
                downloadedBytes: live.bytes,
                expectedExactBytes: liveExactBytes,
                forwardOnly: true) == .complete)
        }

        let staticRow = record(mode: .staticByteRange)
        let staticExactBytes = DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: staticRow)
        #expect(staticExactBytes == 1_000)
        #expect(DownloadCompletionValidation.outcome(
            played: true,
            probeReason: "ok",
            expectedDurationMs: 10_000,
            actualDurationMs: 10_000,
            downloadedBytes: staticRow.bytes,
            expectedExactBytes: staticExactBytes) == .incompleteBytes(actualBytes: 500, expectedBytes: 1_000))

        let unknownSizeStatic = record(mode: .staticByteRange, sourcePartSize: nil)
        #expect(DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: unknownSizeStatic) == nil)
        #expect(DownloadCompletionValidation.outcome(
            played: true,
            probeReason: "ok",
            expectedDurationMs: 10_000,
            actualDurationMs: 10_000,
            downloadedBytes: unknownSizeStatic.bytes,
            expectedExactBytes: nil) == .complete)
    }
}
