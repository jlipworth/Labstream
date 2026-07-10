import Foundation

/// Runs independent asynchronous operations with a fixed upper bound while preserving input order.
/// Individual operation failures are values so callers can keep successful partial results.
enum BoundedAsyncMap {
    static func results<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Result<Output, Error>] {
        precondition(maximumConcurrentTasks > 0)
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
}
