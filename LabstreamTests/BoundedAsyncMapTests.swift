import Testing
@testable import Labstream

struct BoundedAsyncMapTests {
    @Test func maximumInFlightIsBounded() async throws {
        let operation = ControlledOperation()
        let task = Task {
            try await BoundedAsyncMap.results(Array(0..<7), maximumConcurrentTasks: 3) {
                try await operation.perform($0)
            }
        }

        await operation.waitUntilStarted(count: 3)
        var maximumInFlight = await operation.maximumInFlight
        #expect(maximumInFlight == 3)

        for id in 0..<7 {
            await operation.succeed(id, value: id)
            if id < 4 {
                await operation.waitUntilStarted(count: id + 4)
            }
        }

        _ = try await task.value
        maximumInFlight = await operation.maximumInFlight
        #expect(maximumInFlight == 3)
    }

    @Test func reverseCompletionStillReturnsInputOrder() async throws {
        let operation = ControlledOperation()
        let task = Task {
            try await BoundedAsyncMap.results(Array(0..<5), maximumConcurrentTasks: 3) {
                try await operation.perform($0)
            }
        }

        await operation.waitUntilStarted(count: 3)
        await operation.succeed(2, value: 20)
        await operation.waitUntilStarted(count: 4)
        await operation.succeed(1, value: 10)
        await operation.waitUntilStarted(count: 5)
        await operation.succeed(4, value: 40)
        await operation.succeed(3, value: 30)
        await operation.succeed(0, value: 0)

        let results = try await task.value
        #expect(try results.map { try $0.get() } == [0, 10, 20, 30, 40])
    }

    @Test func partialFailureDoesNotDiscardSiblingResults() async throws {
        let operation = ControlledOperation()
        let task = Task {
            try await BoundedAsyncMap.results(Array(0..<3), maximumConcurrentTasks: 2) {
                try await operation.perform($0)
            }
        }

        await operation.waitUntilStarted(count: 2)
        await operation.succeed(0, value: 100)
        await operation.waitUntilStarted(count: 3)
        await operation.fail(1)
        await operation.succeed(2, value: 300)

        let results = try await task.value
        #expect(try results[0].get() == 100)
        if case .success = results[1] {
            Issue.record("Expected the middle operation to fail")
        }
        #expect(try results[2].get() == 300)
    }

    @Test func cancellationStopsSubmittingQueuedOperations() async {
        let operation = ControlledOperation()
        let task = Task {
            try await BoundedAsyncMap.results(Array(0..<6), maximumConcurrentTasks: 2) {
                try await operation.perform($0)
            }
        }

        await operation.waitUntilStarted(count: 2)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let startedIDs = await operation.startedIDs
        #expect(Set(startedIDs) == Set([0, 1]))
        #expect(startedIDs.count == 2)
    }
}

private actor ControlledOperation {
    private struct ProbeError: Error {}

    private var continuations: [Int: CheckedContinuation<Int, Error>] = [:]
    private var cancelledIDs: Set<Int> = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startedIDs: [Int] = []
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    func perform(_ id: Int) async throws -> Int {
        startedIDs.append(id)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        resumeSatisfiedStartWaiters()
        defer { inFlight -= 1 }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledIDs.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func succeed(_ id: Int, value: Int) {
        continuations.removeValue(forKey: id)?.resume(returning: value)
    }

    func fail(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: ProbeError())
    }

    func waitUntilStarted(count: Int) async {
        guard startedIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    private func cancel(_ id: Int) {
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }

    private func resumeSatisfiedStartWaiters() {
        let ready = startWaiters.filter { startedIDs.count >= $0.count }
        startWaiters.removeAll { startedIDs.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
