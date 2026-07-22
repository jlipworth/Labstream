import Foundation

/// Runs independent asynchronous operations with a fixed upper bound while preserving input order.
/// `values` fails fast; `results` keeps individual failures as values for partial-result callers.
enum BoundedAsyncMap {
    /// Fail-fast ordered map. The first operation error cancels the remaining in-flight children,
    /// and inputs that have not yet reached the bounded window are never submitted.
    static func values<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(maximumConcurrentTasks > 0)
        try Task.checkCancellation()
        guard !inputs.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: IndexedValue<Output>.self) { group in
            var nextIndex = 0
            var ordered = [Output?](repeating: nil, count: inputs.count)

            func submit(_ index: Int) {
                let input = inputs[index]
                group.addTask {
                    try Task.checkCancellation()
                    return IndexedValue(index: index, value: try await operation(input))
                }
            }

            for _ in 0..<min(maximumConcurrentTasks, inputs.count) {
                submit(nextIndex)
                nextIndex += 1
            }

            while let completed = try await group.next() {
                try Task.checkCancellation()
                ordered[completed.index] = completed.value

                if nextIndex < inputs.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }

            return ordered.map { value in
                // A normal group exit means every input was submitted and produced one value.
                precondition(value != nil)
                return value!
            }
        }
    }

    static func results<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Result<Output, Error>] {
        precondition(maximumConcurrentTasks > 0)
        try Task.checkCancellation()
        guard !inputs.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: IndexedResult<Output>.self) { group in
            var nextIndex = 0
            var ordered = [Result<Output, Error>?](repeating: nil, count: inputs.count)

            func submit(_ index: Int) {
                let input = inputs[index]
                group.addTask {
                    do {
                        return IndexedResult(index: index, result: .success(try await operation(input)))
                    } catch {
                        return IndexedResult(index: index, result: .failure(error))
                    }
                }
            }

            for _ in 0..<min(maximumConcurrentTasks, inputs.count) {
                submit(nextIndex)
                nextIndex += 1
            }

            while let completed = try await group.next() {
                try Task.checkCancellation()
                ordered[completed.index] = completed.result

                if nextIndex < inputs.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }

            return ordered.map { result in
                // Every submitted child produces exactly one IndexedResult. The task group only
                // exits normally after all inputs have been submitted and completed.
                precondition(result != nil)
                return result!
            }
        }
    }

    private struct IndexedResult<Value: Sendable>: Sendable {
        let index: Int
        let result: Result<Value, Error>
    }

    private struct IndexedValue<Value: Sendable>: Sendable {
        let index: Int
        let value: Value
    }
}

/// Shared bounded execution for the 26 independent MediaBrowser A-Z count probes. A failed
/// letter degrades to zero (and is omitted), while successful letters retain caller order.
enum AlphabetCountFanout {
    static let maximumConcurrentTasks = 4

    static func counts(
        letters: [String],
        fetchCount: @escaping @Sendable (String) async throws -> Int
    ) async throws -> [(display: String, count: Int)] {
        let results = try await BoundedAsyncMap.results(
            letters,
            maximumConcurrentTasks: maximumConcurrentTasks,
            operation: fetchCount
        )
        return zip(letters, results).compactMap { letter, result in
            guard case .success(let count) = result, count > 0 else { return nil }
            return (display: letter, count: count)
        }
    }
}
