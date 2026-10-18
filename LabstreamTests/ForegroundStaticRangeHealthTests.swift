#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("Foreground static range health", .serialized)
struct ForegroundStaticRangeHealthTests {
    private let segment = StaticRangeTransferConfiguration.segmentBytes

    @Test("Only the slow selection is replaced; healthy sibling and attempt survive")
    func selectedTaskAndOneShot() async throws {
        try await withSession { session, store, requests, clock, counters, key in
            let tasks = await session.healthTasksForTesting().sorted { $0.taskIdentifier < $1.taskIdentifier }
            let old = try #require(tasks.first)
            let healthy = try #require(tasks.last)
            try await baseline(session, clock)
            counters.withLock { $0[healthy.taskIdentifier] = 60 * 1_024 * 1_024 }
            clock.advance(to: 70)
            #expect(await requests.waitForCount(3).count == 3)
            let live = await session.healthTasksForTesting()
            #expect(live.contains { $0.taskIdentifier == healthy.taskIdentifier })
            #expect(!live.contains { $0.taskIdentifier == old.taskIdentifier })
            #expect(store.ownsAttempt(key))
            #expect(store.checkpointStorageDiagnostics.copyBeginCount == 0)
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            try #require(await wait { self.hasTimer(clock, at: 100) })
            clock.advance(to: 100)
            #expect(await result.wait(seconds: 3) == "observed")
            session.noteStaticRangeHealthActivity(false)
            session.noteStaticRangeHealthActivity(true)
            session.observeStaticRangeHealthAfterReconciliation()
            clock.advance(to: 110)
            try #require(await wait { self.hasTimer(clock, at: 170) })
            let evaluated = P6Acknowledgement<Bool>()
            session.healthWindowEvaluatedForTesting = { evaluated.signal(true) }
            clock.advance(to: 170)
            try #require(await evaluated.wait(seconds: 3) == true)
            #expect(await requests.count == 3)
        }
    }

    @Test("Two rows with two crawling background tasks each reissue by second eighty")
    func resultObservationDoesNotSerializeRows() async throws {
        try await withSession { session, store, requests, clock, counters, _ in
            let second = DownloadAttemptKey(ratingKey: "plex:second", attemptID: DownloadAttemptID(rawValue: "second")!)
            let row = DownloadRecord(ratingKey: second.ratingKey, attemptID: second.attemptID, title: "Fixture",
                localURL: store.destinationURL(ratingKey: second.ratingKey, ext: "mp4"), status: .downloading,
                metadata: OfflineMetadata(ratingKey: second.ratingKey, title: "Fixture", type: "movie",
                    sourcePartSize: 2 * segment, backendKind: .plex, resumeMode: .staticByteRange))
            try #require(store.createAttemptOwnedRecord(row, attemptID: second.attemptID) == .committed(second))
            session.noteBackgroundCompletionHandlerStored(identifier: BackgroundDownloadSession.identifier)
            try session.start(ratingKey: second.ratingKey, from: URL(string: "https://example.invalid/second")!,
                expectedBytes: 2 * segment, byteRangeCheckpoint: true)
            defer { session.cancel(ratingKey: second.ratingKey) }
            try #require(await requests.waitForCount(4).count == 4)
            session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
            try #require(await wait { session.diagnosticSnapshot(includePendingTempCleanupBytes: false).backgroundCompletionHandlerCount == 0 })
            let originals = await session.healthTasksForTesting().sorted { $0.taskIdentifier < $1.taskIdentifier }
            try await baseline(session, clock)
            counters.withLock { values in
                for task in originals { values[task.taskIdentifier] = 60 * 60 * 1_024 }
            }
            clock.advance(to: 70)
            // No result timer is fired: both serialized mutations must settle in this window.
            try #require(await requests.waitForCount(6).count == 6)
            clock.advance(to: 80)
            let live = await session.healthTasksForTesting()
            for pair in [Array(originals.prefix(2)), Array(originals.suffix(2))] {
                #expect(pair.filter { old in live.contains { $0.taskIdentifier == old.taskIdentifier } }.count == 1)
            }
            #expect(live.count == 4)
            #expect(await requests.count == 6)
        }
    }

    @Test("A sibling finishing after claim remains coverage before its application")
    func siblingFinishesBetweenClaimAndRefill() async throws {
        try await withSession(bytes: segment + 64) { session, store, requests, clock, _, key in
            let tail = try #require(await requests.waitForCount(2).first { $0.range == "bytes=\(segment)-\(segment + 63)" })
            let claimed = P6Acknowledgement<Bool>()
            let finished = P6Acknowledgement<Bool>()
            let suspended = Mutex(false)
            defer { if suspended.withLock({ $0 }) { session.releaseRangeIOForTesting() } }
            session.healthDidClaimForTesting = {
                session.holdRangeIOForTesting()
                suspended.withLock { $0 = true }
                claimed.signal(true)
            }
            session.rangeTrackingDroppedForTesting = { _ in finished.signal(true) }
            try await baseline(session, clock)
            clock.advance(to: 70)
            try #require(await claimed.wait(seconds: 3) == true)
            tail.finish(status: 206, body: Data(repeating: 7, count: 64), headers: [
                "Content-Range": "bytes \(segment)-\(segment + 63)/\(segment + 64)", "ETag": "\"fixture\"",
            ])
            try #require(await finished.wait(seconds: 3) == true)
            #expect(session.claimedRangeBodiesForTesting().count == 1)
            // The refill was enqueued by claim, ahead of this sibling's assembly callback.
            suspended.withLock { $0 = false }
            session.releaseRangeIOForTesting()
            let all = await requests.waitForCount(3)
            try #require(await wait { store.record(for: key)?.metadata?.heldRangeSegments?.count == 1 })
            #expect(all.filter { $0.range == tail.range }.count == 1)
            let live = await session.healthTasksForTesting()
            #expect(live.count + (store.record(for: key)?.metadata?.heldRangeSegments?.count ?? 0) == 2)
            #expect(await requests.count == 3)
        }
    }

    @Test("Connectivity restored before baseline is eligible; interruption inside measurement defers", arguments: [false, true])
    func connectivityWindow(interruptDuringWindow: Bool) async throws {
        try await withSession(bytes: segment) { session, _, requests, clock, counters, _ in
            let task = try #require(await session.healthTasksForTesting().first as? URLSessionDownloadTask)
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            session.noteForegroundAuthorization()
            session.noteStaticRangeHealthActivity(true)
            session.urlSession(URLSession.shared, taskIsWaitingForConnectivity: task)
            session.observeStaticRangeHealthAfterReconciliation()
            clock.advance(to: 5)
            session.urlSession(URLSession.shared, downloadTask: task, didWriteData: 1_024,
                totalBytesWritten: 1_024, totalBytesExpectedToWrite: Int64(segment))
            counters.withLock { $0[task.taskIdentifier] = 1_024 }
            clock.advance(to: 10)
            try #require(await wait { hasTimer(clock, at: 70) })
            if interruptDuringWindow {
                clock.advance(to: 40)
                session.urlSession(URLSession.shared, taskIsWaitingForConnectivity: task)
                clock.advance(to: 45)
                session.urlSession(URLSession.shared, downloadTask: task, didWriteData: 1_024,
                    totalBytesWritten: 2_048, totalBytesExpectedToWrite: Int64(segment))
            }
            counters.withLock { $0[task.taskIdentifier] = 60 * 60 * 1_024 }
            clock.advance(to: 70)
            if interruptDuringWindow {
                #expect(await result.wait(seconds: 3) == "window_deferred")
                #expect(await requests.count == 1)
            } else { #expect(await requests.waitForCount(2).count == 2) }
        }
    }

    @Test("A finished held tail and validator survive head replacement")
    func heldTailPreserved() async throws {
        try await withSession(bytes: segment + 64) { session, store, requests, clock, _, key in
            let initial = await requests.waitForCount(2)
            let tail = try #require(initial.first { $0.range == "bytes=\(segment)-\(segment + 63)" })
            tail.finish(status: 206, body: Data(repeating: 7, count: 64), headers: [
                "Content-Range": "bytes \(segment)-\(segment + 63)/\(segment + 64)", "ETag": "\"fixture\"",
            ])
            try #require(await wait { (store.record(for: key)?.metadata?.heldRangeSegments ?? []).count == 1 &&
                session.diagnosticSnapshot(includePendingTempCleanupBytes: false).pendingBackgroundCompletionOperationCount == 0 })
            let held = session.claimedRangeBodiesForTesting()
            let validator = store.rangeValidator(for: key)
            try await baseline(session, clock)
            clock.advance(to: 70)
            #expect(await requests.waitForCount(3).count == 3)
            #expect(session.claimedRangeBodiesForTesting() == held)
            #expect(held.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            #expect(store.rangeValidator(for: key) == validator)
            #expect(store.ownsAttempt(key))
        }
    }

    @Test("Finish winning before the claim settles its body without revocation")
    func finishWinsClaim() async throws {
        let bytes = 4 * 1_024 * 1_024
        try await withSession(bytes: bytes) { session, store, requests, clock, _, key in
            let claim = P6Hold(); claim.arm()
            defer { claim.release.signal() }
            session.healthWillClaimForTesting = { claim.hit() }
            let result = P6Acknowledgement<String>()
            let finished = P6Acknowledgement<Bool>()
            session.healthResultForTesting = { result.signal($0) }
            session.rangeTrackingDroppedForTesting = { _ in finished.signal(true) }
            try await baseline(session, clock)
            clock.advance(to: 70)
            try #require(await claim.acknowledgement.wait(seconds: 3) == true)
            let request = try #require(await requests.waitForCount(1).first)
            request.finish(status: 206, body: Data(repeating: 9, count: bytes),
                headers: ["Content-Range": "bytes 0-\(bytes - 1)/\(bytes)"])
            try #require(await finished.wait(seconds: 3) == true)
            claim.release.signal()
            #expect(await result.wait(seconds: 3) == "body_settled")
            try #require(await wait { store.record(for: key)?.bytes == bytes })
            #expect(await requests.count == 1)
            #expect(await wait { session.claimedRangeBodiesForTesting().isEmpty })
        }
    }

    @Test("Admission remains occupied through the cancellation-to-registration gap")
    func admissionGap() async throws {
        try await withSession(bytes: segment) { session, _, requests, clock, _, key in
            let hold = P6Hold(); hold.arm()
            defer { hold.release.signal() }
            session.healthDidClaimForTesting = { hold.hit() }
            try await baseline(session, clock)
            clock.advance(to: 70)
            try #require(await hold.acknowledgement.wait(seconds: 3) == true)
            #expect(!session.isTrackingTransfer(ratingKey: key.ratingKey))
            #expect(session.ownsInProgressStaticRangeWork(ratingKey: key.ratingKey))
            hold.release.signal()
            #expect(await requests.waitForCount(2).count == 2)
        }
    }

    @Test("Inactivity during the real resume flush parks then refills the missing head beside a live sibling", arguments: [false, true])
    func inactiveOrFailedFlush(fails: Bool) async throws {
        let hold = P6Hold()
        let failWrite = Mutex(false)
        defer { hold.release.signal() }
        try await withSession(index: .init { data, url in
            hold.hit()
            if failWrite.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
            try DownloadIndexFileCommitter().commit(data, to: url)
        }) { session, store, requests, clock, counters, key in
            let tail = try #require(await session.healthTasksForTesting().max { $0.taskIdentifier < $1.taskIdentifier })
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            session.healthDidClaimForTesting = { hold.arm() }
            try await baseline(session, clock)
            counters.withLock { $0[tail.taskIdentifier] = 60 * 1_024 * 1_024 }
            clock.advance(to: 70)
            try #require(await hold.acknowledgement.wait(seconds: 3) == true)
            // Joining the range queue proves the replacement registered and its resume is awaiting this write.
            await session.drainRangeIOForTesting()
            #expect(await requests.count == 2)
            if fails { failWrite.withLock { $0 = true } }
            else { session.noteStaticRangeHealthActivity(false) }
            hold.release.signal()
            #expect(await result.wait(seconds: 3) == "resume_deferred")
            #expect(await requests.count == 2)
            #expect(store.ownsAttempt(key))
            #expect(await session.healthTasksForTesting().contains { $0.taskIdentifier == tail.taskIdentifier })
            if !fails {
                session.noteForegroundAuthorization()
                session.noteStaticRangeHealthActivity(true)
                session.observeStaticRangeHealthAfterReconciliation()
                #expect(await requests.waitForCount(3).count == 3)
                let live = await session.healthTasksForTesting()
                #expect(live.count == 2)
                #expect(live.contains { $0.taskIdentifier == tail.taskIdentifier })
                // Renewed observation cannot spend another recovery budget for this attempt.
                clock.advance(to: 80)
                try #require(await wait { hasTimer(clock, at: 140) })
                let evaluated = P6Acknowledgement<Bool>()
                session.healthWindowEvaluatedForTesting = { evaluated.signal(true) }
                clock.advance(to: 140)
                try #require(await evaluated.wait(seconds: 3) == true)
                #expect(await requests.count == 3)
            }
        }
    }

    @Test("Checkpoint persistence failure leaves the original task authoritative")
    func failedCheckpointKeepsOriginal() async throws {
        let fail = Mutex(false)
        try await withSession(index: .init { data, url in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
            try DownloadIndexFileCommitter().commit(data, to: url)
        }, bytes: segment) { session, store, requests, clock, _, key in
            let original = try #require(await session.healthTasksForTesting().first)
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            try await baseline(session, clock)
            fail.withLock { $0 = true }
            _ = store.submitRangeValidator(for: key, "fixture")
            clock.advance(to: 70)
            #expect(await result.wait(seconds: 3) == "checkpoint_deferred")
            #expect(await requests.count == 1)
            #expect(await session.healthTasksForTesting().contains { $0.taskIdentifier == original.taskIdentifier })
            fail.withLock { $0 = false }
        }
    }

    @Test("An expired physical P6 operation defers recovery until it actually settles")
    func expiredPhysicalOperation() async throws {
        try await withSession { session, _, requests, clock, _, _ in
            try await baseline(session, clock)
            session.noteBackgroundCompletionHandlerStored(identifier: BackgroundDownloadSession.identifier)
            session.beginBackgroundCompletionOperationForTesting()
            clock.advance(to: 40)
            session.noteForegroundAuthorization()
            clock.advance(to: 70)
            try #require(await wait { self.hasTimer(clock, at: 71) })
            #expect(await requests.count == 2)
            session.endBackgroundCompletionOperationForTesting()
            clock.advance(to: 71)
            #expect(await requests.waitForCount(3).count == 3)
        }
    }

    @Test("Unknown relaunch provenance is observed without reissue")
    func unknownProvenance() async throws {
        try await withSession { session, _, requests, clock, _, _ in
            session.forgetHealthProvenanceForTesting()
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            try await baseline(session, clock)
            clock.advance(to: 70)
            #expect(await result.wait(seconds: 3) == "provenance")
            #expect(await requests.count == 2)
        }
    }

    @Test("A fresh counter above the cap refuses without consuming the task")
    func freshDiscardRefusal() async throws {
        try await withSession(bytes: segment) { session, _, requests, clock, counters, _ in
            let tasks = await session.healthTasksForTesting()
            let id = try #require(tasks.first?.taskIdentifier)
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            session.healthWillClaimForTesting = { counters.withLock { $0[id] = 256 * 1_024 * 1_024 + 1 } }
            try await baseline(session, clock)
            clock.advance(to: 70)
            #expect(await result.wait(seconds: 3) == "discardCap")
            #expect(await requests.count == 1)
            #expect(await session.healthTasksForTesting().contains { $0.taskIdentifier == id })
        }
    }

    @Test("Pause, delete and backend sign-out revoke an in-flight recovery", arguments: ["pause", "delete", "sign_out"])
    @MainActor
    func userIntentDuringRecovery(action: String) async throws {
        try await withSession(bytes: segment) { session, store, requests, clock, _, key in
            let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "health-recovery"))
            let manager = DownloadManager(appModel: model, store: store, session: session,
                                          registerForBackgroundEvents: false)
            try #require(await manager.awaitStartupRecoveryForTesting())
            manager.setQueuePausedForTesting(false)
            manager.refreshRecords()
            let claimed = P6Hold(); claimed.arm()
            defer { claimed.release.signal() }
            session.healthDidClaimForTesting = { claimed.hit() }
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            try await baseline(session, clock)
            clock.advance(to: 70)
            try #require(await claimed.acknowledgement.wait(seconds: 3) == true)
            switch action {
            case "pause": manager.pause(ratingKey: key.ratingKey)
            case "delete":
                session.haltForDeletion(attemptKey: key)
                #expect(store.remove(for: key) == .applied)
            default: manager.pauseDownloadsForBackendSignOut(.plex)
            }
            claimed.release.signal()
            #expect(await result.wait(seconds: 3) == "refill_deferred")
            try #require(await p6AwaitTask(Task { await manager.drainManagerOperationsForTesting() }))
            session.noteStaticRangeHealthActivity(false)
            session.noteStaticRangeHealthActivity(true)
            session.observeStaticRangeHealthAfterReconciliation()
            await session.drainRangeIOForTesting()
            #expect(await requests.count == 1)
            #expect(!session.isTrackingTransfer(ratingKey: key.ratingKey))
            if action == "delete" { #expect(store.record(for: key) == nil) }
            else { #expect(store.record(for: key)?.status == .paused) }
        }
    }

    @Test("Result reports stop-edge rate and independently answers the three evidence questions",
          arguments: ["paused", "cancelled", "completed", "error"])
    func renderedStopResult(outcome: String) async throws {
        let enabled = AppDiagnostics.isEnabled
        AppDiagnostics.setEnabled(true)
        defer { AppDiagnostics.setEnabled(enabled) }
        let bytes = 4 * 1_024 * 1_024
        try await withSession(bytes: bytes) { session, _, requests, clock, counters, key in
            try await baseline(session, clock)
            clock.advance(to: 70)
            try #require(await requests.waitForCount(2).count == 2)
            try #require(await wait { hasTimer(clock, at: 100) })
            let task = try #require(await session.healthTasksForTesting().first)
            let result = P6Acknowledgement<String>()
            session.healthResultForTesting = { result.signal($0) }
            counters.withLock { $0[task.taskIdentifier] = bytes }
            clock.advance(to: 75)
            switch outcome {
            case "paused": session.pause(ratingKey: key.ratingKey)
            case "cancelled":
                session.urlSession(URLSession.shared, taskIsWaitingForConnectivity: task)
                session.cancel(ratingKey: key.ratingKey)
            case "error": session.urlSession(URLSession.shared, task: task,
                didCompleteWithError: URLError(.networkConnectionLost))
            default:
                let request = try #require(await requests.waitForCount(2).last)
                request.finish(status: 206, body: Data(repeating: 7, count: bytes),
                    headers: ["Content-Range": "bytes 0-\(bytes - 1)/\(bytes)"])
            }
            #expect(await result.wait(seconds: 3) == outcome)
            if outcome == "paused" { #expect(session.healthBookkeepingForTesting.used == 1) }
            if outcome == "cancelled" { #expect(session.healthBookkeepingForTesting.used == 1) }
            let event = try #require(AppDiagnostics.events().last {
                $0.name == "downloads.range_health_result" && $0.fields["outcome"] == .label(outcome)
                    && $0.fields["new_task_id"] == .int(task.taskIdentifier)
            })
            #expect(event.fields["post_seconds"] == .double(5))
            #expect(event.fields["post_rate"] == .double(Double(bytes) / 5))
            #expect(event.fields["pre_rate"] == .double(0))
            let report = DiagnosticReportRenderer.render(context: .init(product: "Labstream",
                appVersion: "1", appBuild: "1", operatingSystem: "macOS", deviceName: "Fixture",
                backend: "Plex", selectedQuality: "Original", loggingEnabled: true),
                events: Array(repeating: DiagnosticEvent(category: .downloads, name: "fixture.progress"), count: 79) + [event],
                maxEvents: AppDiagnostics.maxReportEvents)
            #expect(event.fields["old_task_id"] != event.fields["new_task_id"])
            for evidence in ["\"creation_context\":\"background_wake\"", "\"old_task_id\":", "\"new_task_id\":",
                             "\"pre_rate\":0", "\"post_rate\":838860.8", "\"post_seconds\":5", "\"outcome\":\"\(outcome)\""] {
                #expect(report.contains(evidence))
            }
            // Its original timer must never emit another result or dilute the rate to 30 s.
            clock.advance(to: 100)
            #expect(AppDiagnostics.events().filter {
                $0.name == "downloads.range_health_result" && $0.fields["new_task_id"] == .int(task.taskIdentifier)
            }.last?.fields["outcome"] == .label(outcome))
        }
    }

    @Test("Terminal attempts retire the process-local budget and obsolete connectivity entries")
    func terminalBookkeeping() async throws {
        try await withSession(bytes: segment) { session, store, requests, clock, _, key in
            try await baseline(session, clock)
            clock.advance(to: 70)
            try #require(await requests.waitForCount(2).count == 2)
            try #require(await wait { hasTimer(clock, at: 100) })
            #expect(session.healthBookkeepingForTesting.used == 1)
            let task = try #require(await session.healthTasksForTesting().first)
            session.urlSession(URLSession.shared, taskIsWaitingForConnectivity: task)
            #expect(session.healthBookkeepingForTesting.waiting == 1)
            let request = try #require(await requests.waitForCount(2).last)
            request.finish(status: 404, body: Data([0]), headers: [:])
            try #require(await wait { store.lifecycleState(for: key)?.lifecycle == .failed })
            try #require(await wait { session.healthBookkeepingForTesting.used == 0 })
            #expect(session.healthBookkeepingForTesting.waiting == 0)
        }
    }

    private func hasTimer(_ clock: P6WakeClock, at seconds: UInt64) -> Bool {
        clock.state.withLock { $0.timers.contains { $0.0.kind == .foregroundHealth && $0.0.deadline == seconds * 1_000_000_000 } }
    }
    private func baseline(_ session: BackgroundDownloadSession, _ clock: P6WakeClock) async throws {
        session.noteForegroundAuthorization()
        session.noteStaticRangeHealthActivity(true)
        session.observeStaticRangeHealthAfterReconciliation()
        session.observeStaticRangeHealthAfterReconciliation() // duplicate activation coalesces
        clock.advance(to: 10)
        try #require(await wait { hasTimer(clock, at: 70) })
    }
    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
    private func withSession(index: DownloadStore.IndexPersistence = .live, bytes: Int? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (BackgroundDownloadSession, DownloadStore, HeldRangeRequests, P6WakeClock,
                 HealthCounters, DownloadAttemptKey) async throws -> Void) async throws {
        let fixture = try P6Fixture()
        let store = fixture.store(index: index)
        var row = fixture.record()
        row.metadata?.sourcePartSize = bytes ?? 2 * segment
        let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: row.attemptID!)
        try #require(store.createAttemptOwnedRecord(row, attemptID: key.attemptID) == .committed(key))
        let requests = HeldRangeRequests()
        HealthHeldURLProtocol.requests = requests
        let clock = P6WakeClock()
        let counters = HealthCounters()
        let session = BackgroundDownloadSession(store: store, protocolClasses: [HealthHeldURLProtocol.self], wakeClockHooks: clock.hooks)
        let temps = fixture.directory.appendingPathComponent("NetworkTemps")
        try FileManager.default.createDirectory(at: temps, withIntermediateDirectories: true)
        session.rangeBodyDirectoryForTesting = temps
        session.availableStorageBytesForTesting = Int64.max
        session.healthCounterForTesting = { id in counters.withLock { $0[id] ?? 0 } }
        defer { session.noteStaticRangeHealthActivity(false); session.cancel(ratingKey: key.ratingKey)
            session.invalidateInjectedSessionForTesting(); HealthHeldURLProtocol.requests = nil }
        _ = await withCheckedContinuation { continuation in session.activateCurrentStore { continuation.resume(returning: $0) } }
        session.noteBackgroundCompletionHandlerStored(identifier: BackgroundDownloadSession.identifier)
        try session.start(ratingKey: key.ratingKey, from: URL(string: "https://example.invalid/body")!,
                          expectedBytes: row.metadata?.sourcePartSize, byteRangeCheckpoint: true)
        let count = (bytes ?? 2 * segment) > segment ? 2 : 1
        try #require(await requests.waitForCount(count).count == count)
        session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        try #require(await wait { session.diagnosticSnapshot(includePendingTempCleanupBytes: false).backgroundCompletionHandlerCount == 0 })
        try await body(session, store, requests, clock, counters, key)
        session.noteStaticRangeHealthActivity(false)
        session.cancel(ratingKey: key.ratingKey)
        _ = await wait { session.diagnosticSnapshot(includePendingTempCleanupBytes: false).pendingBackgroundCompletionOperationCount == 0 }
        _ = await store.flushLifecycleAndPersistence(through: store.currentPersistenceTicket(),
            artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 3)
    }
}

private final class HealthHeldURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: HeldRangeRequests?
    private var held: HeldRangeRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { let held = HeldRangeRequest(owner: self); self.held = held; Self.requests?.record(held) }
    override func stopLoading() { if let held { Self.requests?.recordStop(held.id) } }
}
#endif

#if !os(tvOS)
private final class HealthCounters: @unchecked Sendable {
    private let storage = Mutex<[Int: Int]>([:])
    func withLock<T>(_ body: (inout [Int: Int]) -> T) -> T { storage.withLock { body(&$0) } }
}
#endif
