import Foundation
import PMSKit
import XCTest
import os
@testable import Labstream

final class SideAssetFetchCoordinatorTests: XCTestCase {
    func testNonpersistentTransportPolicyDisablesCredentialStores() {
        let configuration = SideAssetTransportPolicy.nonpersistentConfiguration()

        XCTAssertNil(configuration.identifier)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.requestCachePolicy,
                       .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testRequestGatewayPreservesAuthenticationAndCallerSemanticsWhileForcingReload() async throws {
        let url = try XCTUnwrap(URL(string: "https://emby.example/Items/42?api_key=query-secret"))
        let captured = TestLockedBox<URLRequest?>(nil)
        let stub = TestURLProtocolStub { request in
            captured.withValue { $0 = request }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data([4, 2]))
        }
        let session = URLSession(configuration: stub.configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad,
                                 timeoutInterval: 17)
        request.httpMethod = "POST"
        request.httpBody = Data("body-secret".utf8)
        request.setValue("Bearer header-secret", forHTTPHeaderField: "Authorization")
        request.setValue("emby-secret", forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.allowsCellularAccess = false

        // Darwin's custom URLProtocol bridge does not reliably expose upload bytes through
        // URLProtocol.request.httpBody, even though URLSession still sends them. Verify body
        // preservation at the policy boundary; keep the protocol capture for the request
        // properties that Foundation exposes consistently end to end.
        let transportRequest = SideAssetTransportPolicy.nonpersistentRequest(request)
        XCTAssertEqual(transportRequest.httpBody, Data("body-secret".utf8))

        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let data = try await coordinator.fetch(
            request: request,
            owner: SideAssetOwner(rawValue: "chapter-owner"),
            session: session
        )

        XCTAssertEqual(data, Data([4, 2]))
        let observed = try XCTUnwrap(captured.value)
        XCTAssertEqual(observed.url, url)
        XCTAssertEqual(observed.httpMethod, "POST")
        XCTAssertEqual(observed.value(forHTTPHeaderField: "Authorization"),
                       "Bearer header-secret")
        XCTAssertEqual(observed.value(forHTTPHeaderField: "X-Emby-Token"), "emby-secret")
        XCTAssertEqual(observed.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(observed.timeoutInterval, 17, accuracy: 0.001)
        XCTAssertFalse(observed.allowsCellularAccess)
        XCTAssertEqual(observed.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testCredentialBearingRequestIdentityIsHashedAndIdentifierReflectionIsRedacted() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://plex.example/photo?X-Plex-Token=query-secret")))
        request.setValue("Bearer header-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("body-secret".utf8)

        let key = SideAssetRequestKey.authenticatedRequest(request)
        let origin = SideAssetOrigin(rawValue: "https://private-server.example:443")
        let owner = SideAssetOwner(rawValue: "private-rating-key\u{0}private-attempt")
        var reflected = ""
        dump((key: key, origin: origin, owner: owner), to: &reflected)
        reflected += String(reflecting: key)
        reflected += String(reflecting: origin)
        reflected += String(reflecting: owner)

        for secret in ["query-secret", "header-secret", "body-secret",
                       "private-server", "private-rating-key", "private-attempt"] {
            XCTAssertFalse(key.rawValue.contains(secret))
            XCTAssertFalse(reflected.contains(secret))
        }
        XCTAssertEqual(key, SideAssetRequestKey.authenticatedRequest(request))
    }

    func testDefaultTransportNormalizesCredentialBearingURLError() async throws {
        let secretURL = try XCTUnwrap(URL(
            string: "https://plex.example/photo?X-Plex-Token=must-not-escape"))
        let stub = TestURLProtocolStub { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: URLError.cannotConnectToHost.rawValue,
                userInfo: [NSURLErrorFailingURLErrorKey: secretURL]
            )
        }
        let session = URLSession(configuration: stub.configuration)
        defer { session.invalidateAndCancel() }
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)

        do {
            _ = try await coordinator.fetch(
                request: URLRequest(url: secretURL),
                owner: SideAssetOwner(rawValue: "chapter-owner"),
                session: session
            )
            XCTFail("expected transport failure")
        } catch let error as SideAssetFetchError {
            XCTAssertEqual(error, .transportFailure(code: URLError.cannotConnectToHost.rawValue))
            XCTAssertFalse(String(reflecting: error).contains("must-not-escape"))
        }
    }

    func testCancellingLastRequestWaiterCancelsURLSessionTask() async throws {
        let started = expectation(description: "URLProtocol request started")
        let stopped = expectation(description: "URLProtocol request cancelled")
        SideAssetCancellationURLProtocol.install(started: started, stopped: stopped)
        defer { SideAssetCancellationURLProtocol.reset() }
        let configuration = SideAssetTransportPolicy.nonpersistentConfiguration(
            protocolClasses: [SideAssetCancellationURLProtocol.self])
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let request = URLRequest(url: URL(string: "https://side-asset-cancel.example/chapter")!)
        let task = Task {
            try await coordinator.fetch(
                request: request,
                owner: SideAssetOwner(rawValue: "chapter-owner"),
                session: session
            )
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testRequestGatewayPacesPlayerChapterBurstByOrigin() async throws {
        let clock = AdvancingSideAssetClock()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 2, maximumConcurrentRequests: 2),
            clock: clock.dependency
        )
        let owner = SideAssetOwner(rawValue: "player-chapter-thumbnails")

        let tasks = (0..<48).map { index in
            Task {
                var request = URLRequest(url: URL(string: "https://emby.example/emby/Items/50388/Images/Chapter/\(index)")!)
                request.setValue("secret", forHTTPHeaderField: "X-Emby-Token")
                return try await coordinator.fetch(request: request, owner: owner) {
                    await recorder.record(owner: owner.rawValue)
                }
            }
        }
        for task in tasks { _ = try await task.value }

        let admissions = await coordinator.recordedAdmissionsForTesting()
        XCTAssertEqual(admissions.count, 48)
        XCTAssertTrue(zip(admissions, admissions.dropFirst()).allSatisfy {
            $1.timeNanoseconds - $0.timeNanoseconds >= 500_000_000
        })
    }

    func testTwoDownloadIncidentIsGloballyPacedAndFair() async throws {
        let clock = AdvancingSideAssetClock()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 2, maximumConcurrentRequests: 2),
            clock: clock.dependency
        )
        let origin = SideAssetOrigin(rawValue: "origin")
        let first = SideAssetOwner(rawValue: "first")
        let second = SideAssetOwner(rawValue: "second")
        await coordinator.setParked(true, for: first)
        await coordinator.setParked(true, for: second)

        var tasks: [Task<Data, any Error>] = []
        for index in 0..<32 {
            tasks.append(Task {
                try await coordinator.fetch(
                    origin: origin,
                    owner: first,
                    requestKey: .init(rawValue: "first-\(index)")
                ) { await recorder.record(owner: "first") }
            })
            await Task.yield()
        }
        for index in 0..<52 {
            tasks.append(Task {
                try await coordinator.fetch(
                    origin: origin,
                    owner: second,
                    requestKey: .init(rawValue: "second-\(index)")
                ) { await recorder.record(owner: "second") }
            })
            await Task.yield()
        }

        let countWhileParked = await recorder.count
        XCTAssertEqual(countWhileParked, 0)
        await coordinator.setParked(false, for: first)
        await coordinator.setParked(false, for: second)
        for task in tasks { _ = try await task.value }

        let admissions = await coordinator.recordedAdmissionsForTesting()
        XCTAssertEqual(admissions.count, 84)
        XCTAssertTrue(zip(admissions, admissions.dropFirst()).allSatisfy {
            $1.timeNanoseconds - $0.timeNanoseconds >= 500_000_000
        })
        XCTAssertEqual(Array(admissions.prefix(64).map(\.owner.rawValue)),
                       (0..<64).map { $0.isMultiple(of: 2) ? "first" : "second" })
    }

    func testConcurrencyIsBoundedAcrossOwnersAtOneOrigin() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 100, maximumConcurrentRequests: 2),
            clock: clock.dependency
        )
        let tasks = (0..<5).map { index in
            Task {
                try await coordinator.fetch(
                    origin: .init(rawValue: "origin"),
                    owner: .init(rawValue: "owner-\(index % 2)"),
                    requestKey: .init(rawValue: "request-\(index)")
                ) {
                    await recorder.begin(owner: "owner")
                    await gate.wait()
                    await recorder.end()
                    return Data([1])
                }
            }
        }
        await waitUntil { await recorder.count == 2 }
        let maximumWhileBlocked = await recorder.maximumActive
        XCTAssertEqual(maximumWhileBlocked, 2)
        await gate.releaseAll()
        for task in tasks { _ = try await task.value }
        let finalMaximum = await recorder.maximumActive
        XCTAssertEqual(finalMaximum, 2)
    }

    func testIdenticalInFlightRequestIsCoalesced() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let request = SideAssetRequestKey(rawValue: "same")
        let first = Task {
            try await coordinator.fetch(origin: origin, owner: .init(rawValue: "a"), requestKey: request) {
                await calls.increment()
                await gate.wait()
                return Data([7])
            }
        }
        await waitUntil { await calls.value == 1 }
        let second = Task {
            try await coordinator.fetch(origin: origin, owner: .init(rawValue: "b"), requestKey: request) {
                XCTFail("coalesced operation must not run")
                return Data()
            }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 2
        }
        await gate.releaseAll()
        let firstData = try await first.value
        let secondData = try await second.value
        let callCount = await calls.value
        XCTAssertEqual(firstData, Data([7]))
        XCTAssertEqual(secondData, Data([7]))
        XCTAssertEqual(callCount, 1)
    }

    func testTransportAdmissionChargesOnlyTheOperationThatActuallyStarts() async throws {
        let gate = SideAssetGate()
        let admissions = SideAssetCounter()
        let operations = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let request = URLRequest(url: URL(string: "https://assets.example/poster")!)
        let first = Task {
            try await coordinator.fetch(
                request: request, owner: .init(rawValue: "attempt-a"),
                onTransportAdmission: { await admissions.increment() },
                operation: {
                    await operations.increment()
                    await gate.wait()
                    return Data([1])
                })
        }
        await waitUntil { await operations.value == 1 }
        let second = Task {
            try await coordinator.fetch(
                request: request, owner: .init(rawValue: "attempt-b"),
                onTransportAdmission: {
                    XCTFail("coalesced waiter must not consume retry budget")
                },
                operation: {
                    XCTFail("coalesced operation must not start")
                    return Data()
                })
        }
        let origin = SideAssetOrigin(rawValue: "https://assets.example:443")
        let requestKey = SideAssetRequestKey.authenticatedRequest(
            SideAssetTransportPolicy.nonpersistentRequest(request))
        await waitUntil {
            await coordinator.waiterCountForTesting(
                origin: origin, requestKey: requestKey) == 2
        }
        await gate.releaseAll()
        _ = try await (first.value, second.value)
        let admissionCount = await admissions.value
        let operationCount = await operations.value
        XCTAssertEqual(admissionCount, 1)
        XCTAssertEqual(operationCount, 1)
    }

    func testSuccessfulSuspendedAdmissionFundsSurvivorWhenFundingWaiterCancels() async throws {
        let admissionGate = SideAssetGate()
        let firstAdmissions = SideAssetCounter()
        let secondAdmissions = SideAssetCounter()
        let operations = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let request = SideAssetRequestKey(rawValue: "shared-admission")

        let first = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "attempt-a"), requestKey: request,
                onTransportAdmission: {
                    await firstAdmissions.increment()
                    await admissionGate.wait()
                }) {
                    await operations.increment()
                    return Data([7])
                }
        }
        await waitUntil { await firstAdmissions.value == 1 }

        let second = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "attempt-b"), requestKey: request,
                onTransportAdmission: { await secondAdmissions.increment() }) {
                    XCTFail("coalesced operation must not start")
                    return Data()
                }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 2
        }

        first.cancel()
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 1
        }
        await admissionGate.releaseAll()

        do {
            _ = try await first.value
            XCTFail("cancelled funding waiter should observe cancellation")
        } catch is CancellationError {}
        let survivorData = try await second.value
        let firstAdmissionCount = await firstAdmissions.value
        let secondAdmissionCount = await secondAdmissions.value
        let operationCount = await operations.value
        XCTAssertEqual(survivorData, Data([7]))
        XCTAssertEqual(firstAdmissionCount, 1)
        XCTAssertEqual(secondAdmissionCount, 0)
        XCTAssertEqual(operationCount, 1)
    }

    func testWaiterJoiningCancelledEmptyRunningJobIsReadmittedAndSucceeds() async throws {
        let cancelledOperationGate = SideAssetGate()
        let firstAdmissions = SideAssetCounter()
        let survivorAdmissions = SideAssetCounter()
        let operationCalls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let request = SideAssetRequestKey(rawValue: "cancelled-running-job")

        let cancelled = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "attempt-a"), requestKey: request,
                onTransportAdmission: { await firstAdmissions.increment() }) {
                    await operationCalls.increment()
                    if await operationCalls.value == 1 {
                        await cancelledOperationGate.wait()
                        try Task.checkCancellation()
                    }
                    return Data([8])
                }
        }
        await waitUntil { await operationCalls.value == 1 }
        cancelled.cancel()
        _ = await cancelled.result
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 0
        }

        let survivor = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "attempt-b"), requestKey: request,
                onTransportAdmission: { await survivorAdmissions.increment() }) {
                    XCTFail("requeued request must retain its single canonical operation")
                    return Data()
                }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 1
        }
        await cancelledOperationGate.releaseAll()

        let survivorData = try await survivor.value
        let firstAdmissionCount = await firstAdmissions.value
        let survivorAdmissionCount = await survivorAdmissions.value
        let operationCount = await operationCalls.value
        XCTAssertEqual(survivorData, Data([8]))
        XCTAssertEqual(firstAdmissionCount, 1)
        XCTAssertEqual(survivorAdmissionCount, 1)
        XCTAssertEqual(operationCount, 2)
    }

    func testQueuedCancellationMovesAdmissionAuthorityToSurvivingOwner() async throws {
        let gate = SideAssetGate()
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 1_000,
                          maximumConcurrentRequests: 1),
            clock: AdvancingSideAssetClock().dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let blocker = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "blocker"),
                requestKey: .init(rawValue: "blocker")) {
                    await gate.wait()
                    return Data([0])
                }
        }
        await waitUntil { await coordinator.activeCountForTesting(origin: origin) == 1 }

        let staleAdmissions = SideAssetCounter()
        let survivorAdmissions = SideAssetCounter()
        let request = SideAssetRequestKey(rawValue: "coalesced")
        let first = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "attempt-a"), requestKey: request,
                onTransportAdmission: { await staleAdmissions.increment() }) {
                    return Data([1])
                }
        }
        let second = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "attempt-b"), requestKey: request,
                onTransportAdmission: { await survivorAdmissions.increment() }) {
                    return Data([2])
                }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 2
        }
        first.cancel()
        _ = await first.result
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 1
        }
        await gate.releaseAll()
        _ = try await blocker.value
        let survivorData = try await second.value
        XCTAssertEqual(survivorData, Data([1])) // transport is request-equivalent
        let staleCount = await staleAdmissions.value
        let survivorCount = await survivorAdmissions.value
        XCTAssertEqual(staleCount, 0)
        XCTAssertEqual(survivorCount, 1)
    }

    func testRejectedCoalescedAdmissionHandsOffWithoutDoubleCharging() async throws {
        let gate = SideAssetGate()
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 1_000,
                          maximumConcurrentRequests: 1),
            clock: AdvancingSideAssetClock().dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let blocker = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "blocker"),
                requestKey: .init(rawValue: "blocker")) {
                    await gate.wait(); return Data([0])
                }
        }
        await waitUntil { await coordinator.activeCountForTesting(origin: origin) == 1 }

        let rejectedCharges = SideAssetCounter()
        let acceptedCharges = SideAssetCounter()
        let operations = SideAssetCounter()
        let request = SideAssetRequestKey(rawValue: "handoff")
        let rejected = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "stale"), requestKey: request,
                onTransportAdmission: {
                    await rejectedCharges.increment()
                    throw SideAssetFetchError.retryBudgetExhausted
                }) {
                    await operations.increment()
                    return Data([9])
                }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 1
        }
        let accepted = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "current"), requestKey: request,
                onTransportAdmission: { await acceptedCharges.increment() }) {
                    XCTFail("coalesced transport must retain a single operation")
                    return Data()
                }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: request) == 2
        }
        await gate.releaseAll()
        _ = try await blocker.value
        do {
            _ = try await rejected.value
            XCTFail("rejected waiter should receive its admission failure")
        } catch let error as SideAssetFetchError {
            XCTAssertEqual(error, .retryBudgetExhausted)
        }
        let acceptedData = try await accepted.value
        let rejectedCount = await rejectedCharges.value
        let acceptedCount = await acceptedCharges.value
        let operationCount = await operations.value
        XCTAssertEqual(acceptedData, Data([9]))
        XCTAssertEqual(rejectedCount, 1)
        XCTAssertEqual(acceptedCount, 1)
        XCTAssertEqual(operationCount, 1)
    }

    func testTaskCancellationWinsWhenSuccessfulCompletionRacesCancellation() async {
        // The operation deliberately ignores cooperative cancellation and returns success at the
        // same boundary where the caller is cancelled. Actor serialization prevents a double
        // resume, while fetch's post-resume check makes the externally observed result stable
        // regardless of whether completion or cancelWaiter reaches the coordinator first.
        for iteration in 0..<100 {
            let clock = AdvancingSideAssetClock()
            let gate = SideAssetGate()
            let calls = SideAssetCounter()
            let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
            let task = Task {
                try await coordinator.fetch(
                    origin: .init(rawValue: "origin"),
                    owner: .init(rawValue: "owner"),
                    requestKey: .init(rawValue: "race-\(iteration)")
                ) {
                    await calls.increment()
                    await gate.wait()
                    return Data([7])
                }
            }

            await waitUntil { await calls.value == 1 }
            task.cancel()
            await gate.releaseAll()

            do {
                _ = try await task.value
                XCTFail("cancelled waiter must not observe a successful completion")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
            let indexedWaiters = await coordinator.waiterJobIndexCountForTesting()
            XCTAssertEqual(indexedWaiters, 0)
        }
    }

    func testWaiterJobIndexTracksCoalescedCancellationAndCompletion() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let origin = SideAssetOrigin(rawValue: "origin")
        let request = SideAssetRequestKey(rawValue: "shared-index")

        let cancelled = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "cancelled"), requestKey: request
            ) {
                await calls.increment()
                await gate.wait()
                return Data([3])
            }
        }
        await waitUntil { await calls.value == 1 }
        let survivor = Task {
            try await coordinator.fetch(
                origin: origin, owner: .init(rawValue: "survivor"), requestKey: request
            ) {
                XCTFail("coalesced operation must not run")
                return Data()
            }
        }
        await waitUntil {
            await coordinator.waiterJobIndexCountForTesting() == 2
        }

        cancelled.cancel()
        await waitUntil {
            await coordinator.waiterJobIndexCountForTesting() == 1
        }
        do {
            _ = try await cancelled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        await gate.releaseAll()
        let survivorData = try await survivor.value
        XCTAssertEqual(survivorData, Data([3]))
        let finalIndexCount = await coordinator.waiterJobIndexCountForTesting()
        XCTAssertEqual(finalIndexCount, 0)
    }

    func testExistingNonemptyFileBypassesNetwork() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([4, 2]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: AdvancingSideAssetClock().dependency)
        let data = try await coordinator.fetch(
            origin: .init(rawValue: "origin"),
            owner: .init(rawValue: "owner"),
            requestKey: .init(rawValue: "request"),
            existingFile: file
        ) {
            await calls.increment()
            return Data([9])
        }
        XCTAssertEqual(data, Data([4, 2]))
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testParkPreventsStartUntilResumeAndCancelRemovesQueuedOwnerWork() async throws {
        let clock = AdvancingSideAssetClock()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let owner = SideAssetOwner(rawValue: "owner")
        let origin = SideAssetOrigin(rawValue: "origin")
        let resumeRequest = SideAssetRequestKey(rawValue: "resume")
        await coordinator.setParked(true, for: owner)
        let resumed = Task {
            try await coordinator.fetch(
                origin: origin, owner: owner, requestKey: resumeRequest
            ) {
                await calls.increment()
                return Data([1])
            }
        }
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: resumeRequest) == 1
        }
        let countWhileParked = await calls.value
        XCTAssertEqual(countWhileParked, 0)
        await coordinator.setParked(false, for: owner)
        let resumedData = try await resumed.value
        XCTAssertEqual(resumedData, Data([1]))

        await coordinator.setParked(true, for: owner)
        let cancelRequest = SideAssetRequestKey(rawValue: "cancel")
        let cancelled = Task {
            try await coordinator.fetch(
                origin: origin, owner: owner, requestKey: cancelRequest
            ) { XCTFail("cancelled queued work must not start"); return Data() }
        }
        // Task.yield() does not order the unstructured task's actor enqueue before cancel(owner:).
        // Wait for the queued waiter so this test exercises cancellation of existing owner work,
        // rather than the distinct case where cancellation reaches an empty coordinator first.
        await waitUntil {
            await coordinator.waiterCountForTesting(origin: origin, requestKey: cancelRequest) == 1
        }
        await coordinator.cancel(owner: owner)
        do {
            _ = try await cancelled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    func testParkedCoalescedOwnerDoesNotBlockActiveOwnerOrCancelSharedRequest() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let calls = SideAssetCounter()
        let coordinator = SideAssetFetchCoordinator(clock: clock.dependency)
        let parked = SideAssetOwner(rawValue: "parked")
        let active = SideAssetOwner(rawValue: "active")
        let request = SideAssetRequestKey(rawValue: "shared")
        await coordinator.setParked(true, for: parked)
        let first = Task {
            try await coordinator.fetch(
                origin: .init(rawValue: "origin"), owner: parked, requestKey: request
            ) {
                await calls.increment()
                await gate.wait()
                return Data([8])
            }
        }
        await Task.yield()
        let second = Task {
            try await coordinator.fetch(
                origin: .init(rawValue: "origin"), owner: active, requestKey: request
            ) { XCTFail("coalesced operation must not run"); return Data() }
        }
        await waitUntil { await calls.value == 1 }
        await coordinator.cancel(owner: parked)
        await gate.releaseAll()
        do {
            _ = try await first.value
            XCTFail("parked owner's waiter should be cancelled")
        } catch is CancellationError {}
        let secondData = try await second.value
        XCTAssertEqual(secondData, Data([8]))
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testDifferentOriginsProgressIndependently() async throws {
        let clock = AdvancingSideAssetClock()
        let gate = SideAssetGate()
        let recorder = SideAssetStartRecorder(clock: clock)
        let coordinator = SideAssetFetchCoordinator(
            policy: .init(maximumRequestStartsPerSecond: 1, maximumConcurrentRequests: 1),
            clock: clock.dependency
        )
        let tasks = ["a", "b"].map { origin in
            Task {
                try await coordinator.fetch(
                    origin: .init(rawValue: origin), owner: .init(rawValue: origin),
                    requestKey: .init(rawValue: origin)
                ) {
                    await recorder.begin(owner: origin)
                    await gate.wait()
                    await recorder.end()
                    return Data([1])
                }
            }
        }
        await waitUntil { await recorder.count == 2 }
        let maximumActive = await recorder.maximumActive
        XCTAssertEqual(maximumActive, 2)
        await gate.releaseAll()
        for task in tasks { _ = try await task.value }
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not reached")
    }
}

private final class AdvancingSideAssetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var now: UInt64 { lock.withLock { value } }

    var dependency: SideAssetCoordinatorClock {
        SideAssetCoordinatorClock(
            nowNanoseconds: { [self] in now },
            sleepUntilNanoseconds: { [self] deadline in
                lock.withLock { value = max(value, deadline) }
                await Task.yield()
            }
        )
    }
}

private actor SideAssetStartRecorder {
    struct Start: Equatable { let owner: String; let time: UInt64 }
    private let clock: AdvancingSideAssetClock
    private(set) var starts: [Start] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    var count: Int { starts.count }

    init(clock: AdvancingSideAssetClock) { self.clock = clock }

    func record(owner: String) -> Data {
        starts.append(.init(owner: owner, time: clock.now))
        return Data([1])
    }

    func begin(owner: String) {
        starts.append(.init(owner: owner, time: clock.now))
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() { active -= 1 }
}

private actor SideAssetGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SideAssetCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class SideAssetCancellationURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var startedExpectation: XCTestExpectation?
        var stoppedExpectation: XCTestExpectation?
    }
    private static let state = TestLockedBox(State())

    static func install(started: XCTestExpectation, stopped: XCTestExpectation) {
        state.withValue {
            $0.startedExpectation = started
            $0.stoppedExpectation = stopped
        }
    }

    static func reset() { state.withValue { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "side-asset-cancel.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let expectation = Self.state.withValue { state in
            defer { state.startedExpectation = nil }
            return state.startedExpectation
        }
        expectation?.fulfill()
    }

    override func stopLoading() {
        let expectation = Self.state.withValue { state in
            defer { state.stoppedExpectation = nil }
            return state.stoppedExpectation
        }
        expectation?.fulfill()
    }
}

final class DownloadSideAssetRetryBudgetTests: XCTestCase {
    private let source = OfflineSideAssetSourceIdentity(
        backendKind: .plex, backendBaseURLString: "https://one.example",
        backendServerID: "server", mediaSourceID: "source", mediaIndex: 0,
        partIndex: 0, sourcePartID: 7, downloadLane: .original,
        serverPreparedVersion: false)

    private func identity(attempt: String = "attempt-a",
                          source: OfflineSideAssetSourceIdentity? = nil,
                          kind: DownloadSideAssetKind = .poster,
                          resource: String? = nil) -> DownloadSideAssetRetryIdentity {
        DownloadSideAssetRetryIdentity(
            attemptKey: DownloadAttemptKey(
                ratingKey: "row", attemptID: DownloadAttemptID(rawValue: attempt)!),
            source: source ?? self.source,
            kind: kind,
            resource: resource)
    }

    func testChargesOnlyExplicitDispatchAndStopsAtBound() {
        var budget = DownloadSideAssetRetryBudget()
        let key = identity()
        XCTAssertTrue(budget.canDispatch(key, maximum: 2)) // inventory is free
        XCTAssertTrue(budget.chargeDispatch(key, maximum: 2))
        XCTAssertTrue(budget.chargeDispatch(key, maximum: 2))
        XCTAssertFalse(budget.chargeDispatch(key, maximum: 2))
        XCTAssertFalse(budget.canDispatch(key, maximum: 2))
    }

    func testBudgetIsExactAttemptSourceAndKindScoped() {
        var budget = DownloadSideAssetRetryBudget()
        let exhausted = identity()
        XCTAssertTrue(budget.chargeDispatch(exhausted, maximum: 1))
        XCTAssertFalse(budget.canDispatch(exhausted, maximum: 1))
        XCTAssertTrue(budget.canDispatch(identity(attempt: "attempt-b"), maximum: 1))
        XCTAssertTrue(budget.canDispatch(identity(kind: .plexBIF), maximum: 1))
        XCTAssertTrue(budget.canDispatch(identity(resource: "other-poster"), maximum: 1))

        var otherSource = source
        otherSource.mediaSourceID = "replacement-source"
        XCTAssertTrue(budget.canDispatch(identity(source: otherSource), maximum: 1))
    }
}

final class DownloadSideAssetServiceTests: XCTestCase {
    func testPreparationValidatesOffMainBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "side-asset-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidURL = directory.appendingPathComponent("invalid.jpg")
        let rejected = await DownloadSideAssetService.prepare(
            Data("server error".utf8), as: .image, at: invalidURL)
        XCTAssertFalse(rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidURL.path))

        let validPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let validURL = directory.appendingPathComponent("valid.png")
        let observedMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let prepared = await DownloadSideAssetService.prepare(
            validPNG, as: .image, at: validURL,
            executionProbe: { isMain in observedMain.withLock { $0 = isMain } })
        XCTAssertTrue(prepared)
        XCTAssertEqual(observedMain.withLock { $0 }, false)
        XCTAssertEqual(try Data(contentsOf: validURL), validPNG)
    }

    func testValidatorsRejectWrongPayloadClass() {
        let subtitle = Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello".utf8)
        XCTAssertTrue(DownloadSideAssetService.validate(subtitle, as: .textSubtitle))
        XCTAssertFalse(DownloadSideAssetService.validate(subtitle, as: .image))
        XCTAssertFalse(DownloadSideAssetService.validate(Data("<html>error</html>".utf8), as: .bif))
    }

    func testRepairInventoryIncludesEveryDerivablePlexPayloadClass() {
        let attemptID = DownloadAttemptID(rawValue: "attempt")!
        let metadata = OfflineMetadata(
            ratingKey: "row", title: "Title", type: "movie", thumb: "/poster",
            chapters: [OfflineChapter(thumb: "/chapter")],
            offlineTextSubtitles: [OfflineTextSubtitleTrack(
                id: 1, displayName: "English", relativePath: "missing.vtt")],
            backendKind: .plex, mediaSourceID: "source")
        let record = DownloadRecord(
            ratingKey: "row", attemptID: attemptID, title: "Title",
            localURL: URL(fileURLWithPath: "/tmp/media.mp4"), bytes: 1,
            progress: 1, status: .complete, metadata: metadata)

        XCTAssertEqual(DownloadSideAssetRepairInventory.missingKinds(
            record: record, fileExists: { _ in false }),
            [.poster, .plexBIF, .chapterImages, .textSubtitles])
    }

    func testRepairInventoryIncludesMediaBrowserPreviewAndSubtitleDiscovery() {
        let attemptID = DownloadAttemptID(rawValue: "attempt")!
        for (backend, expectedPreview) in [
            (DownloadBackendKind.jellyfin, DownloadSideAssetKind.jellyfinTrickPlay),
            (.emby, .embyBIF),
        ] {
            let metadata = OfflineMetadata(
                ratingKey: "row", title: "Title", type: "movie",
                backendKind: backend, mediaSourceID: "selected-source")
            let record = DownloadRecord(
                ratingKey: "row", attemptID: attemptID, title: "Title",
                localURL: URL(fileURLWithPath: "/tmp/media.mp4"), bytes: 1,
                progress: 1, status: .complete, metadata: metadata)
            let missing = DownloadSideAssetRepairInventory.missingKinds(
                record: record, fileExists: { _ in false })
            XCTAssertTrue(missing.contains(expectedPreview))
            XCTAssertTrue(missing.contains(.textSubtitles))
        }
    }

    func testJellyfinRepairInventoryFindsPlaylistReferencedUnpersistedTile() {
        let attemptID = DownloadAttemptID(rawValue: "attempt")!
        let metadata = OfflineMetadata(
            ratingKey: "jellyfin:row", title: "Title", type: "movie",
            jellyfinTrickPlayPlaylistRelativePath: "trickplay.m3u8",
            jellyfinTrickPlayTileRelativePaths: ["tile-0.jpg"],
            backendKind: .jellyfin, mediaSourceID: "source")
        let record = DownloadRecord(
            ratingKey: "jellyfin:row", attemptID: attemptID, title: "Title",
            localURL: URL(fileURLWithPath: "/tmp/media.mp4"), bytes: 1,
            progress: 1, status: .complete, metadata: metadata)

        let missing = DownloadSideAssetRepairInventory.missingKinds(
            record: record,
            fileExists: { ["trickplay.m3u8", "tile-0.jpg"].contains($0) },
            jellyfinPlaylistTiles: { _ in ["tile-0.jpg", "tile-1.jpg"] })
        XCTAssertTrue(missing.contains(.jellyfinTrickPlay))

        let complete = DownloadSideAssetRepairInventory.missingKinds(
            record: record,
            fileExists: {
                ["trickplay.m3u8", "tile-0.jpg", "tile-1.jpg"].contains($0)
            },
            jellyfinPlaylistTiles: { _ in ["tile-0.jpg", "tile-1.jpg"] })
        XCTAssertFalse(complete.contains(.jellyfinTrickPlay))

        let unreadable = DownloadSideAssetRepairInventory.missingKinds(
            record: record,
            fileExists: { $0 == "trickplay.m3u8" },
            jellyfinPlaylistTiles: { _ in nil })
        XCTAssertTrue(unreadable.contains(.jellyfinTrickPlay))

        let unsafeLoaderCalls = OSAllocatedUnfairLock(initialState: 0)
        let unowned = DownloadSideAssetRepairInventory.missingKinds(
            record: record,
            fileExists: { _ in false },
            jellyfinPlaylistTiles: { _ in
                unsafeLoaderCalls.withLock { $0 += 1 }
                return ["tile-0.jpg"]
            })
        XCTAssertTrue(unowned.contains(.jellyfinTrickPlay))
        XCTAssertEqual(unsafeLoaderCalls.withLock { $0 }, 0)
    }

    func testRepairRetryResourcesMatchTransportAdmissionDiscriminators() {
        let attemptID = DownloadAttemptID(rawValue: "attempt")!
        let metadata = OfflineMetadata(
            ratingKey: "row", title: "Title", type: "movie",
            chapters: [OfflineChapter(thumb: "/zero"), OfflineChapter(thumb: "/one")],
            chapterImageRelativePaths: [0: "chapter-0.jpg"],
            backendKind: .jellyfin, mediaSourceID: "source")
        let record = DownloadRecord(
            ratingKey: "row", attemptID: attemptID, title: "Title",
            localURL: URL(fileURLWithPath: "/tmp/media.mp4"), bytes: 1,
            progress: 1, status: .complete, metadata: metadata)

        XCTAssertEqual(DownloadSideAssetRepairInventory.retryResources(
            for: .textSubtitles, record: record, fileExists: { _ in false },
            chapterResource: { "chapter-\($0).jpg" }), ["source-metadata"])
        XCTAssertEqual(DownloadSideAssetRepairInventory.retryResources(
            for: .plexBIF, record: record, fileExists: { _ in false },
            chapterResource: { "chapter-\($0).jpg" }), ["source-metadata"])
        XCTAssertEqual(DownloadSideAssetRepairInventory.retryResources(
            for: .jellyfinTrickPlay, record: record, fileExists: { _ in false },
            chapterResource: { "chapter-\($0).jpg" }), ["playlist"])
        XCTAssertEqual(DownloadSideAssetRepairInventory.retryResources(
            for: .chapterImages, record: record,
            fileExists: { $0 == "chapter-0.jpg" },
            chapterResource: { "chapter-\($0).jpg" }), ["chapter-1.jpg"])
    }

    func testPublicationBatchMergesAllFilesInOneMutation() {
        var metadata = OfflineMetadata(ratingKey: "row", title: "Title", type: "movie")
        let track = OfflineTextSubtitleTrack(
            id: 1, displayName: "English", relativePath: "one.vtt")
        let batch = DownloadSideAssetPublicationBatch(
            chapterImages: [0: "chapter-0.jpg", 2: "chapter-2.jpg"],
            textSubtitles: [track, track],
            jellyfinTiles: ["tile-0.jpg", "tile-0.jpg", "tile-1.jpg"],
            jellyfinPlaylist: "trickplay.m3u8")

        batch.apply(to: &metadata)
        XCTAssertEqual(metadata.chapterImageRelativePaths,
                       [0: "chapter-0.jpg", 2: "chapter-2.jpg"])
        XCTAssertEqual(metadata.offlineTextSubtitles, [track])
        XCTAssertEqual(metadata.jellyfinTrickPlayTileRelativePaths,
                       ["tile-0.jpg", "tile-1.jpg"])
        XCTAssertEqual(metadata.jellyfinTrickPlayPlaylistRelativePath, "trickplay.m3u8")
    }
}
