// The loopback media proxy (#33 experiment) is an Apple-only path: it relies on the Network
// framework's NWListener/NWConnection. Gating it here keeps PMSKit compiling on Linux so the
// Woodpecker fleet can run `swift test` (incl. the DiagnosticRedactor privacy tests). See #115.
#if canImport(Network)
import Foundation
import Network

/// A minimal loopback HTTP/1.1 origin. Binds `127.0.0.1:0`, and for each inbound connection
/// reads exactly one request head (GET, no body — HLS), hands it to `handler`, writes the
/// serialized response, and closes. One request per connection keeps this trivial and is
/// correct for HLS; keep-alive is a deferred refinement.
final class LoopbackOrigin: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestHead) async -> HTTPResponse

    private let queue = DispatchQueue(label: "media-session-proxy.loopback")
    private var listener: NWListener?

    /// Start listening and resume with the bound port once ready.
    func start(handler: @escaping Handler) async throws -> Int {
        let state = ListenerStartState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let completed = state.install(cont) {
                    cont.resume(with: completed)
                    return
                }
                queue.async {
                    guard !state.isCompleted else { return }
                    do {
                        let params = NWParameters.tcp
                        params.requiredInterfaceType = .loopback
                        let listener = try NWListener(using: params, on: .any)
                        guard !state.isCompleted else {
                            listener.cancel()
                            return
                        }
                        self.listener = listener
                        listener.newConnectionHandler = { [weak self] conn in
                            self?.handle(conn, handler: handler)
                        }
                        listener.stateUpdateHandler = { stateUpdate in
                            switch stateUpdate {
                            case .ready:
                                if let port = listener.port?.rawValue {
                                    state.complete(.success(Int(port)))
                                } else {
                                    state.complete(.failure(URLError(.cannotConnectToHost)))
                                }
                            case .failed(let err):
                                state.complete(.failure(err))
                            default:
                                break
                            }
                        }
                        listener.start(queue: self.queue)
                    } catch {
                        state.complete(.failure(error))
                    }
                }
            }
        } onCancel: {
            state.complete(.failure(CancellationError()))
            queue.async {
                self.listener?.cancel()
                self.listener = nil
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ conn: NWConnection, handler: @escaping Handler) {
        conn.start(queue: queue)
        readHead(conn, buffer: Data()) { head in
            guard let head else { conn.cancel(); return }
            Task {
                let response = await handler(head)
                conn.send(content: response.serialized(), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    /// Accumulate bytes until the request head is complete (`\r\n\r\n`), then deliver it.
    private func readHead(_ conn: NWConnection, buffer: Data, done: @escaping @Sendable (HTTPRequestHead?) -> Void) {
        if let parsed = HTTPRequestHead.parse(buffer) {
            done(parsed.head)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if let parsed = HTTPRequestHead.parse(next) {
                done(parsed.head)
            } else if isComplete || error != nil {
                done(nil)
            } else {
                self.readHead(conn, buffer: next, done: done)
            }
        }
    }
}

/// Thread-safe state for a listener-start continuation. Cancellation can happen before
/// the continuation is installed, while the listener is being constructed on its queue, or
/// after the listener has been assigned but before `.ready`; this stores the winning
/// result and resumes exactly once in every ordering.
private final class ListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var completedResult: Result<Int, Error>?

    var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return completedResult != nil
    }

    /// Install the checked continuation. If cancellation/failure already won, return
    /// that result so the caller can resume the just-created continuation immediately.
    func install(_ continuation: CheckedContinuation<Int, Error>) -> Result<Int, Error>? {
        lock.lock()
        if let completedResult {
            lock.unlock()
            return completedResult
        }
        self.continuation = continuation
        lock.unlock()
        return nil
    }

    /// Complete the start attempt exactly once. Later listener callbacks/cancellations no-op.
    func complete(_ result: Result<Int, Error>) {
        let continuation: CheckedContinuation<Int, Error>?
        lock.lock()
        if completedResult != nil {
            lock.unlock()
            return
        }
        completedResult = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
#endif
