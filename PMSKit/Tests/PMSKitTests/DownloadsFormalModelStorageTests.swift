import Foundation
import Testing
@testable import PMSKit

/// The Swift side of `specs/downloads/DownloadsStorage.tla`.
///
/// The first tests hold the model's policy operators equal to the Swift policies over the small
/// integers the model uses, so that a change to either side fails here. The last one pins the
/// finding the model reported (`Storage-Finding-S1-RequeueErasesPark.cfg`) with
/// `withKnownIssue`: it states the wanted behaviour, stays green while the finding is open, and
/// fails once a fix lands. Remove the wrapper then and flip the config to `EXPECT: pass`.
@Suite("Downloads formal model: storage")
struct DownloadsFormalModelStorageTests {
    private typealias P = DownloadStorageAdmissionPolicy
    private typealias R = DownloadLifecycleReducer

    // MARK: - The model's operators equal the Swift policies

    /// `RequiredAdditional` in the spec. An unknown size is 0 there and nil here.
    private static func modelRequiredAdditional(expected: Int, checkpoint: Int, held: Int,
                                                peak: Int, sideFuture: Int, headroom: Int) -> Int {
        guard expected > 0 else { return peak + sideFuture + headroom }
        let onDisk = (checkpoint > expected ? 0 : checkpoint) + held
        return max(0, expected - onDisk) + peak + sideFuture + headroom
    }

    @Test("RequiredAdditional equals requiredAdditionalFreeBytes on the model's bounds")
    func requiredAdditionalMatchesThePolicy() {
        for expected in 0...3 { for checkpoint in 0...4 { for held in 0...1 {
            for peak in 0...2 { for side in 0...1 { for headroom in 0...1 {
                let swift = P.requiredAdditionalFreeBytes(
                    expectedBytes: expected == 0 ? nil : expected,
                    durableCheckpointBytes: checkpoint, heldBodyBytes: held,
                    largestPendingAppendBytes: peak, futureSideAssetBytes: side,
                    headroomBytes: Int64(headroom))
                let model = Self.modelRequiredAdditional(
                    expected: expected, checkpoint: checkpoint, held: held, peak: peak,
                    sideFuture: side, headroom: headroom)
                #expect(swift == Int64(model),
                        "expected \(expected) checkpoint \(checkpoint) held \(held) peak \(peak)")
            } } }
        } } }
    }

    /// One row as the model sees it.
    private struct ModelRow {
        var retained: Int
        var side: Int
        var estimate: Int   // 0 is unknown
        var active: Bool

        /// `ContributionWith(r, TRUE)` in the spec.
        var contribution: Int {
            retained + side + (active && estimate > 0 ? max(0, estimate - retained) : 0)
        }

        func capRow(_ id: String) -> DownloadStorageAdmissionPolicy.CapRow {
            .init(id: id, retainedBytes: retained, sideAssetBytes: side,
                  estimatedTotalBytes: active && estimate > 0 ? estimate : nil,
                  reservesRemaining: active)
        }
    }

    @Test("Contribution, Projection and CapRejects equal the cap policy on the model's bounds")
    func capOperatorsMatchThePolicy() {
        var shapes: [ModelRow] = []
        for retained in 0...2 { for side in 0...1 { for estimate in [0, 2] { for active in [false, true] {
            shapes.append(ModelRow(retained: retained, side: side, estimate: estimate, active: active))
        } } } }
        for own in shapes { for other in shapes {
            #expect(own.capRow("own").contribution == own.contribution)
            let rows = [own.capRow("own"), other.capRow("other")]
            #expect(P.capUsage(rows) == own.contribution + other.contribution)
            // Projection(r): a retry of "own" by its estimate replaces its own row (B24).
            let adding: Int? = own.estimate > 0 ? own.estimate : nil
            let projected = P.capProjection(rows: rows, addingBytes: adding, replacingRowID: "own")
            let model = own.estimate == 0
                ? own.contribution + other.contribution
                : other.contribution + own.estimate + own.side
            #expect(projected == model)
            for limit in 0...4 {
                let refused = P.capRejection(rows: rows, addingBytes: adding,
                                             replacingRowID: "own", limitBytes: limit) != nil
                #expect(refused == (limit > 0 && own.estimate > 0 && model > limit))
            }
        } }
    }

    /// B26 and B31 as the model uses them: an ENOSPC completion is storage-full on the
    /// forward-only lane, and the failure the app submits for it is durable and is not a
    /// relaunch candidate.
    @Test("A storage-full failure is classified and durable")
    func storageFullIsClassifiedAndDurable() {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCannotWriteToFile, hasResumeData: true,
            supportsPersistedResumeData: false, isOutOfSpace: true) == .failStorageFull)
        for lifecycle in [DownloadLifecycle.admitted, .transferring, .paused] {
            let failed = R.reduce(DownloadLifecycleState(lifecycle: lifecycle),
                                  .transferFailed(.storage),
                                  facts: DownloadRowFacts(route: .staticRange)).state
            #expect(failed?.lifecycle == .failed)
            #expect(failed?.history.lastFailure == .storage)
        }
        let parked = DownloadLifecycleState(
            lifecycle: .failed, history: DownloadAttemptHistory(lastFailure: .storage))
        let relaunch = R.reduce(parked, .relaunchObserved,
                                facts: DownloadRowFacts(route: .staticRange, checkpoint: .durablePartial(bytes: 1)))
        #expect(relaunch.state == parked)
        #expect(relaunch.effects.isEmpty)
    }

    // MARK: - Finding S1

    /// S1. A static-range row fails because the disk is full: the row is `failed(storage)` and
    /// the manager remembers `.storageFull` in `lastError`, which is what the automatic-redrive
    /// gate reads. An automatic edge then arrives while the backend session is away (the usual
    /// case just after launch). `resumeStaticRangeWhenReady` checks the backend before the
    /// storage gate, so it requeues the row (`requeued` clears the durable storage reason) and
    /// overwrites `lastError`. When the session returns, the redrive finds neither record and
    /// retries against the same full disk without measuring: a new attempt, a request rebuild
    /// and a checkpoint copy or start preflight that fails again.
    ///
    /// Wanted: either the storage reason survives the automatic requeue durably, or the gate
    /// runs before the row is deferred for a missing backend.
    @Test("S1: an automatic requeue never erases a storage-full park")
    func automaticRequeueKeepsTheStoragePark() throws {
        let resume = try #require(Self.appFunctionSource(
            named: "resumeStaticRangeWhenReady",
            in: "Labstream/Capabilities/Downloads/Core/DownloadManager.swift"))
        let gate = try #require(resume.range(of: "range_auto_resume_parked"))
        let backendDeferral = try #require(resume.range(
            of: "deferStaticRangeResume(record: record, reason: reason, preserveActiveIntent: true)"))
        // The deferral this function takes for a missing backend keeps the row queued.
        #expect(StaticRangeRecoveryPolicy.deferredResumeDisposition(
            checkpointBytes: 1, preserveActiveIntent: true) == .queuedActiveIntent)

        let parked = DownloadLifecycleState(
            lifecycle: .failed, history: DownloadAttemptHistory(lastFailure: .storage))
        let requeued = R.reduce(parked, .requeued, facts: DownloadRowFacts(route: .staticRange))

        withKnownIssue("TLA+ finding S1 (#486): an automatic requeue erases the storage-full park") {
            let reasonSurvives = requeued.state == nil
                || requeued.state?.history.lastFailure == .storage
                || requeued.state?.history.storagePark != nil
            let gateRunsFirst = gate.lowerBound < backendDeferral.lowerBound
            #expect(reasonSurvives || gateRunsFirst,
                    "a storage-parked row is requeued and later redriven without re-measuring")
        }
    }

    /// The text of one function in an app source file, from its declaration to the next member
    /// at the same indentation. Nil when the file or the function is missing.
    private static func appFunctionSource(named name: String, in relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8),
              let start = source.range(of: "    private func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = ["\n    private func ", "\n    func ", "\n    var "]
            .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(source[start.lowerBound..<end])
    }
}
