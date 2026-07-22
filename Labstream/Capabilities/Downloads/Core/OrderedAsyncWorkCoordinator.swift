import Foundation

/// Runs work for one key serially while allowing unrelated keys to proceed independently.
/// Every queued completion is delivered exactly once and in submission order.
@MainActor
final class OrderedAsyncWorkCoordinator<Key: Hashable, Output> {
    private struct Item {
        let operation: () async -> Output
        let completion: (Output) -> Void
    }

    private var queues: [Key: [Item]] = [:]

    func enqueue(
        key: Key,
        operation: @escaping () async -> Output,
        completion: @escaping (Output) -> Void
    ) {
        let item = Item(operation: operation, completion: completion)
        if queues[key] != nil {
            queues[key]?.append(item)
            return
        }
        queues[key] = [item]
        startNext(for: key)
    }

    private func startNext(for key: Key) {
        guard let item = queues[key]?.first else {
            queues.removeValue(forKey: key)
            return
        }
        Task {
            let output = await item.operation()
            item.completion(output)
            finishCurrent(for: key)
        }
    }

    private func finishCurrent(for key: Key) {
        guard var queue = queues[key], !queue.isEmpty else { return }
        queue.removeFirst()
        if queue.isEmpty {
            queues.removeValue(forKey: key)
        } else {
            queues[key] = queue
            startNext(for: key)
        }
    }
}
